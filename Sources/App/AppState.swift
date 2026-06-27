import Foundation
import Combine

/// Single source of truth for the UI and the speak path. Holds connection,
/// settings, history, and runs synthesis (cache-first) + playback.
@MainActor
final class AppState: ObservableObject {

    enum BackendKind: String, CaseIterable, Identifiable {
        case elevenlabs, local
        var id: String { rawValue }
        var label: String { self == .elevenlabs ? "ElevenLabs (클라우드)" : "로컬 (sidecar)" }
    }

    // Connection
    @Published var keyPresent: Bool = Secrets.elevenLabsKey != nil
    @Published var backendKind: BackendKind = .elevenlabs
    @Published var voices: [ElevenVoice] = []
    @Published var connectionStatus = ""

    // Settings
    @Published var voiceId = "Yp1WZJMrN7OSdP8PG9sm"   // 성주 (cloned)
    @Published var voiceName = "성주"
    @Published var modelId = "eleven_flash_v2_5"
    @Published var voiceSettings = ElevenVoiceSettings()
    @Published var useCache = true
    @Published var localBaseURL = "http://127.0.0.1:8765"

    // TTS-friendly text normalization (lightweight LLM via Ollama)
    @Published var normalizeEnabled = false
    @Published var ollamaModel = "gemma4:31b-cloud"   // 3B local models garble Korean numbers; a strong model is needed
    @Published var ollamaURL = "http://localhost:11434"
    @Published var ollamaModels: [String] = []
    @Published var ollamaStatus = ""

    // Runtime
    enum Phase: Equatable { case idle, synthesizing, playing, paused }
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0          // 0…1 across all chunks
    @Published var currentText = ""              // text being spoken (overlay label)
    @Published var inputText = ""                // mirrored into the Generate tab
    @Published var chunkIndex = 0                // 1-based chunk being played
    @Published var chunkCount = 0
    @Published var statusText = ""
    @Published var maxChunkChars = TextSplitter.defaultMaxChars
    @Published private(set) var history: [HistoryEntry] = []

    var isBusy: Bool { phase != .idle }

    private let cache = CacheStore()
    private let player = QueuePlayer()
    private var task: Task<Void, Never>?
    private var timer: Timer?

    init() {
        loadSettings()
        history = cache.entries
        player.onFinish = { [weak self] in self?.finish() }
    }

    private func finish() {
        stopTimer()
        phase = .idle; progress = 0; statusText = ""; chunkIndex = 0; chunkCount = 0
    }

    // MARK: - Transport (overlay controls)

    func togglePause() {
        switch phase {
        case .playing: player.pause(); phase = .paused; stopTimer()
        case .paused:  player.resume(); phase = .playing; startTimer()
        default: break
        }
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func stopTimer() { timer?.invalidate(); timer = nil }
    private func tick() {
        progress = player.progress
        chunkIndex = min(max(1, player.finishedCount + 1), max(1, chunkCount))
    }

    var backendIdentity: String { backendKind == .elevenlabs ? "elevenlabs" : "qwen3-local" }
    var settingsHash: String { backendKind == .elevenlabs ? voiceSettings.hash : "" }
    var audioExt: String { backendKind == .elevenlabs ? "mp3" : "wav" }

    private func makeBackend() -> TTSBackend? {
        switch backendKind {
        case .elevenlabs:
            guard let key = Secrets.elevenLabsKey else { return nil }
            return ElevenLabsBackend(apiKey: key, settings: voiceSettings)
        case .local:
            return Qwen3MLXBackend(identity: backendIdentity,
                                   baseURL: URL(string: localBaseURL) ?? URL(string: "http://127.0.0.1:8765")!)
        }
    }

    // MARK: - Synthesize (paragraph chunks, cache-first, queued playback)

    func synthesize(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let chunks = TextSplitter.paragraphs(t, maxChars: maxChunkChars)
        guard !chunks.isEmpty else { return }

        task?.cancel(); player.stop(); stopTimer()
        inputText = t                            // mirror into the Generate tab (req: show source text)
        currentText = t
        progress = 0
        player.start(expected: chunks.count)
        chunkCount = chunks.count; chunkIndex = 0

        let ident = backendIdentity, vid = voiceId, mid = modelId
        // Cache namespace includes normalization so normalized/raw audio don't collide.
        let sHash = settingsHash + (normalizeEnabled ? "|norm:\(ollamaModel)" : "")
        let vName = voiceName, ext = audioExt
        let voice = VoiceConfig(voiceId: vid, modelId: mid, settingsHash: sHash)
        let normalizer: TextNormalizer? = normalizeEnabled
            ? TextNormalizer(baseURL: URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")!,
                             model: ollamaModel)
            : nil

        task = Task { [weak self] in
            guard let self else { return }
            var backend: TTSBackend?
            var startedPlaying = false           // ⏳ only before the first audio plays
            do {
                for chunk in chunks {
                    try Task.checkCancellation()
                    let key = CacheStore.key(text: chunk, backend: ident,
                                             voiceId: vid, modelId: mid, settingsHash: sHash)
                    var url: URL?
                    if self.useCache, let u = self.cache.fileURL(forKey: key) {
                        self.cache.touch(key); url = u   // cache hit: skip synthesizing state
                    } else {
                        // "synthesizing" only while waiting for the FIRST chunk
                        if !startedPlaying {
                            self.phase = .synthesizing
                            self.statusText = normalizer != nil ? "정규화·합성 중…" : "합성 중…"
                        }
                        if backend == nil { backend = self.makeBackend() }
                        guard let b = backend else {
                            self.phase = .idle; self.statusText = "키/백엔드 미설정"; return
                        }
                        // TTS-friendly normalization (falls back to original on failure).
                        var ttsText = chunk
                        if let normalizer {
                            ttsText = (try? await normalizer.normalize(chunk)) ?? chunk
                            try Task.checkCancellation()
                        }
                        var data = Data()
                        for try await c in b.stream(segment: ttsText, voice: voice) {
                            try Task.checkCancellation(); data.append(c)
                        }
                        if self.useCache {
                            let e = self.cache.save(key: key, text: chunk, backend: ident, voiceId: vid,
                                                    voiceName: vName, modelId: mid, ext: ext, data: data)
                            url = self.cache.audioURL(e)
                        } else {
                            let tmp = FileManager.default.temporaryDirectory
                                .appendingPathComponent("\(key).\(ext)")
                            try? data.write(to: tmp); url = tmp
                        }
                    }
                    if let url {
                        self.player.enqueue(url)
                        if !startedPlaying {
                            startedPlaying = true
                            self.phase = .playing; self.statusText = "재생 중…"; self.startTimer()
                        }
                    }
                }
                self.history = self.cache.entries
            } catch is CancellationError {
                self.finish()
            } catch {
                self.phase = .idle
                self.statusText = "오류: \(error.localizedDescription)"
            }
        }
    }

    func replay(_ e: HistoryEntry) {
        task?.cancel(); player.stop()
        guard let url = cache.fileURL(forKey: e.id) else { statusText = "오디오 파일 없음"; return }
        cache.touch(e.id); history = cache.entries
        inputText = e.text; currentText = e.text
        chunkCount = 1; chunkIndex = 1; progress = 0
        player.start(expected: 1)
        player.enqueue(url)
        phase = .playing; statusText = "캐시에서 재생"; startTimer()
    }

    func stop() { task?.cancel(); player.stop(); finish() }

    func deleteHistory(_ id: String) { cache.delete(id); history = cache.entries }
    func clearHistory() { cache.clear(); history = cache.entries }

    // MARK: - Connection

    func saveKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.createDirectory(atPath: Secrets.appSupportDir,
                                                 withIntermediateDirectories: true)
        let path = (Secrets.appSupportDir as NSString).appendingPathComponent("eleven_key")
        try? k.write(toFile: path, atomically: true, encoding: .utf8)
        keyPresent = !k.isEmpty
        connectionStatus = k.isEmpty ? "키 삭제됨" : "키 저장됨"
        if !k.isEmpty { refreshVoices() }
    }

    func refreshVoices() {
        guard let key = Secrets.elevenLabsKey else { connectionStatus = "키 없음"; return }
        connectionStatus = "연결 확인 중…"
        Task { [weak self] in
            do {
                let vs = try await ElevenLabs.voices(apiKey: key)
                guard let self else { return }
                self.voices = vs
                self.connectionStatus = "연결됨 · 보이스 \(vs.count)개"
                if let v = vs.first(where: { $0.id == self.voiceId }) { self.voiceName = v.name }
            } catch {
                self?.connectionStatus = "연결 실패: \(error.localizedDescription)"
            }
        }
    }

    func refreshOllamaModels() {
        let url = URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")!
        ollamaStatus = "확인 중…"
        Task { [weak self] in
            do {
                let ms = try await Ollama.models(baseURL: url)
                guard let self else { return }
                self.ollamaModels = ms
                self.ollamaStatus = "연결됨 · 모델 \(ms.count)개"
            } catch {
                self?.ollamaStatus = "연결 실패: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Settings persistence

    private var settingsURL: URL {
        URL(fileURLWithPath: (Secrets.appSupportDir as NSString).appendingPathComponent("settings.json"))
    }

    func saveSettings() {
        let dict: [String: Any] = [
            "voiceId": voiceId, "voiceName": voiceName, "modelId": modelId,
            "backend": backendKind.rawValue, "useCache": useCache, "localBaseURL": localBaseURL,
            "maxChunkChars": maxChunkChars,
            "normalize": normalizeEnabled, "ollamaModel": ollamaModel, "ollamaURL": ollamaURL,
            "stability": voiceSettings.stability, "similarity": voiceSettings.similarityBoost,
            "style": voiceSettings.style, "speakerBoost": voiceSettings.useSpeakerBoost,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? d.write(to: settingsURL)
        }
    }

    private func loadSettings() {
        guard let d = try? Data(contentsOf: settingsURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        voiceId = o["voiceId"] as? String ?? voiceId
        voiceName = o["voiceName"] as? String ?? voiceName
        modelId = o["modelId"] as? String ?? modelId
        backendKind = BackendKind(rawValue: o["backend"] as? String ?? "") ?? backendKind
        useCache = o["useCache"] as? Bool ?? useCache
        localBaseURL = o["localBaseURL"] as? String ?? localBaseURL
        maxChunkChars = o["maxChunkChars"] as? Int ?? maxChunkChars
        normalizeEnabled = o["normalize"] as? Bool ?? normalizeEnabled
        ollamaModel = o["ollamaModel"] as? String ?? ollamaModel
        ollamaURL = o["ollamaURL"] as? String ?? ollamaURL
        voiceSettings.stability = o["stability"] as? Double ?? voiceSettings.stability
        voiceSettings.similarityBoost = o["similarity"] as? Double ?? voiceSettings.similarityBoost
        voiceSettings.style = o["style"] as? Double ?? voiceSettings.style
        voiceSettings.useSpeakerBoost = o["speakerBoost"] as? Bool ?? voiceSettings.useSpeakerBoost
    }
}

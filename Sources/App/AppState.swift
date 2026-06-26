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

    // Runtime
    enum Phase: Equatable { case idle, synthesizing, playing, paused }
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0          // 0…1 playback position
    @Published var currentText = ""              // text being spoken (overlay label)
    @Published var statusText = ""
    @Published private(set) var history: [HistoryEntry] = []

    var isBusy: Bool { phase != .idle }

    private let cache = CacheStore()
    private let player = AudioPlayer()
    private var task: Task<Void, Never>?
    private var timer: Timer?

    init() {
        loadSettings()
        history = cache.entries
        player.onFinish = { [weak self] in self?.finish() }
    }

    private func finish() {
        stopTimer()
        phase = .idle; progress = 0; statusText = ""
    }

    /// Begin playback of ready audio and enter the .playing phase.
    private func startPlayback(_ data: Data, status: String) {
        do {
            try player.play(data)
            statusText = status; phase = .playing
            startTimer()
        } catch {
            statusText = "재생 실패"; phase = .idle
        }
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
        let d = player.duration
        progress = d > 0 ? min(1, player.currentTime / d) : 0
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

    // MARK: - Synthesize (cache-first)

    func synthesize(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        task?.cancel(); player.stop()

        let key = CacheStore.key(text: t, backend: backendIdentity,
                                 voiceId: voiceId, modelId: modelId, settingsHash: settingsHash)
        currentText = t
        if useCache, let data = cache.data(forKey: key) {
            cache.touch(key); history = cache.entries
            startPlayback(data, status: "캐시에서 재생")
            return
        }
        guard let backend = makeBackend() else { statusText = "키/백엔드 미설정"; return }
        phase = .synthesizing; statusText = "합성 중…"; progress = 0
        let voice = VoiceConfig(voiceId: voiceId, modelId: modelId, settingsHash: settingsHash)
        let vName = voiceName, ident = backendIdentity, ext = audioExt
        task = Task { [weak self] in
            guard let self else { return }
            do {
                var data = Data()
                for try await chunk in backend.stream(segment: t, voice: voice) {
                    try Task.checkCancellation(); data.append(chunk)
                }
                if self.useCache {
                    self.cache.save(key: key, text: t, backend: ident, voiceId: self.voiceId,
                                    voiceName: vName, modelId: self.modelId, ext: ext, data: data)
                    self.history = self.cache.entries
                }
                self.startPlayback(data, status: "재생 중…")
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
        guard let data = cache.data(forKey: e.id) else { statusText = "오디오 파일 없음"; return }
        cache.touch(e.id); history = cache.entries
        currentText = e.text
        startPlayback(data, status: "캐시에서 재생")
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

    // MARK: - Settings persistence

    private var settingsURL: URL {
        URL(fileURLWithPath: (Secrets.appSupportDir as NSString).appendingPathComponent("settings.json"))
    }

    func saveSettings() {
        let dict: [String: Any] = [
            "voiceId": voiceId, "voiceName": voiceName, "modelId": modelId,
            "backend": backendKind.rawValue, "useCache": useCache, "localBaseURL": localBaseURL,
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
        voiceSettings.stability = o["stability"] as? Double ?? voiceSettings.stability
        voiceSettings.similarityBoost = o["similarity"] as? Double ?? voiceSettings.similarityBoost
        voiceSettings.style = o["style"] as? Double ?? voiceSettings.style
        voiceSettings.useSpeakerBoost = o["speakerBoost"] as? Bool ?? voiceSettings.useSpeakerBoost
    }
}

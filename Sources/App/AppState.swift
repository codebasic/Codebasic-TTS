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

    // TTS-friendly text normalization (LLM: Gemini API or local Ollama)
    enum NormalizeProvider: String, CaseIterable, Identifiable {
        case gemini, ollama
        var id: String { rawValue }
        var label: String { self == .gemini ? "Gemini" : "Ollama" }
    }
    @Published var normalizeEnabled = false
    @Published var normalizeProvider: NormalizeProvider = .ollama
    @Published var geminiBaseURL = GeminiNormalizer.defaultBaseURL   // endpoint root; field default, not hardcoded
    @Published var geminiModel = "gemini-2.0-flash"   // 대본(정규화)용
    @Published var geminiModels: [String] = []        // fetched from the endpoint (models.list)
    @Published var geminiStatus = ""
    @Published var geminiKeyPresent = Secrets.geminiKey != nil
    @Published var ollamaModel = "gemma4:31b-cloud"   // 대본(정규화)용. 3B local models garble Korean numbers; a strong model is needed
    @Published var ollamaURL = "http://localhost:11434"
    @Published var ollamaModels: [String] = []
    @Published var ollamaStatus = ""
    @Published var normalizePrompt = TextNormalizer.defaultInstruction
    @Published var normalizing = false

    // Commentary (코드 → 해설). Shares the provider + endpoint above, but the
    // explain model is SEPARATE from the script model — they can differ.
    @Published var codeText = ""                 // source code (해설 panel, top)
    @Published var explanationText = ""          // generated commentary (해설 panel, bottom)
    @Published var explaining = false
    @Published var explainPrompt = CodeExplanation.defaultInstruction
    @Published var explainHint = ""              // 해설 단계 (코드→해설) 추가 지시
    @Published var scriptHint = ""               // 음성 대본 단계 (해설→대본) 추가 지시
    @Published var explainGeminiModel = "gemini-2.0-flash"   // 해설용
    @Published var explainOllamaModel = "gemma4:31b-cloud"   // 해설용
    @Published var lastExplainedCode = ""        // baseline snapshot for "이어서 해설" (incremental)
    @Published var lastSegment = ""              // the most recently produced commentary (full or appended delta)
    var canContinueExplain: Bool {
        !lastExplainedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasLastSegment: Bool {
        !lastSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // 해설 패널의 하단 토글: 해설(원문 산문) ⇄ 음성 대본(실제 합성에 쓰이는 정규화 결과).
    enum CommentaryPane: String, CaseIterable, Identifiable {
        case explanation = "해설", script = "음성 대본"
        var id: String { rawValue }
    }
    @Published var commentaryPane: CommentaryPane = .explanation
    @Published var commentaryScript = ""         // editable TTS script derived from the 해설
    @Published var commentaryScriptSource = ""   // the explanation the script was built from (staleness)
    @Published var buildingScript = false
    /// True when the 해설 changed after the 음성 대본 was generated.
    var commentaryScriptStale: Bool {
        !commentaryScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && commentaryScriptSource != explanationText
    }
    @Published var selectedTab = 0               // RootView TabView selection

    /// Model used for the current provider, per role.
    var scriptModel: String { normalizeProvider == .gemini ? geminiModel : ollamaModel }
    var explainModel: String { normalizeProvider == .gemini ? explainGeminiModel : explainOllamaModel }
    /// Models exposed by the current provider's endpoint (Gemini falls back to the
    /// static list until a fetch succeeds).
    var providerModels: [String] {
        normalizeProvider == .gemini
            ? (geminiModels.isEmpty ? GeminiNormalizer.models : geminiModels)
            : ollamaModels
    }

    // Runtime
    enum Phase: Equatable { case idle, synthesizing, playing, paused }
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0          // 0…1 across all chunks
    @Published var currentText = ""              // text being spoken (overlay label)
    @Published var inputText = ""                // original (top panel / source text)
    @Published var scriptText = ""               // TTS-friendly script actually sent to the engine (bottom panel)
    @Published var chunkIndex = 0                // 1-based chunk being played
    @Published var chunkCount = 0
    @Published var statusText = ""
    @Published var maxChunkChars = TextSplitter.defaultMaxChars
    @Published private(set) var history: [HistoryEntry] = []

    var isBusy: Bool { phase != .idle }

    private let cache = CacheStore()
    private let normCache = NormalizationCache()
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
        currentText = t                          // overlay label (the spoken text); do NOT touch inputText
        progress = 0
        player.start(expected: chunks.count)
        chunkCount = chunks.count; chunkIndex = 0

        let ident = backendIdentity, vid = voiceId, mid = modelId, sHash = settingsHash
        let vName = voiceName, ext = audioExt
        let voice = VoiceConfig(voiceId: vid, modelId: mid, settingsHash: sHash)

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
                            if self.statusText.isEmpty { self.statusText = "합성 중…" }
                        }
                        if backend == nil { backend = self.makeBackend() }
                        guard let b = backend else {
                            self.phase = .idle; self.statusText = "키/백엔드 미설정"; return
                        }
                        var data = Data()
                        for try await c in b.stream(segment: chunk, voice: voice) {
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

    private func makeNormalizer(instruction: String) -> Normalizing? {
        switch normalizeProvider {
        case .gemini:
            guard let key = Secrets.geminiKey else { return nil }
            return GeminiNormalizer(baseURL: geminiBaseURL, apiKey: key, model: geminiModel,
                                    instruction: instruction)
        case .ollama:
            return TextNormalizer(
                baseURL: URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")!,
                model: ollamaModel, instruction: instruction)
        }
    }

    /// Normalize instruction with an optional per-run 음성 대본 hint folded in.
    private func scriptInstruction(_ hint: String) -> String {
        let h = hint.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? normalizePrompt
            : normalizePrompt + "\n\n[추가 지시 — 이번 변환에만 적용]\n\(h)"
    }

    func saveGeminiKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Secrets.writeKey(named: "gemini_key", k)
        geminiKeyPresent = !k.isEmpty
    }

    // MARK: - Commentary (코드 → 해설)

    private func makeExplainer() -> Explaining? {
        switch normalizeProvider {
        case .gemini:
            guard let key = Secrets.geminiKey else { return nil }
            return GeminiExplainer(baseURL: geminiBaseURL, apiKey: key, model: explainGeminiModel,
                                   instruction: explainPrompt)
        case .ollama:
            return OllamaExplainer(
                baseURL: URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")!,
                model: explainOllamaModel, instruction: explainPrompt)
        }
    }

    /// Run the explainer on `codeText` (cache-first) and fill `explanationText`.
    /// Returns nil on failure WITHOUT touching the speak path — a failed
    /// explanation must never fall through to reading raw code aloud. The code is
    /// sent verbatim (no cleanInput, which would flatten line structure).
    @discardableResult
    func explainCode(force: Bool = false) async -> String? {
        let code = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else { explanationText = ""; return nil }
        guard let explainer = makeExplainer() else {
            statusText = normalizeProvider == .gemini ? "Gemini 키 미설정" : "Ollama 미설정"
            return nil
        }
        let provider = "explain:" + normalizeProvider.rawValue
        let nk = NormalizationCache.key(text: code, provider: provider, model: explainModel,
                                        prompt: explainPrompt + "\u{1F}" + explainHint)
        if !force, let cached = normCache.script(forKey: nk) {
            explanationText = cached; lastExplainedCode = code; lastSegment = cached; return cached
        }
        explaining = true
        defer { explaining = false }
        do {
            let out = CodeExplanation.stripMarkdown(try await explainer.explain(code, hint: explainHint))
            guard !out.isEmpty else { statusText = "해설 생성 실패 (빈 응답)"; return nil }
            normCache.put(key: nk, script: out)
            explanationText = out
            lastExplainedCode = code      // establish the baseline for "이어서 해설"
            lastSegment = out             // full explanation is also the latest segment
            return out
        } catch {
            statusText = "해설 오류: \(error.localizedDescription)"
            return nil
        }
    }

    /// "이어서 해설": explain only what changed in `codeText` since the last
    /// explanation, and APPEND it to `explanationText` (a growing narration). The
    /// first run (no baseline yet) falls back to a full explain. Diffing is left
    /// to the LLM — it sees both the previous and current code.
    @discardableResult
    func continueExplain(force: Bool = false) async -> String? {
        let current = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return nil }
        guard canContinueExplain else { return await explainCode(force: force) }   // first pass = full
        guard let explainer = makeExplainer() else {
            statusText = normalizeProvider == .gemini ? "Gemini 키 미설정" : "Ollama 미설정"
            return nil
        }
        // Cache keyed on (previous ∥ current) so re-running the same step is free.
        let provider = "explain-cont:" + normalizeProvider.rawValue
        let keyText = lastExplainedCode + "\u{1F}" + current
        let nk = NormalizationCache.key(text: keyText, provider: provider, model: explainModel,
                                        prompt: "continue\u{1F}" + explainHint)
        if !force, let cached = normCache.script(forKey: nk) {
            applyContinuation(cached, newBaseline: current); return cached
        }
        explaining = true
        defer { explaining = false }
        do {
            let out = CodeExplanation.stripMarkdown(
                try await explainer.explainContinuing(previous: lastExplainedCode, current: current, hint: explainHint))
            guard !out.isEmpty else { statusText = "이어서 해설 실패 (빈 응답)"; return nil }
            normCache.put(key: nk, script: out)
            applyContinuation(out, newBaseline: current)
            return out
        } catch {
            statusText = "이어서 해설 오류: \(error.localizedDescription)"
            return nil
        }
    }

    /// Append a continuation to the running narration (or note "변경 없음"), then
    /// advance the baseline so the next "이어서 해설" diffs from here.
    private func applyContinuation(_ text: String, newBaseline: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { lastExplainedCode = newBaseline }
        if t.hasPrefix(CodeExplanation.noChange) {
            statusText = "변경 없음 — 추가할 해설 없음"
            return
        }
        if explanationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            explanationText = t
        } else {
            explanationText += "\n\n" + t
        }
        lastSegment = t          // only the newly appended part — for "새 해설만 재생"
        statusText = "이어서 해설 추가됨"
    }

    /// Start a fresh narration: clear the commentary, baseline, and 음성 대본.
    func clearCommentary() {
        explanationText = ""
        lastExplainedCode = ""
        lastSegment = ""
        commentaryScript = ""
        commentaryScriptSource = ""
        commentaryPane = .explanation
        statusText = ""
    }

    /// Build the 음성 대본 from the current 해설 (normalize per paragraph when
    /// enabled), filling `commentaryScript` so the user can see/edit exactly what
    /// the engine will receive. Records the source for staleness tracking.
    @discardableResult
    func buildCommentaryScript() async -> String {
        let src = explanationText
        guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            commentaryScript = ""; commentaryScriptSource = src; return ""
        }
        buildingScript = true
        defer { buildingScript = false }
        let script = await buildScript(from: src, hint: scriptHint)
        commentaryScript = script
        commentaryScriptSource = src
        return script
    }

    /// 해설 탭 "이어서 읽기": read the latest segment — the delta from the last
    /// "이어서 해설" (or the whole thing after a full explain). If audio is playing,
    /// it stops and reads this segment from the start. Leaves the 생성 탭 panels
    /// untouched; synthesize() owns the single playback task.
    func speakContinue() {
        let seg = lastSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seg.isEmpty else { return }
        synthesize(TextSplitter.cleanInput(seg))   // read the latest 해설 segment directly
    }

    /// 해설 탭 → 생성 탭: hand the commentary to the script pipeline as its source.
    func sendExplanationToGenerate() {
        let ex = explanationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ex.isEmpty else { return }
        inputText = ex          // prepareScript cleans/normalizes this prose downstream
        scriptText = ""
        selectedTab = 1         // switch to 생성
    }

    /// 해설 탭 "전체 재생": if a 음성 대본 was explicitly generated, speak exactly
    /// that (incl. manual edits); otherwise read the 해설 directly — no extra
    /// normalize pass. 음성 대본 생성은 선택 사항. Does not touch 생성 탭 panels.
    func speakExplanation() {
        let script = commentaryScript.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = script.isEmpty ? TextSplitter.cleanInput(explanationText) : commentaryScript
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        synthesize(text)
    }

    /// Services entry ("코드 해설"): explain the selected code, then speak it
    /// end-to-end (코드 → 해설 → 대본 → 음성). Two sequential LLM calls before any
    /// audio (explain, then normalize if enabled). The code is fed RAW to the
    /// explainer; if explanation fails we stop and never speak the source.
    func explainAndSpeak(_ code: String) {
        task?.cancel(); player.stop()
        codeText = code             // raw — no cleanInput
        explanationText = ""
        scriptText = ""
        phase = .synthesizing
        statusText = "해설 생성 중…"
        Task { [weak self] in
            guard let self else { return }
            guard let explanation = await self.explainCode() else {
                self.phase = .idle
                if self.statusText.isEmpty { self.statusText = "해설 생성 실패" }
                return                  // do NOT speak raw code
            }
            self.inputText = explanation
            self.scriptText = ""
            self.statusText = self.normalizeEnabled ? "대본 생성 중…" : "합성 중…"
            let script = await self.prepareScript()
            self.synthesize(script)
        }
    }

    // MARK: - Script (TTS-friendly text)

    /// Build the TTS script from inputText: normalize per paragraph via the LLM
    /// when enabled, otherwise pass the original through. Returns the script and
    /// fills `scriptText` (the bottom panel).
    @discardableResult
    func prepareScript(force: Bool = false) async -> String {
        inputText = TextSplitter.cleanInput(inputText)   // tidy pasted markdown/math in the source panel
        let script = await buildScript(from: inputText, force: force)
        scriptText = script
        return script
    }

    /// Core normalization: source prose → TTS script (per-paragraph, cache-first),
    /// WITHOUT mutating the inputText/scriptText panels. Used by prepareScript and
    /// by segment playback (재생할 조각만 정규화).
    private func buildScript(from source: String, hint: String = "", force: Bool = false) async -> String {
        let src = TextSplitter.cleanInput(source)
        guard !src.isEmpty else { return "" }
        let instruction = scriptInstruction(hint)
        guard normalizeEnabled, let norm = makeNormalizer(instruction: instruction) else { return src }

        normalizing = true
        defer { normalizing = false }
        let provider = normalizeProvider.rawValue
        let model = scriptModel
        var out: [String] = []
        for p in TextSplitter.paragraphs(src, maxChars: maxChunkChars) {
            // Normalization cache: skip the LLM for text already normalized.
            // The 음성 대본 hint is part of `instruction`, so it's in the key too.
            let nk = NormalizationCache.key(text: p, provider: provider, model: model, prompt: instruction)
            if !force, let cached = normCache.script(forKey: nk) {
                out.append(cached)
            } else {
                let n = (try? await norm.normalize(p)) ?? p
                normCache.put(key: nk, script: n)
                out.append(n)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Force a fresh normalization (ignores the normalization cache).
    func regenerateScript() {
        Task { [weak self] in await self?.prepareScript(force: true) }
    }

    /// Generate-tab "재생": speak the script (or the original if it is empty).
    func speakScript() {
        if scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = TextSplitter.cleanInput(inputText)
            synthesize(inputText)
        } else {
            synthesize(scriptText)
        }
    }

    /// Services entry: set the source, build the script, then speak it.
    func speakSelected(_ text: String) {
        task?.cancel(); player.stop()
        inputText = TextSplitter.cleanInput(text)
        scriptText = ""
        phase = .synthesizing
        statusText = normalizeEnabled ? "대본 생성 중…" : "합성 중…"
        Task { [weak self] in
            guard let self else { return }
            let script = await self.prepareScript()
            self.synthesize(script)
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

    func refreshGeminiModels() {
        guard let key = Secrets.geminiKey else { geminiStatus = "키 없음"; return }
        geminiStatus = "확인 중…"
        let base = geminiBaseURL
        Task { [weak self] in
            do {
                let ms = try await Gemini.models(baseURL: base, apiKey: key)
                guard let self else { return }
                self.geminiModels = ms
                self.geminiStatus = "연결됨 · 모델 \(ms.count)개"
            } catch {
                self?.geminiStatus = "연결 실패: \(error.localizedDescription)"
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
        var dict: [String: Any] = [
            "voiceId": voiceId, "voiceName": voiceName, "modelId": modelId,
            "backend": backendKind.rawValue, "useCache": useCache, "localBaseURL": localBaseURL,
            "maxChunkChars": maxChunkChars,
            "normalize": normalizeEnabled, "ollamaModel": ollamaModel, "ollamaURL": ollamaURL,
            "normalizeProvider": normalizeProvider.rawValue, "geminiModel": geminiModel,
            "geminiBaseURL": geminiBaseURL,
            "explainGeminiModel": explainGeminiModel, "explainOllamaModel": explainOllamaModel,
            "stability": voiceSettings.stability, "similarity": voiceSettings.similarityBoost,
            "style": voiceSettings.style, "speakerBoost": voiceSettings.useSpeakerBoost,
        ]
        // Only persist the prompt if the user customized it, so default-prompt
        // updates auto-apply for everyone who didn't.
        if normalizePrompt != TextNormalizer.defaultInstruction {
            dict["normalizePrompt"] = normalizePrompt
        }
        if explainPrompt != CodeExplanation.defaultInstruction {
            dict["explainPrompt"] = explainPrompt
        }
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
        normalizePrompt = o["normalizePrompt"] as? String ?? normalizePrompt
        explainPrompt = o["explainPrompt"] as? String ?? explainPrompt
        normalizeProvider = NormalizeProvider(rawValue: o["normalizeProvider"] as? String ?? "") ?? normalizeProvider
        geminiModel = o["geminiModel"] as? String ?? geminiModel
        geminiBaseURL = o["geminiBaseURL"] as? String ?? geminiBaseURL
        explainGeminiModel = o["explainGeminiModel"] as? String ?? explainGeminiModel
        explainOllamaModel = o["explainOllamaModel"] as? String ?? explainOllamaModel
        voiceSettings.stability = o["stability"] as? Double ?? voiceSettings.stability
        voiceSettings.similarityBoost = o["similarity"] as? Double ?? voiceSettings.similarityBoost
        voiceSettings.style = o["style"] as? Double ?? voiceSettings.style
        voiceSettings.useSpeakerBoost = o["speakerBoost"] as? Bool ?? voiceSettings.useSpeakerBoost
    }
}

import Foundation
import Combine
import CryptoKit
import AppKit

/// Single source of truth for the UI and the speak path. Holds connection,
/// settings, history, and runs synthesis (cache-first) + playback.
@MainActor
final class AppState: ObservableObject {

    /// The TTS-engine seam: each engine declares its capabilities so the settings
    /// UI renders the right controls without hardcoding ElevenLabs. A new engine =
    /// a new case + these descriptors + its own settings sub-section. The engine's
    /// concrete tuning (e.g. ElevenVoiceSettings) stays its own typed value so the
    /// cache key / persistence are untouched.
    enum BackendKind: String, CaseIterable, Identifiable {
        case elevenlabs, local
        var id: String { rawValue }
        var label: String { self == .elevenlabs ? "ElevenLabs (클라우드)" : "로컬 Qwen3 (sidecar)" }
        /// Engine needs an API key + a connection step.
        var requiresAPIKey: Bool { self == .elevenlabs }
        /// Engine exposes a fetchable voice list (else the voice is entered/fixed).
        var hasVoiceList: Bool { self == .elevenlabs }
        /// Engine reaches a local sidecar at a configurable base URL.
        var usesLocalSidecar: Bool { self == .local }
        /// Selectable synthesis models (empty = single/fixed model).
        var ttsModels: [(id: String, label: String)] {
            self == .elevenlabs ? ElevenLabs.koreanModels : []
        }
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
    @Published var scriptHint = ""               // 대본 단계 (원문→대본) 추가 지시
    private var scriptBuiltFrom = ""             // (원본 ∥ 지시) the 대본 was built from
    /// True when 원본 or 추가 지시 changed after the 대본 was generated. Suppressed
    /// while generating — scriptText fills before scriptBuiltFrom is stamped.
    var scriptStale: Bool {
        !normalizing
            && !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && scriptBuiltFrom != (inputText + "\u{1F}" + scriptHint)
    }

    // Commentary (코드 → 해설). Shares the provider + endpoint above, but the
    // explain model is SEPARATE from the script model — they can differ.
    @Published var codeText = ""                 // source code (해설 panel, top)
    @Published var explanationText = ""          // generated commentary (해설 panel, bottom)
    @Published var explaining = false
    @Published var explainPrompt = CodeExplanation.defaultInstruction
    @Published var explainHint = ""              // 해설 단계 (코드→해설) 추가 지시
    @Published var explainGeminiModel = "gemini-2.0-flash"   // 해설용
    @Published var explainOllamaModel = "gemma4:31b-cloud"   // 해설용
    @Published var explainTemperature: Double = 0.4          // 해설 LLM 생성 매개변수
    @Published var scriptTemperature: Double = 0.2           // 대본 LLM 생성 매개변수
    @Published var codeImages: [Data] = []       // pasted code screenshots (PNG); needs a vision model
    // Vision model = the explain model by default; a non-empty value is a remembered override.
    @Published var explainVisionGeminiModel = ""
    @Published var explainVisionOllamaModel = ""
    var hasImages: Bool { !codeImages.isEmpty }
    @Published var lastExplainedCode = ""        // baseline snapshot for "이어서 해설" (incremental)
    @Published var lastSegment = ""              // the most recently produced commentary (full or appended delta)
    var canContinueExplain: Bool {
        !lastExplainedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var hasLastSegment: Bool {
        !lastSegment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    @Published var selectedTab = 0               // RootView TabView selection

    // Per-role provider (Ollama / Gemini can be configured simultaneously; a role
    // picks any connected model, which determines its provider). Migrated from the
    // old single normalizeProvider on load so existing setups keep working.
    @Published var explainProvider: NormalizeProvider = .ollama
    @Published var scriptProvider: NormalizeProvider = .ollama
    @Published var visionProvider: NormalizeProvider = .ollama
    @Published var visionOverridden = false       // false = vision follows the 해설 model

    /// Effective model per role (provider's own model field).
    var scriptModel: String { scriptProvider == .gemini ? geminiModel : ollamaModel }
    var explainModel: String { explainProvider == .gemini ? explainGeminiModel : explainOllamaModel }
    var visionProviderEff: NormalizeProvider { visionOverridden ? visionProvider : explainProvider }
    var visionModelEff: String {
        if !visionOverridden { return explainModel }
        return visionProvider == .gemini ? explainVisionGeminiModel : explainVisionOllamaModel
    }

    /// A pick in a model selector: a (provider, model) pair. Identity carries the
    /// provider so models from different providers never collide.
    struct LLMChoice: Hashable, Identifiable {
        let provider: NormalizeProvider
        let model: String
        var id: String { provider.rawValue + "\u{1F}" + model }
        var label: String { "\(model) · \(provider == .gemini ? "Gemini" : "Ollama")" }
    }

    /// All models from connected providers (Ollama always; Gemini once a key is set).
    var connectedModels: [LLMChoice] {
        var out = ollamaModels.map { LLMChoice(provider: .ollama, model: $0) }
        if geminiKeyPresent || !geminiModels.isEmpty {
            let g = geminiModels.isEmpty ? GeminiNormalizer.models : geminiModels
            out += g.map { LLMChoice(provider: .gemini, model: $0) }
        }
        return out
    }

    func refreshAllModels() {
        refreshOllamaModels()
        if geminiKeyPresent { refreshGeminiModels() }
    }
    func refreshAllModelsIfNeeded() {
        if ollamaModels.isEmpty { refreshOllamaModels() }
        if geminiModels.isEmpty && geminiKeyPresent { refreshGeminiModels() }
    }

    // Runtime
    enum Phase: Equatable { case idle, synthesizing, playing, paused }
    @Published var phase: Phase = .idle
    @Published var progress: Double = 0          // 0…1 across all chunks

    /// What the current playback is — shown in the HUD instead of the script text.
    enum PlaybackMode { case tts, explain
        var label: String { self == .tts ? "TTS" : "해설" }
        var icon: String { self == .tts ? "speaker.wave.2.fill" : "text.book.closed.fill" }
    }
    @Published var playbackMode: PlaybackMode = .tts

    @Published var currentText = ""              // text being spoken (overlay label)
    @Published var inputText = ""                // original (top panel / source text)
    @Published var scriptText = ""               // TTS-friendly script actually sent to the engine (bottom panel)
    @Published var chunkIndex = 0                // 1-based chunk being played
    @Published var chunkCount = 0
    @Published var statusText = ""
    @Published var maxChunkChars = TextSplitter.defaultMaxChars
    @Published private(set) var historyRevision = 0       // bumped on any history change → view reloads
    @Published private(set) var backlog: [BacklogEntry] = []

    var isBusy: Bool { phase != .idle }

    private let cache = CacheStore()
    private let normCache = NormalizationCache()
    private let backlogStore = BacklogStore()
    private let player = QueuePlayer()
    private var task: Task<Void, Never>?         // audio synthesis/playback
    private var explainTask: Task<Void, Never>?  // long-lived 해설 LLM stream
    private var scriptTask: Task<Void, Never>?   // long-lived 대본 정규화 stream
    private var timer: Timer?

    init() {
        loadSettings()
        backlog = backlogStore.entries
        player.onFinish = { [weak self] in self?.finish() }
    }

    // MARK: - Backlog (flag a generation case for later analysis)

    enum IssueStage { case explain, script }

    /// Capture the current stage's full context (input + prompt + hint + output)
    /// into the backlog, tagged for later filtering/analysis.
    func recordIssue(_ stage: IssueStage, note: String = "", tags: [String] = ["이슈"]) {
        let cleanTags = tags.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let finalTags = cleanTags.isEmpty ? ["이슈"] : cleanTags
        let e: BacklogEntry
        switch stage {
        case .explain:
            guard !explanationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusText = "기록할 해설이 없습니다"; return
            }
            e = BacklogEntry(id: UUID().uuidString, createdAt: Date(), tags: finalTags, note: note,
                             stage: "해설", provider: explainProvider.label, model: explainModel,
                             prompt: explainPrompt, hint: explainHint, input: codeText, output: explanationText,
                             images: codeImages.isEmpty ? nil : codeImages)
        case .script:
            guard !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusText = "기록할 대본이 없습니다"; return
            }
            e = BacklogEntry(id: UUID().uuidString, createdAt: Date(), tags: finalTags, note: note,
                             stage: "대본", provider: scriptProvider.label, model: scriptModel,
                             prompt: normalizePrompt, hint: scriptHint, input: inputText, output: scriptText,
                             images: nil)
        }
        backlogStore.add(e); backlog = backlogStore.entries
        statusText = "백로그에 기록됨 (\(stage == .explain ? "해설" : "대본"))"
    }

    func updateBacklog(_ e: BacklogEntry) { backlogStore.update(e); backlog = backlogStore.entries }
    func deleteBacklog(_ id: String) { backlogStore.delete(id); backlog = backlogStore.entries }
    func clearBacklog() { backlogStore.clear(); backlog = backlogStore.entries }
    func exportBacklog(_ items: [BacklogEntry]) -> URL? { backlogStore.export(items) }
    var backlogTags: [String] { backlogStore.allTags }

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
                self.historyRevision += 1
            } catch is CancellationError {
                self.finish()
            } catch {
                self.phase = .idle
                self.statusText = "오류: \(error.localizedDescription)"
            }
        }
    }

    private func makeNormalizer(instruction: String) -> Normalizing? {
        switch scriptProvider {
        case .gemini:
            guard let key = Secrets.geminiKey else { return nil }
            return GeminiNormalizer(baseURL: geminiBaseURL, apiKey: key, model: geminiModel,
                                    instruction: instruction, temperature: scriptTemperature)
        case .ollama:
            return TextNormalizer(
                baseURL: URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")!,
                model: ollamaModel, instruction: instruction, temperature: scriptTemperature)
        }
    }

    /// Normalize instruction with the optional per-run 대본 hint folded in. The
    /// hint goes FIRST as highest-priority: appended after the base rules, the
    /// base "영어는 그대로 둠 / 의미 보존" rules drown it out (verified w/ gemma —
    /// top placement is followed, trailing placement is ignored).
    private func scriptInstruction() -> String {
        let h = scriptHint.trimmingCharacters(in: .whitespacesAndNewlines)
        return h.isEmpty ? normalizePrompt
            : "[가장 중요한 지시 — 아래 규칙과 충돌하면 이 지시를 최우선으로 따른다]\n\(h)\n\n\(normalizePrompt)"
    }

    func saveGeminiKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Secrets.writeKey(named: "gemini_key", k)
        geminiKeyPresent = !k.isEmpty
        if !k.isEmpty { refreshGeminiModels() }   // populate the combined model list right away
    }

    // MARK: - Commentary (코드 → 해설)

    private func makeExplainer() -> Explaining? {
        switch explainProvider {
        case .gemini:
            guard let key = Secrets.geminiKey else { return nil }
            return GeminiExplainer(baseURL: geminiBaseURL, apiKey: key, model: explainGeminiModel,
                                   instruction: explainPrompt, temperature: explainTemperature)
        case .ollama:
            return OllamaExplainer(
                baseURL: URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")!,
                model: explainOllamaModel, instruction: explainPrompt, temperature: explainTemperature)
        }
    }

    /// Single-stage image explain: the 해설 model (== vision model) reads the
    /// screenshot(s) and explains in one streamed call, using the explain prompt.
    private func explainStreamWithImages(code: String, images: [Data]) -> AsyncThrowingStream<String, Error> {
        let prompt = CodeExplanation.prompt(explainPrompt, code, hint: explainHint)
        switch explainProvider {
        case .gemini:
            guard let key = Secrets.geminiKey else {
                return AsyncThrowingStream { $0.finish() }
            }
            return LLM.geminiStream(baseURL: geminiBaseURL, apiKey: key, model: explainGeminiModel,
                                    prompt: prompt, images: images, temperature: explainTemperature)
        case .ollama:
            let url = URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")!
            return LLM.ollamaChatStream(baseURL: url, model: explainOllamaModel,
                                        prompt: prompt, images: images, temperature: explainTemperature)
        }
    }

    /// Stable digest of the attached screenshots, for caching the transcription.
    private func imagesDigest(_ imgs: [Data]) -> String {
        var h = SHA256()
        for d in imgs { h.update(data: d) }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Stage 1 of image-explain: the VISION model transcribes the screenshot(s) to
    /// text (the code + any relevant screen content). Cached by image digest so a
    /// re-run skips the vision call. The text then feeds the normal explain stage.
    private func transcribeImages(_ imgs: [Data]) async -> String? {
        let visionProv = visionProviderEff
        let visionModel = visionModelEff
        let tkey = NormalizationCache.key(text: imagesDigest(imgs),
                                          provider: "vision:" + visionProv.rawValue,
                                          model: visionModel, prompt: "transcribe")
        if let cached = normCache.script(forKey: tkey) { return cached }
        let prompt = """
        이미지를 텍스트로 옮기는 작업입니다. 여러 장이 첨부될 수 있으며, 서로 보완하는 자료(코드 화면 + 필기
        메모·그림 + 책/교재 페이지 등)일 수 있으니 모든 이미지를 빠짐없이 반영하세요. 반드시 아래 세 섹션으로 나눠 출력하세요.

        [코드]
        보이는 코드를 들여쓰기·줄바꿈 그대로 옮겨 적습니다. 코드가 아닌 화면 요소(파일명·출력·오류 등)는 짧게 덧붙입니다.

        [강조 표시]
        사용자가 손으로 그린 강조(박스·화살표·동그라미·밑줄·색칠·필기 메모 등)를 빠짐없이 적습니다. 각 강조가
        어떤 코드/변수/요소를 가리키는지, 적힌 메모 내용, 그리고 무엇을 비교·대조하거나 왜 강조했는지를 구체적으로
        설명합니다. 예: "x1, x2 컬럼을 빨간 박스로, label 컬럼을 초록 박스로 묶고 'label ∈ {0,1}', 'y ∈ float'라고 적어
        분류(라벨)와 회귀(연속값 y)의 차이를 대조함". 손으로 그린 강조가 전혀 없으면 정확히 "없음"이라고만 적습니다.

        [참고 자료]
        코드가 아닌 설명 자료(책/교재 페이지, 개념 그림, 긴 설명 텍스트 등)가 있으면, 코드 이해에 도움이 되는 핵심
        내용을 요약해 적습니다(관련 개념·기법·용어·정의 등). 없으면 정확히 "없음".

        해설·설명 문장은 쓰지 말고 위 세 섹션 형식으로만 출력합니다.
        """
        let stream: AsyncThrowingStream<String, Error>
        switch visionProv {
        case .gemini:
            guard let key = Secrets.geminiKey else { statusText = "Gemini 키 미설정"; return nil }
            stream = LLM.geminiStream(baseURL: geminiBaseURL, apiKey: key, model: visionModel,
                                      prompt: prompt, images: imgs, temperature: 0)
        case .ollama:
            let url = URL(string: ollamaURL) ?? URL(string: "http://localhost:11434")!
            stream = LLM.ollamaChatStream(baseURL: url, model: visionModel,
                                          prompt: prompt, images: imgs, temperature: 0)
        }
        var acc = ""
        do {
            for try await delta in stream { try Task.checkCancellation(); acc += delta }
        } catch is CancellationError {
            return nil
        } catch {
            statusText = "이미지 인식 오류: \(error.localizedDescription)"; return nil
        }
        let out = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }
        // Non-vision models (e.g. gemma4) silently reply "이미지가 없다" instead of
        // erroring — catch that so we don't explain a refusal as if it were code.
        let refusal = ["이미지가 첨부", "이미지를 첨부", "이미지가 없", "이미지가 보이지", "첨부되지 않",
                       "no image", "can't see", "cannot see", "don't see"]
        if out.count < 400, refusal.contains(where: { out.contains($0) }) {
            statusText = "비전 모델이 이미지를 못 읽었습니다 — 비전 모델을 gemma3 등 비전 지원 모델로 바꾸세요"
            return nil
        }
        normCache.put(key: tkey, script: out)
        return out
    }

    // Public entry points (sync): manage the single long-lived `explainTask`,
    // serialized so a new run waits for the previous to fully unwind (no two
    // writers racing into `explanationText`). The streaming workers below stream
    // deltas straight into `explanationText` and finalize (strip + cache) at end.

    func generateExplanation(force: Bool = false) {
        let prior = explainTask
        explainTask = Task { [weak self] in
            prior?.cancel(); await prior?.value
            _ = await self?.runExplain(force: force)
        }
    }

    func continueExplanation(force: Bool = false) {
        let prior = explainTask
        explainTask = Task { [weak self] in
            prior?.cancel(); await prior?.value
            _ = await self?.runContinue(force: force)
        }
    }

    /// Stream a full 해설 (코드→해설) into `explanationText`. Returns the finalized
    /// text, or nil on failure/cancel. Code is sent verbatim (no cleanInput).
    @discardableResult
    private func runExplain(force: Bool) async -> String? {
        let typed = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = codeImages
        guard !typed.isEmpty || !imgs.isEmpty else { explanationText = ""; return nil }
        guard let explainer = makeExplainer() else {
            statusText = explainProvider == .gemini ? "Gemini 키 미설정" : "Ollama 미설정"
            return nil
        }
        explaining = true
        defer { explaining = false }

        // If a screenshot is attached AND the vision model is the same as the 해설
        // model, that model can both read the image and explain in ONE call — skip
        // the transcribe stage (less loss, faster). Otherwise: vision transcribes,
        // then the text model explains.
        let singleStage = !imgs.isEmpty
            && visionProviderEff == explainProvider && visionModelEff == explainModel

        var code = typed
        if !imgs.isEmpty && !singleStage {
            statusText = "이미지에서 코드 추출 중…"
            guard let transcribed = await transcribeImages(imgs) else {
                if statusText.isEmpty { statusText = "이미지 인식 실패" }
                return nil
            }
            code = typed.isEmpty ? transcribed : typed + "\n\n" + transcribed
        } else if singleStage {
            code = typed.isEmpty
                ? "(첨부된 스크린샷을 모두 보고 해설하세요. 코드는 정확히 읽고, 손으로 그린 강조가 있으면 해설의 중심에 두며, 책·교재·설명 자료가 함께 있으면 그 내용을 해설의 배경·맥락으로 연결해 활용하세요. 여러 장이면 서로 보완하는 자료이니 빠짐없이 반영합니다.)"
                : typed
        }
        guard !code.isEmpty else { statusText = "해설 생성 실패 (빈 입력)"; return nil }

        // Cache key: single-stage feeds the raw image, so fold its digest in.
        let provider = "explain:" + explainProvider.rawValue
        let keyText = singleStage ? code + imagesDigest(imgs) : code
        let nk = NormalizationCache.key(text: keyText, provider: provider, model: explainModel,
                                        prompt: explainPrompt + "\u{1F}" + explainHint)
        if !force, let cached = normCache.script(forKey: nk) {
            explanationText = cached; lastExplainedCode = code; lastSegment = cached; return cached
        }
        explanationText = ""
        statusText = "해설 생성 중…"
        var acc = ""
        do {
            let stream = singleStage
                ? explainStreamWithImages(code: code, images: imgs)
                : explainer.stream(code, hint: explainHint)
            for try await delta in stream {
                try Task.checkCancellation()
                acc += delta
                explanationText = acc          // live (raw markdown shows until finalize)
            }
        } catch is CancellationError {
            return nil
        } catch {
            statusText = "해설 오류: \(error.localizedDescription)"
            return nil
        }
        let out = CodeExplanation.stripMarkdown(acc)
        guard !out.isEmpty else { statusText = "해설 생성 실패 (빈 응답)"; return nil }
        normCache.put(key: nk, script: out)
        explanationText = out          // finalize (stripped)
        lastExplainedCode = code       // baseline for "이어서 해설"
        lastSegment = out
        statusText = ""
        return out
    }

    /// Stream only the added/changed part (이어서 해설), appending to the running
    /// narration. First run (no baseline) falls back to a full explain. On the
    /// "변경 없음" sentinel or cancel, rolls the streamed text back to the original.
    @discardableResult
    private func runContinue(force: Bool) async -> String? {
        let current = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return nil }
        guard canContinueExplain else { return await runExplain(force: force) }
        guard let explainer = makeExplainer() else {
            statusText = explainProvider == .gemini ? "Gemini 키 미설정" : "Ollama 미설정"
            return nil
        }
        let provider = "explain-cont:" + explainProvider.rawValue
        let keyText = lastExplainedCode + "\u{1F}" + current
        let nk = NormalizationCache.key(text: keyText, provider: provider, model: explainModel,
                                        prompt: "continue\u{1F}" + explainHint)
        if !force, let cached = normCache.script(forKey: nk) {
            applyContinuation(cached, newBaseline: current); return cached
        }
        explaining = true
        defer { explaining = false }
        let original = explanationText
        let base = original.isEmpty ? "" : original + "\n\n"
        statusText = "이어서 해설 생성 중…"
        var acc = ""
        do {
            for try await delta in explainer.streamContinuing(previous: lastExplainedCode, current: current, hint: explainHint) {
                try Task.checkCancellation()
                acc += delta
                explanationText = base + acc
            }
        } catch is CancellationError {
            explanationText = original          // roll back the streamed text
            return nil
        } catch {
            explanationText = original
            statusText = "이어서 해설 오류: \(error.localizedDescription)"
            return nil
        }
        let out = CodeExplanation.stripMarkdown(acc)
        if out.isEmpty || out.hasPrefix(CodeExplanation.noChange) {
            explanationText = original          // nothing to add → restore
            statusText = out.isEmpty ? "이어서 해설 실패 (빈 응답)" : "변경 없음 — 추가할 해설 없음"
            lastExplainedCode = current         // advance baseline anyway
            return out
        }
        normCache.put(key: nk, script: out)
        explanationText = base + out            // finalize (stripped)
        lastSegment = out
        lastExplainedCode = current
        statusText = "이어서 해설 추가됨"
        return out
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

    /// Start a fresh narration: clear the commentary and baseline.
    func clearCommentary() {
        explainTask?.cancel()
        explanationText = ""
        lastExplainedCode = ""
        lastSegment = ""
        statusText = ""
    }

    func removeImage(at index: Int) { if codeImages.indices.contains(index) { codeImages.remove(at: index) } }
    func clearImages() { codeImages.removeAll() }

    /// Attach any images on the clipboard as PNG. Returns true if any were added.
    /// Used by the ⌘V monitor (해설 탭) and the 붙여넣기 button.
    @discardableResult
    func pasteImagesFromClipboard() -> Bool {
        let objs = NSPasteboard.general.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
        var added = false
        for img in objs where !img.size.equalTo(.zero) {
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                codeImages.append(png); added = true
            }
        }
        return added
    }

    /// 해설 탭 "이어서 읽기": read the latest segment — the delta from the last
    /// "이어서 해설" (or the whole thing after a full explain). If audio is playing,
    /// it stops and reads this segment from the start. Leaves the 생성 탭 panels
    /// untouched; synthesize() owns the single playback task.
    func speakContinue() {
        let seg = lastSegment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seg.isEmpty else { return }
        playbackMode = .explain
        synthesize(TextSplitter.cleanInput(seg))   // read the latest 해설 segment directly
    }

    /// 해설 탭 → 생성 탭: hand the commentary to the script pipeline as its source.
    func sendExplanationToGenerate() {
        let ex = explanationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ex.isEmpty else { return }
        inputText = ex          // prepareScript cleans/normalizes this prose downstream
        scriptText = ""
        selectedTab = 0         // switch to TTS
    }

    /// 해설 탭 "전체 재생": read the 해설 directly (no normalize pass). The 음성 대본
    /// (정규화된 TTS 대본) lives in the TTS 탭 — send the 해설 there with "TTS로
    /// 보내기" when you want that. Does not touch the TTS 탭 panels.
    func speakExplanation() {
        let text = TextSplitter.cleanInput(explanationText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        playbackMode = .explain
        synthesize(text)
    }

    /// Services entry ("코드 해설"): stream the explanation of the selected code,
    /// then read the 해설 directly (음성 대본 is an opt-in panel step, not used in
    /// the one-shot). Code is fed RAW; a failed/cancelled explanation never falls
    /// through to speaking the source. Runs under `explainTask` so 중지 cancels it.
    func explainAndSpeak(_ code: String) {
        task?.cancel(); player.stop()
        playbackMode = .explain
        codeText = code             // raw — no cleanInput
        explanationText = ""
        phase = .synthesizing
        statusText = "해설 생성 중…"
        let prior = explainTask
        explainTask = Task { [weak self] in
            prior?.cancel(); await prior?.value
            guard let self else { return }
            guard let explanation = await self.runExplain(force: false), !Task.isCancelled else {
                self.phase = .idle
                if self.statusText.isEmpty { self.statusText = "해설 생성 실패" }
                return                  // do NOT speak raw code
            }
            self.synthesize(TextSplitter.cleanInput(explanation))
        }
    }

    // MARK: - Script (TTS-friendly text)

    /// Snapshot what the current 대본 was built from, so the UI can flag it stale
    /// when 원본 or 추가 지시 changes.
    private func markScriptFresh() { scriptBuiltFrom = inputText + "\u{1F}" + scriptHint }

    /// Build the TTS 대본 from inputText: normalize the WHOLE document in one
    /// streaming LLM call when enabled, else pass the original through. Streams
    /// straight into `scriptText`. Audio synthesis chunks by paragraph downstream.
    @discardableResult
    func prepareScript(force: Bool = false) async -> String {
        inputText = TextSplitter.cleanInput(inputText)   // tidy pasted markdown/math in the source panel
        let src = inputText
        guard !src.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { scriptText = ""; return "" }
        let instruction = scriptInstruction()
        guard normalizeEnabled, let norm = makeNormalizer(instruction: instruction) else {
            scriptText = src; markScriptFresh(); return src
        }

        let provider = scriptProvider.rawValue
        let model = scriptModel
        // Normalize the WHOLE 대본 in one call so the model has full context —
        // per-paragraph calls applied instructions unevenly (the hint landed on
        // some paragraphs, missed others). Audio synthesis still chunks by
        // paragraph downstream; only the text rewrite is whole-document here.
        let nk = NormalizationCache.key(text: src, provider: provider, model: model, prompt: instruction)
        if !force, let cached = normCache.script(forKey: nk) {
            scriptText = cached; markScriptFresh(); return cached
        }
        normalizing = true
        defer { normalizing = false }
        scriptText = ""
        var acc = ""
        do {
            for try await delta in norm.normalizeStream(src) {
                try Task.checkCancellation()
                acc += delta
                scriptText = acc                       // live, whole document
            }
        } catch is CancellationError {
            return scriptText                          // keep whatever streamed (stays stale)
        } catch {
            scriptText = src; markScriptFresh()        // error → fall back to original
            return src
        }
        let out = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalScript = out.isEmpty ? src : out
        markScriptFresh()
        normCache.put(key: nk, script: finalScript)
        scriptText = finalScript
        return finalScript
    }

    /// 대본 생성 (sync entry): manage the single `scriptTask`, serialized so a new
    /// run waits for the previous to unwind. `force` ignores the cache.
    func generateScript(force: Bool = false) {
        let prior = scriptTask
        scriptTask = Task { [weak self] in
            prior?.cancel(); await prior?.value
            _ = await self?.prepareScript(force: force)
        }
    }

    /// "재생성/다듬기" (sync entry): if a 대본 already exists, REFINE it (원본 +
    /// 현재 대본 + 추가 지시 → 미흡한 부분만 개선); otherwise regenerate fresh from 원본.
    func regenerateScript() {
        let prior = scriptTask
        scriptTask = Task { [weak self] in
            prior?.cancel(); await prior?.value
            guard let self else { return }
            if self.scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = await self.prepareScript(force: true)
            } else {
                _ = await self.runRefineScript()
            }
        }
    }

    /// Refine instruction: the FULL normalize instruction (all rules + hint at
    /// top, via scriptInstruction) PLUS a note that the input carries 원본 + 현재
    /// 대본. Carrying the base rules is essential — without them the refine
    /// regressed already-normalized parts (e.g. .score() → '점 스코어 괄호').
    private func refineInstruction() -> String {
        scriptInstruction()
            + "\n\n추가로, '원문' 영역에는 [원본]과 [현재 대본]이 함께 주어집니다."
            + " [현재 대본]을 기준으로 위 규칙과 추가 지시를 빠짐없이 적용해 더 낫게 다듬어 다시 쓰세요."
            + " 이미 규칙에 맞는 부분은 그대로 둡니다."
    }

    /// Stream a refined 대본 from 원본 + the current 대본 (no cache — it's a moving
    /// target). On cancel/error, restores the pre-refine 대본.
    @discardableResult
    private func runRefineScript() async -> String? {
        let current = scriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return nil }
        guard let norm = makeNormalizer(instruction: refineInstruction()) else {
            statusText = scriptProvider == .gemini ? "Gemini 키 미설정" : "Ollama 미설정"
            return nil
        }
        let combined = "[원본]\n\(inputText)\n\n[현재 대본]\n\(current)"
        normalizing = true
        defer { normalizing = false }
        statusText = "대본 다듬는 중…"
        var acc = ""
        do {
            for try await delta in norm.normalizeStream(combined) {
                try Task.checkCancellation()
                acc += delta
                scriptText = acc
            }
        } catch is CancellationError {
            scriptText = current        // restore
            return nil
        } catch {
            scriptText = current
            statusText = "다듬기 오류: \(error.localizedDescription)"
            return nil
        }
        let out = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = out.isEmpty ? current : out
        scriptText = final
        markScriptFresh()
        statusText = ""
        return final
    }

    /// Generate-tab "재생": speak the script (or the original if it is empty).
    func speakScript() {
        playbackMode = .tts
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
        playbackMode = .tts
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
        playbackMode = .tts
        guard let url = cache.fileURL(forKey: e.id) else { statusText = "오디오 파일 없음"; return }
        cache.touch(e.id); historyRevision += 1
        inputText = e.text; currentText = e.text
        chunkCount = 1; chunkIndex = 1; progress = 0
        player.start(expected: 1)
        player.enqueue(url)
        phase = .playing; statusText = "캐시에서 재생"; startTimer()
    }

    func stop() { explainTask?.cancel(); scriptTask?.cancel(); task?.cancel(); player.stop(); finish() }

    // HUD transport: paragraph navigation.
    var canSkipNext: Bool { isBusy && player.canNext }
    var canSkipPrev: Bool { isBusy && player.canPrev }
    func skipNext() { guard player.canNext else { return }; player.next(); resumeIfPaused() }
    func skipPrev() { guard player.canPrev else { return }; player.prev(); resumeIfPaused() }
    private func resumeIfPaused() {
        if phase == .paused { phase = .playing; startTimer() }
        tick()
    }

    func deleteHistory(_ id: String) { cache.delete(id); historyRevision += 1 }
    func clearHistory() { cache.clear(); historyRevision += 1 }

    /// History view queries (search / sort / paginate via SQLite).
    func historyPage(search: String, sort: HistorySort, limit: Int, offset: Int) -> [HistoryEntry] {
        cache.page(search: search, sort: sort, limit: limit, offset: offset)
    }
    func historyTotal(search: String) -> Int { cache.total(search: search) }

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
            "explainProvider": explainProvider.rawValue, "scriptProvider": scriptProvider.rawValue,
            "visionProvider": visionProvider.rawValue, "visionOverridden": visionOverridden,
            "geminiBaseURL": geminiBaseURL,
            "explainGeminiModel": explainGeminiModel, "explainOllamaModel": explainOllamaModel,
            "explainVisionGeminiModel": explainVisionGeminiModel,
            "explainVisionOllamaModel": explainVisionOllamaModel,
            "explainTemperature": explainTemperature, "scriptTemperature": scriptTemperature,
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
        // Per-role providers default from the old single normalizeProvider (migration),
        // so an existing Ollama/gemma4 setup keeps running with no user action.
        explainProvider = NormalizeProvider(rawValue: o["explainProvider"] as? String ?? "") ?? normalizeProvider
        scriptProvider = NormalizeProvider(rawValue: o["scriptProvider"] as? String ?? "") ?? normalizeProvider
        visionProvider = NormalizeProvider(rawValue: o["visionProvider"] as? String ?? "") ?? explainProvider
        visionOverridden = o["visionOverridden"] as? Bool ?? false
        geminiModel = o["geminiModel"] as? String ?? geminiModel
        geminiBaseURL = o["geminiBaseURL"] as? String ?? geminiBaseURL
        explainGeminiModel = o["explainGeminiModel"] as? String ?? explainGeminiModel
        explainOllamaModel = o["explainOllamaModel"] as? String ?? explainOllamaModel
        explainVisionGeminiModel = o["explainVisionGeminiModel"] as? String ?? explainVisionGeminiModel
        explainVisionOllamaModel = o["explainVisionOllamaModel"] as? String ?? explainVisionOllamaModel
        explainTemperature = o["explainTemperature"] as? Double ?? explainTemperature
        scriptTemperature = o["scriptTemperature"] as? Double ?? scriptTemperature
        voiceSettings.stability = o["stability"] as? Double ?? voiceSettings.stability
        voiceSettings.similarityBoost = o["similarity"] as? Double ?? voiceSettings.similarityBoost
        voiceSettings.style = o["style"] as? Double ?? voiceSettings.style
        voiceSettings.useSpeakerBoost = o["speakerBoost"] as? Bool ?? voiceSettings.useSpeakerBoost
    }
}

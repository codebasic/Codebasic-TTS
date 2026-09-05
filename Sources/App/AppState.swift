import Foundation
import Combine
import CryptoKit
import AppKit

/// 용어 → 발음 한 쌍. 대본(정규화) LLM에 few-shot 사전으로 주입되어 코드 명칭·
/// 고유명사 발음을 일관되게 만든다. settings.json의 "glossary"에 저장된다.
struct GlossaryEntry: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var term: String
    var pronunciation: String
    var note: String = ""
}

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

    // TTS-friendly text normalization (LLM endpoints: dynamic, user-managed).
    // An endpoint = baseURL + API key (own <id>.key file) + apiStyle; the legacy
    // gemini/zai/ollama fields were migrated into 3 seeded endpoints on first
    // run (seedEndpoints) and the old settings keys are read as seed data only.
    @Published var endpoints: [CustomEndpoint] = []
    @Published private var endpointModels: [String: [String]] = [:]   // endpoint id → live models.list
    @Published private(set) var endpointStatus: [String: String] = [:] // endpoint id → 연결 확인 status
    @Published var normalizeEnabled = false
    @Published var normalizePrompt = TextNormalizer.defaultInstruction
    @Published var normalizing = false
    @Published var scriptHint = ""               // 대본 단계 (원문→대본) 추가 지시
    /// 대본 few-shot 용어 발음 사전 (glossary). 대본(정규화) 단계에만 프롬프트에
    /// 주입된다 — 해설 단계는 코드 해설이라 제외.
    @Published var glossary: [GlossaryEntry] = []
    /// glossary 키가 settings.json에 아직 없을 때만 심는 기본 예시
    /// (defaultInstruction의 예시 활용). 빈 배열 저장은 "전부 삭제"로 존중됨.
    static let seedGlossary: [GlossaryEntry] = [
        GlossaryEntry(term: "np", pronunciation: "넘파이"),
        GlossaryEntry(term: "pd", pronunciation: "판다스"),
        GlossaryEntry(term: "sklearn", pronunciation: "싸이킷런"),
        GlossaryEntry(term: "plt", pronunciation: "매트플롯립"),
        GlossaryEntry(term: "tf", pronunciation: "텐서플로우"),
    ]
    private var scriptBuiltFrom = ""             // (원본 ∥ 지시) the 대본 was built from
    /// True when 원본 or 추가 지시 changed after the 대본 was generated. Suppressed
    /// while generating — scriptText fills before scriptBuiltFrom is stamped.
    var scriptStale: Bool {
        !normalizing
            && !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && scriptBuiltFrom != (inputText + "\u{1F}" + scriptHint)
    }

    // Commentary (코드 → 해설). Shares the endpoint pool above, but the explain
    // model is SEPARATE from the script model — they can differ.
    @Published var codeText = ""                 // source code (해설 panel, top)
    @Published var explanationText = ""          // generated commentary (해설 panel, bottom)
    @Published var explaining = false
    @Published var explainPrompt = CodeExplanation.defaultInstruction
    @Published var explainHint = ""              // 해설 단계 (코드→해설) 추가 지시
    @Published var explainAutoPlay = true        // 단축키/Services 해설: 생성 직후 바로 재생(끄면 검토 후 수동 재생)

    /// Set by AppDelegate: bring the management window forward so a review-only
    /// 해설 (explainAutoPlay == false) is visible to read/check before playing.
    var onRequestReview: (() -> Void)?
    @Published var explainTemperature: Double = 0.4          // 해설 LLM 생성 매개변수
    @Published var scriptTemperature: Double = 0.2           // 대본 LLM 생성 매개변수
    /// 역할별 reasoning(thinking) 수준 — 공급자별 파라미터로 변환해 요청에 실린다
    /// (ReasoningLevel 참고). 엔드포인트별이 아닌 역할별로 단순하게.
    @Published var explainReasoningLevel: ReasoningLevel = .medium   // 해설 (+single-stage 해설)
    @Published var scriptReasoningLevel: ReasoningLevel = .medium    // 대본 정규화
    @Published var visionReasoningLevel: ReasoningLevel = .medium    // 스크린샷 전사 (비전)
    @Published var codeImages: [Data] = []       // pasted code screenshots (PNG); needs a vision model
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

    // Per-role endpoint reference + model memory. A role points at an endpoint
    // (id) and remembers the model last picked for it; an unset role model
    // inherits the endpoint's defaultModel (구 zaiModel 폴백의 일반화).
    @Published var explainEndpointID = ""
    @Published var scriptEndpointID = ""
    @Published var visionEndpointID = ""
    @Published var visionOverridden = false       // false = vision follows the 해설 model
    @Published var explainRoleModels: [String: String] = [:]   // endpoint id → model
    @Published var scriptRoleModels: [String: String] = [:]
    @Published var visionRoleModels: [String: String] = [:]

    // MARK: Endpoint resolution

    func endpoint(byID id: String) -> CustomEndpoint? {
        endpoints.first { $0.id.uuidString == id }
    }

    /// Only ENABLED endpoints resolve for generation/pickers; a disabled one
    /// behaves like a missing one.
    func activeEndpoint(byID id: String) -> CustomEndpoint? {
        endpoints.first { $0.id.uuidString == id && $0.isEnabled }
    }

    func endpointKey(_ e: CustomEndpoint) -> String {
        Secrets.endpointKey(e.id) ?? ""
    }

    /// A role's model on `e`: its own remembered pick, or the endpoint's 기본
    /// 모델 when unset. Every LLM call must go through this — a raw empty role
    /// field would be sent to the API as `"model": ""`.
    func roleModel(_ role: [String: String], _ e: CustomEndpoint) -> String {
        let m = role[e.id.uuidString] ?? ""
        return m.isEmpty ? e.defaultModel : m
    }

    /// True when the 기본 모델 is usable: unset, in the fetched list, or not yet
    /// checkable (no list). Drives the per-endpoint SettingsView warning.
    func endpointDefaultModelValid(_ e: CustomEndpoint) -> Bool {
        let ms = endpointModels[e.id.uuidString] ?? []
        return e.defaultModel.isEmpty || ms.isEmpty || ms.contains(e.defaultModel)
    }

    /// Effective endpoint/model per role (role's own memory → endpoint default).
    var scriptModel: String {
        guard let e = activeEndpoint(byID: scriptEndpointID) else { return "" }
        return roleModel(scriptRoleModels, e)
    }
    var explainModel: String {
        guard let e = activeEndpoint(byID: explainEndpointID) else { return "" }
        return roleModel(explainRoleModels, e)
    }
    var visionEndpointEff: CustomEndpoint? {
        visionOverridden ? activeEndpoint(byID: visionEndpointID) : activeEndpoint(byID: explainEndpointID)
    }
    var visionModelEff: String {
        if !visionOverridden { return explainModel }
        guard let e = activeEndpoint(byID: visionEndpointID) else { return "" }
        return roleModel(visionRoleModels, e)
    }

    /// A pick in a model selector: an (endpoint, model) pair. Identity carries
    /// the endpoint so models from different endpoints never collide.
    struct LLMChoice: Hashable, Identifiable {
        let endpointID: String
        let endpointName: String
        let model: String
        var id: String { endpointID + "\u{1F}" + model }
        var label: String { "\(model) · \(endpointName)" }
    }

    /// Well-known model names for a style, used ONLY to pick a sensible 기본 모델
    /// out of a freshly fetched list (see refreshEndpointModels) — never shown as
    /// a standalone picker entry, since these names are provider-specific and an
    /// arbitrary OpenAI-호환 endpoint (내 vLLM 등) does not serve them.
    func preferredModels(_ e: CustomEndpoint) -> [String] {
        switch e.apiStyle {
        case .gemini: return GeminiNormalizer.models
        case .openAICompatible: return ZAINormalizer.fallbackModels
        case .ollama: return []
        }
    }

    /// All models from enabled endpoints. Before a successful models.list the
    /// only model we can honestly offer is the endpoint's own 기본 모델 — that
    /// also makes a keyless/offline endpoint selectable once the user types one.
    var connectedModels: [LLMChoice] {
        var out: [LLMChoice] = []
        for e in endpoints where e.isEnabled {
            let fetched = endpointModels[e.id.uuidString] ?? []
            let ms = fetched.isEmpty ? (e.defaultModel.isEmpty ? [] : [e.defaultModel]) : fetched
            out += ms.map { LLMChoice(endpointID: e.id.uuidString, endpointName: e.name, model: $0) }
        }
        return out
    }

    func refreshAllModels() {
        for e in endpoints where e.isEnabled { refreshEndpointModels(e) }
    }
    func refreshAllModelsIfNeeded() {
        for e in endpoints
        where e.isEnabled && (endpointModels[e.id.uuidString] ?? []).isEmpty {
            // Fetching a keyed endpoint without a key just errors — wait for the key.
            if e.apiStyle == .gemini && endpointKey(e).isEmpty { continue }
            refreshEndpointModels(e)
        }
    }

    // Runtime
    enum Phase: Equatable { case idle, synthesizing, playing, paused }
    @Published var phase: Phase = .idle
    /// High-frequency playback values (progress/chunkProgress/chunkSeconds) live on
    /// a SEPARATE ObservableObject so the 10 Hz tick doesn't invalidate every view
    /// observing AppState. Only PlayerOverlay observes this. See PlaybackTelemetry.
    let telemetry = PlaybackTelemetry()

    /// What the current playback is — shown in the HUD instead of the script text.
    enum PlaybackMode { case tts, explain
        var label: String { self == .tts ? "TTS" : "해설" }
        var icon: String { self == .tts ? "speaker.wave.2.fill" : "text.book.closed.fill" }
    }
    @Published var playbackMode: PlaybackMode = .tts

    // HUD subtitles: show the paragraph being read (toggle per mode).
    @Published var subtitleTTS = true
    @Published var subtitleExplain = true
    @Published var subtitleFontSize: Double = 17    // points; adjustable from the HUD (A-/A+)
    static let subtitleFontRange: ClosedRange<Double> = 11...48

    // HUD placement. The HUD follows the focused app per command: at trigger time
    // we capture which screen the command happened on, and the HUD shows there
    // (so in a lecture it lands on the screen the learners see). The user can drag
    // it; its position is remembered per screen so each monitor keeps its own spot.
    var hudTargetScreenID: CGDirectDisplayID?            // screen the current command targets
    var hudPositions: [CGDirectDisplayID: CGPoint] = [:] // bottom-left offset within each screen's visibleFrame
    @Published var spokenChunks: [String] = []   // the spoken (대본) paragraph chunks — drives crawlFraction
    @Published var subtitleText = ""             // the human-readable subtitle source (원본/해설), shown as the crawl
    @Published var chunkSentenceTimes: [[Double]] = []  // exact sentence start times per chunk (ElevenLabs); [] = estimate
    var showSubtitle: Bool { playbackMode == .tts ? subtitleTTS : subtitleExplain }

    // MARK: - Continuous crawl (teleprompter over the WHOLE script)

    /// One subtitle sentence. The subtitle is the human-readable source
    /// (`subtitleText`: 원본/해설), NOT the spoken 대본, so it never has to align with
    /// the audio chunking — the crawl position is driven by overall progress.
    struct CrawlLine: Identifiable {
        let id: Int        // global order (0-based)
        let text: String
    }

    /// Memoized sentence split of the current subtitle. `TextSplitter.sentences`
    /// is an O(N) char scan; the crawl reads it every 0.1s frame (and used to
    /// re-split once PER line for the current-line test), so recomputing it per
    /// frame stalls the main thread and janks the subtitle + typing. Recompute
    /// only when `subtitleText` actually changes.
    private var sentenceCacheKey: String?
    private var sentenceCache: [String] = []
    private var subtitleSentences: [String] {
        if sentenceCacheKey != subtitleText {
            sentenceCacheKey = subtitleText
            sentenceCache = TextSplitter.sentences(subtitleText)
        }
        return sentenceCache
    }

    /// The full subtitle text split into sentences, flattened in reading order.
    var crawlLines: [CrawlLine] {
        subtitleSentences.enumerated().map { CrawlLine(id: $0.offset, text: $0.element) }
    }

    /// Which subtitle sentence is being read now — overall audio progress
    /// (`crawlFraction`) mapped onto the subtitle text by length.
    var currentCrawlLineID: Int {
        TextSplitter.sentenceIndex(at: crawlFraction, in: subtitleSentences)
    }
    func isCurrentLine(_ line: CrawlLine) -> Bool { line.id == currentCrawlLineID }

    /// How far through the WHOLE playback the audio is (0…1), weighted by spoken
    /// chunk length (chars) so it tracks the voice smoothly via chunkProgress —
    /// QueuePlayer.progress is chunk-equal-weighted, which lurches per paragraph.
    var crawlFraction: Double {
        CrawlLayout.fraction(chunkLengths: spokenChunks.map { Double(max(1, $0.count)) },
                             chunkIndex: chunkIndex, chunkProgress: telemetry.chunkProgress)
    }

    /// Map ElevenLabs per-character start times to one start time per sentence
    /// of `text`. Returns [] if the alignment doesn't line up (→ estimate).
    private func sentenceStartTimes(text: String, charStarts: [Double]) -> [Double] {
        let chars = Array(text)
        guard charStarts.count == chars.count else { return [] }
        let sentences = TextSplitter.sentences(text)
        var times: [Double] = []
        var offset = 0
        for s in sentences {
            while offset < chars.count, chars[offset].isWhitespace { offset += 1 }
            times.append(offset < charStarts.count ? charStarts[offset] : (times.last ?? 0))
            offset += s.count
        }
        return times.count == sentences.count ? times : []
    }

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
                             stage: "해설", provider: endpoint(byID: explainEndpointID)?.name ?? "-",
                             model: explainModel,
                             prompt: explainPrompt, hint: explainHint, input: codeText, output: explanationText,
                             images: codeImages.isEmpty ? nil : codeImages)
        case .script:
            guard !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                statusText = "기록할 대본이 없습니다"; return
            }
            e = BacklogEntry(id: UUID().uuidString, createdAt: Date(), tags: finalTags, note: note,
                             stage: "대본", provider: endpoint(byID: scriptEndpointID)?.name ?? "-",
                             model: scriptModel,
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
        phase = .idle; telemetry.reset(); statusText = ""; chunkIndex = 0; chunkCount = 0
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
        telemetry.progress = player.progress
        telemetry.chunkProgress = player.chunkFraction
        telemetry.chunkSeconds = player.chunkSeconds
        // Only assign chunkIndex when the paragraph actually turns — it lives on
        // AppState (read by GenerateView/overlay), so a 10 Hz same-value write would
        // needlessly fire AppState.objectWillChange and re-render the whole window.
        let ci = min(max(1, player.finishedCount + 1), max(1, chunkCount))
        if ci != chunkIndex { chunkIndex = ci }
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

    /// `displayText` is the human-readable source to show as the subtitle (원문 for
    /// TTS, 해설 prose for commentary) while `text` is what's actually synthesized
    /// (the 대본). When omitted, the subtitle is the spoken text.
    func synthesize(_ text: String, displayText: String? = nil) {
        // cleanInput both sides: collapse the stray line breaks a web selection or
        // an LLM 대본 carries (esp. math/markdown), so paragraph chunking is by
        // blank lines — otherwise the spoken and display chunk counts diverge and
        // the subtitle falls back to the 대본.
        let t = TextSplitter.cleanInput(text)
        guard !t.isEmpty else { return }
        let chunks = TextSplitter.paragraphs(t, maxChars: maxChunkChars)
        guard !chunks.isEmpty else { return }

        cancelActiveWork()                       // supersede any prior command (LLM/synthesis/playback)
        currentText = t                          // overlay label (the spoken text); do NOT touch inputText
        spokenChunks = chunks                    // spoken 대본 chunks (drive crawlFraction)
        // Subtitle is the human-readable source, decoupled from the audio chunking
        // — so it's always the 원본/해설, never the 대본, regardless of how the LLM
        // reformatted paragraphs (web-selected math, etc.).
        subtitleText = TextSplitter.cleanInput(displayText ?? t)
        chunkSentenceTimes = Array(repeating: [], count: chunks.count)
        telemetry.reset()
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
                for (ci, chunk) in chunks.enumerated() {
                    try Task.checkCancellation()
                    let key = CacheStore.key(text: chunk, backend: ident,
                                             voiceId: vid, modelId: mid, settingsHash: sHash)
                    var url: URL?
                    if self.useCache, let u = self.cache.fileURL(forKey: key) {
                        self.cache.touch(key); url = u   // cache hit: skip synthesizing state
                        self.chunkSentenceTimes[ci] = self.cache.times(forKey: key) ?? []
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
                        var times: [Double] = []
                        if let timed = try await b.synthesizeTimed(segment: chunk, voice: voice) {
                            try Task.checkCancellation()
                            data = timed.data
                            times = self.sentenceStartTimes(text: chunk, charStarts: timed.charStarts)
                        } else {
                            for try await c in b.stream(segment: chunk, voice: voice) {
                                try Task.checkCancellation(); data.append(c)
                            }
                        }
                        self.chunkSentenceTimes[ci] = times
                        if self.useCache {
                            let e = self.cache.save(key: key, text: chunk, backend: ident, voiceId: vid,
                                                    voiceName: vName, modelId: mid, ext: ext, data: data)
                            self.cache.saveTimes(key: key, times)
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
                // Tear playback down like finish() (stop the timer + player) but keep
                // the error message. Without stopTimer() a mid-playback synthesis
                // error left the 10 Hz timer running forever, growing memory at idle.
                self.stopTimer()
                self.player.stop()
                self.phase = .idle; self.telemetry.reset()
                self.chunkIndex = 0; self.chunkCount = 0
                self.statusText = "오류: \(error.localizedDescription)"
            }
        }
    }

    /// Build the script normalizer from the 대본 role's endpoint, branching on
    /// its apiStyle — the HTTP implementations (LLM.*) are reused as-is.
    private func makeNormalizer(instruction: String) -> Normalizing? {
        guard let e = activeEndpoint(byID: scriptEndpointID) else { return nil }
        let model = roleModel(scriptRoleModels, e)
        // A role with no pick AND an endpoint with no 기본 모델 would post
        // `"model": ""` — refuse instead of letting the server 400.
        guard !model.isEmpty else { return nil }
        switch e.apiStyle {
        case .gemini:
            guard let key = Secrets.endpointKey(e.id) else { return nil }
            return GeminiNormalizer(baseURL: e.baseURL, apiKey: key, model: model,
                                    instruction: instruction, temperature: scriptTemperature,
                                    reasoningLevel: scriptReasoningLevel)
        case .openAICompatible:
            return ZAINormalizer(baseURL: e.baseURL, apiKey: endpointKey(e), model: model,
                                 instruction: instruction, temperature: scriptTemperature,
                                 reasoningLevel: scriptReasoningLevel)
        case .ollama:
            guard let url = URL(string: e.baseURL) else { return nil }
            return TextNormalizer(baseURL: url, model: model,
                                  instruction: instruction, temperature: scriptTemperature,
                                  reasoningLevel: scriptReasoningLevel)
        }
    }

    /// few-shot 용어 발음 사전 섹션. term 순(알파벳/가나다)으로 정렬해 결정적
    /// 프롬프트를 유지하고, 용어·발음이 빈 행은 건너뛴다. 사전이 비면 "".
    private func glossaryBlock() -> String {
        let entries = glossary
            .map { GlossaryEntry(id: $0.id,
                                 term: $0.term.trimmingCharacters(in: .whitespaces),
                                 pronunciation: $0.pronunciation.trimmingCharacters(in: .whitespaces),
                                 note: $0.note) }
            .filter { !$0.term.isEmpty && !$0.pronunciation.isEmpty }
            .sorted { $0.term.localizedCaseInsensitiveCompare($1.term) == .orderedAscending }
        guard !entries.isEmpty else { return "" }
        let table = entries.map { "\($0.term) → \($0.pronunciation)" }.joined(separator: "\n")
        return "[용어 발음 사전 — 반드시 이 표기대로 변환]\n\(table)\n"
            + "위 사전에 있는 표기는 아래 일반 규칙(영어는 그대로 둠 등)보다 우선한다."
            + " 사전에 없는 표기는 아래 규칙을 따른다."
    }

    /// Normalize instruction with the optional per-run 대본 hint folded in. The
    /// hint goes FIRST as highest-priority: appended after the base rules, the
    /// base "영어는 그대로 둠 / 의미 보존" rules drown it out (verified w/ gemma —
    /// top placement is followed, trailing placement is ignored).
    /// 용어 발음 사전도 같은 이유로 base rules **앞**에 둔다: 사전은 "영어는 그대로
    /// 둠" 규칙과 정면으로 충돌하므로(np → 넘파이) 뒤에 붙이면 무시된다.
    /// 우선순위는 추가 지시 > 사전 > 기본 규칙 — 사전에 없는 표기는 기본 규칙이 맡는다.
    private func scriptInstruction() -> String {
        let h = scriptHint.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !h.isEmpty {
            parts.append("[가장 중요한 지시 — 아래 규칙과 충돌하면 이 지시를 최우선으로 따른다]\n\(h)")
        }
        let g = glossaryBlock()
        if !g.isEmpty { parts.append(g) }
        parts.append(normalizePrompt)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Endpoint management (settings UI)

    /// Register a new endpoint; its key (if any) goes to its own <id>.key file.
    func addEndpoint(name: String, baseURL: String, style: CustomEndpoint.APIStyle,
                     apiKey: String, defaultModel: String = "") {
        var e = CustomEndpoint(name: name, baseURL: baseURL, apiStyle: style)
        e.name = e.name.isEmpty ? style.label : e.name
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !k.isEmpty { Secrets.writeEndpointKey(e.id, k) }
        e.defaultModel = defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoints.append(e)
        // First endpoint ever → point the roles at it so a fresh setup works.
        if (endpoints.filter { $0.isEnabled }.count == 1)
            && !endpoints.contains(where: { $0.id.uuidString == explainEndpointID && $0.isEnabled }) {
            explainEndpointID = e.id.uuidString
            if !visionOverridden { visionEndpointID = e.id.uuidString }
            if scriptEndpointID.isEmpty || !endpoints.contains(where: { $0.id.uuidString == scriptEndpointID && $0.isEnabled }) {
                scriptEndpointID = e.id.uuidString
            }
        }
        saveSettings()
        refreshEndpointModels(e)
    }

    func deleteEndpoint(_ id: UUID) {
        endpoints.removeAll { $0.id == id }
        endpointModels[id.uuidString] = nil
        endpointStatus[id.uuidString] = nil
        explainRoleModels[id.uuidString] = nil
        scriptRoleModels[id.uuidString] = nil
        visionRoleModels[id.uuidString] = nil
        // Any role still pointing at the deleted endpoint falls back to the
        // first remaining enabled one (or the first remaining at all).
        let fallback = endpoints.first(where: { $0.isEnabled })?.id.uuidString
            ?? endpoints.first?.id.uuidString ?? ""
        if explainEndpointID == id.uuidString { explainEndpointID = fallback }
        if scriptEndpointID == id.uuidString { scriptEndpointID = fallback }
        if visionEndpointID == id.uuidString {
            // The vision OVERRIDE pointed here. Retargeting it silently would
            // pin vision to an endpoint the user never chose, so drop back to
            // 해설 추종 (the documented default) instead.
            visionEndpointID = fallback
            visionOverridden = false
        }
        saveSettings()
    }

    func saveEndpointKey(_ id: UUID, _ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Secrets.writeEndpointKey(id, k)
        guard let e = endpoint(byID: id.uuidString) else { return }
        if !k.isEmpty || e.apiStyle != .gemini { refreshEndpointModels(e) }
    }

    /// Fetch the endpoint's live models.list (openAI=`GET /models`,
    /// gemini=`GET /models`, ollama=`GET /api/tags`) and swap it into the picker.
    /// Reuses the existing per-style helpers — no new network code.
    func refreshEndpointModels(_ endpoint: CustomEndpoint) {
        let e = endpoint
        let id = e.id.uuidString
        if e.apiStyle == .gemini && endpointKey(e).isEmpty {
            endpointStatus[id] = "키 없음"
            return
        }
        endpointStatus[id] = "확인 중…"
        // Read the endpoint's URL/key HERE, on the main actor, exactly as the old
        // refreshGemini/ZAIModels did — reading them through `self?` inside the
        // Task would send an UNAUTHENTICATED request if self had gone away.
        let base = e.baseURL
        let key = endpointKey(e)
        Task { [weak self] in
            do {
                let ms: [String]
                switch e.apiStyle {
                case .openAICompatible:
                    ms = try await ZAI.models(baseURL: base, apiKey: key)
                case .gemini:
                    ms = try await Gemini.models(baseURL: base, apiKey: key)
                case .ollama:
                    ms = try await Ollama.models(baseURL: URL(string: base) ?? URL(string: "http://localhost:11434")!)
                }
                guard let self else { return }
                self.endpointModels[id] = ms
                // 기본 모델 미지정: 목록에서 채운다 (선호 모델이 목록에 있으면 그것, 없으면 첫 항목).
                if let idx = self.endpoints.firstIndex(where: { $0.id == e.id }), self.endpoints[idx].defaultModel.isEmpty {
                    let fallback = self.preferredModels(e).first(where: { ms.contains($0) }) ?? ms.first ?? ""
                    if !fallback.isEmpty {
                        self.endpoints[idx].defaultModel = fallback
                        self.saveSettings()
                    }
                }
                var status = "연결됨 · 모델 \(ms.count)개"
                if !self.endpointDefaultModelValid(e) {
                    let dm = self.endpoint(byID: id)?.defaultModel ?? ""
                    status += " · ⚠️ 기본 모델 ‘\(dm)’이 목록에 없음"
                }
                self.endpointStatus[id] = status
            } catch {
                self?.endpointStatus[id] = "연결 실패: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Commentary (코드 → 해설)

    private func makeExplainer() -> Explaining? {
        guard let e = activeEndpoint(byID: explainEndpointID) else { return nil }
        let model = roleModel(explainRoleModels, e)
        guard !model.isEmpty else { return nil }   // never post `"model": ""`
        switch e.apiStyle {
        case .gemini:
            guard let key = Secrets.endpointKey(e.id) else { return nil }
            return GeminiExplainer(baseURL: e.baseURL, apiKey: key, model: model,
                                   instruction: explainPrompt, temperature: explainTemperature,
                                   reasoningLevel: explainReasoningLevel)
        case .openAICompatible:
            return ZAIExplainer(baseURL: e.baseURL, apiKey: endpointKey(e), model: model,
                                instruction: explainPrompt, temperature: explainTemperature,
                                reasoningLevel: explainReasoningLevel)
        case .ollama:
            guard let url = URL(string: e.baseURL) else { return nil }
            return OllamaExplainer(baseURL: url, model: model,
                                   instruction: explainPrompt, temperature: explainTemperature,
                                   reasoningLevel: explainReasoningLevel)
        }
    }

    /// Single-stage image explain: the 해설 model (== vision model) reads the
    /// screenshot(s) and explains in one streamed call, using the explain prompt.
    private func explainStreamWithImages(code: String, images: [Data]) -> AsyncThrowingStream<String, Error> {
        guard let e = activeEndpoint(byID: explainEndpointID) else {
            return AsyncThrowingStream { $0.finish() }
        }
        let prompt = CodeExplanation.prompt(explainPrompt, code, hint: explainHint)
        let model = roleModel(explainRoleModels, e)
        guard !model.isEmpty else { return AsyncThrowingStream { $0.finish() } }
        switch e.apiStyle {
        case .gemini:
            guard let key = Secrets.endpointKey(e.id) else {
                return AsyncThrowingStream { $0.finish() }
            }
            return LLM.geminiStream(baseURL: e.baseURL, apiKey: key, model: model,
                                    prompt: prompt, images: images, temperature: explainTemperature,
                                    reasoningLevel: explainReasoningLevel)
        case .openAICompatible:
            return LLM.openAIChatStream(baseURL: e.baseURL, model: model, apiKey: endpointKey(e),
                                        prompt: prompt, images: images, temperature: explainTemperature,
                                        reasoningLevel: explainReasoningLevel)
        case .ollama:
            guard let url = URL(string: e.baseURL) else {
                return AsyncThrowingStream { $0.finish() }
            }
            return LLM.ollamaChatStream(baseURL: url, model: model,
                                        prompt: prompt, images: images, temperature: explainTemperature,
                                        reasoningLevel: explainReasoningLevel)
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
        guard let visionProv = visionEndpointEff else {
            statusText = "비전 엔드포인트 없음 (설정에서 엔드포인트를 확인하세요)"
            return nil
        }
        let visionModel = visionModelEff
        guard !visionModel.isEmpty else {
            statusText = "\(visionProv.name) 비전 모델 미설정 (기본 모델을 지정하세요)"
            return nil
        }
        let tkey = NormalizationCache.key(text: imagesDigest(imgs),
                                          provider: "vision:" + visionProv.id.uuidString,
                                          model: visionModel,
                                          prompt: "transcribe" + visionReasoningLevel.cacheSuffix)
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
        switch visionProv.apiStyle {
        case .gemini:
            guard let key = Secrets.endpointKey(visionProv.id) else {
                statusText = "\(visionProv.name) 키 미설정"; return nil
            }
            stream = LLM.geminiStream(baseURL: visionProv.baseURL, apiKey: key, model: visionModel,
                                      prompt: prompt, images: imgs, temperature: 0,
                                      reasoningLevel: visionReasoningLevel)
        case .openAICompatible:
            stream = LLM.openAIChatStream(baseURL: visionProv.baseURL, model: visionModel,
                                          apiKey: endpointKey(visionProv),
                                          prompt: prompt, images: imgs, temperature: 0,
                                          reasoningLevel: visionReasoningLevel)
        case .ollama:
            let url = URL(string: visionProv.baseURL) ?? URL(string: "http://localhost:11434")!
            stream = LLM.ollamaChatStream(baseURL: url, model: visionModel,
                                          prompt: prompt, images: imgs, temperature: 0,
                                          reasoningLevel: visionReasoningLevel)
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
        cancelActiveWork()
        explainTask = Task { [weak self] in _ = await self?.runExplain(force: force) }
    }

    func continueExplanation(force: Bool = false) {
        cancelActiveWork()
        explainTask = Task { [weak self] in _ = await self?.runContinue(force: force) }
    }

    /// Stream a full 해설 (코드→해설) into `explanationText`. Returns the finalized
    /// text, or nil on failure/cancel. Code is sent verbatim (no cleanInput).
    @discardableResult
    private func runExplain(force: Bool) async -> String? {
        let typed = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imgs = codeImages
        guard !typed.isEmpty || !imgs.isEmpty else { explanationText = ""; return nil }
        guard let explainer = makeExplainer(), let ep = activeEndpoint(byID: explainEndpointID) else {
            statusText = "해설 생성 불가 — 엔드포인트·모델·API 키 중 하나가 미설정입니다 (설정 확인)"
            return nil
        }
        explaining = true
        defer { explaining = false }

        // If a screenshot is attached AND the vision model is the same as the 해설
        // model, that model can both read the image and explain in ONE call — skip
        // the transcribe stage (less loss, faster). Otherwise: vision transcribes,
        // then the text model explains.
        let singleStage = !imgs.isEmpty
            && visionEndpointEff?.id == ep.id && visionModelEff == explainModel

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
        let provider = "explain:" + ep.id.uuidString
        let keyText = singleStage ? code + imagesDigest(imgs) : code
        let nk = NormalizationCache.key(text: keyText, provider: provider, model: explainModel,
                                        prompt: explainPrompt + "\u{1F}" + explainHint
                                                + explainReasoningLevel.cacheSuffix)
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
        guard !Task.isCancelled else { return nil }   // superseded just as the stream ended
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
        guard let explainer = makeExplainer(), let ep = activeEndpoint(byID: explainEndpointID) else {
            statusText = "해설 생성 불가 — 엔드포인트·모델·API 키 중 하나가 미설정입니다 (설정 확인)"
            return nil
        }
        let provider = "explain-cont:" + ep.id.uuidString
        let keyText = lastExplainedCode + "\u{1F}" + current
        let nk = NormalizationCache.key(text: keyText, provider: provider, model: explainModel,
                                        prompt: "continue\u{1F}" + explainHint
                                                + explainReasoningLevel.cacheSuffix)
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
        cancelActiveWork()
        playbackMode = .explain
        phase = .synthesizing
        let reading = TextSplitter.cleanInput(seg)
        scriptTask = Task { [weak self] in
            guard let self else { return }
            let tts = await self.ttsScript(for: reading)   // 음성용 대본은 내부에서만
            guard !Task.isCancelled else { return }
            self.synthesize(tts, displayText: reading)     // 자막은 읽기 좋은 해설
        }
    }

    /// 해설 탭 → 생성 탭: hand the commentary to the script pipeline as its source.
    func sendExplanationToGenerate() {
        let ex = explanationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ex.isEmpty else { return }
        inputText = ex          // prepareScript cleans/normalizes this prose downstream
        scriptText = ""
        selectedTab = 0         // switch to TTS
    }

    /// 해설 탭 "전체 재생": speak the 해설. The 해설 itself is reading-friendly
    /// (shown as the subtitle); the spoken audio uses an internal TTS 대본
    /// normalized from it (when 대본 정규화 is on). Does not touch the TTS 탭 panels.
    func speakExplanation() {
        let text = TextSplitter.cleanInput(explanationText)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        cancelActiveWork()
        playbackMode = .explain
        phase = .synthesizing
        scriptTask = Task { [weak self] in
            guard let self else { return }
            let tts = await self.ttsScript(for: text)   // 음성용 대본은 내부에서만
            guard !Task.isCancelled else { return }
            self.synthesize(tts, displayText: text)     // 자막은 읽기 좋은 해설
        }
    }

    /// Services entry ("코드 해설"): stream the explanation of the selected code,
    /// then read the 해설 directly (음성 대본 is an opt-in panel step, not used in
    /// the one-shot). Code is fed RAW; a failed/cancelled explanation never falls
    /// through to speaking the source. Runs under `explainTask` so 중지 cancels it.
    /// Build the speech 대본 for already-readable prose (e.g. a 해설): when 대본
    /// 정규화 is enabled, normalize it for TTS (spell numbers/symbols); else read
    /// the prose as-is. Cached by content. On cancel/error, falls back to `text`.
    private func ttsScript(for text: String) async -> String {
        let src = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let instruction = scriptInstruction()
        guard normalizeEnabled, !src.isEmpty,
              let norm = makeNormalizer(instruction: instruction) else { return text }
        let nk = NormalizationCache.key(text: src, provider: scriptEndpointID,
                                        model: scriptModel,
                                        prompt: instruction + scriptReasoningLevel.cacheSuffix)
        if let cached = normCache.script(forKey: nk) { return cached }
        normalizing = true
        defer { normalizing = false }
        statusText = "음성 대본 준비 중…"
        var acc = ""
        do {
            for try await delta in norm.normalizeStream(src) { try Task.checkCancellation(); acc += delta }
        } catch { return text }   // cancel/error → read the prose as-is
        let out = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = out.isEmpty ? text : out
        normCache.put(key: nk, script: final)
        return final
    }

    func explainAndSpeak(_ code: String) {
        cancelActiveWork()
        playbackMode = .explain
        codeText = code             // raw — no cleanInput
        explanationText = ""
        phase = .synthesizing
        statusText = "해설 생성 중…"
        explainTask = Task { [weak self] in
            guard let self else { return }
            guard let explanation = await self.runExplain(force: false), !Task.isCancelled else {
                self.phase = .idle
                if self.statusText.isEmpty { self.statusText = "해설 생성 실패" }
                return                  // do NOT speak raw code
            }
            guard self.explainAutoPlay else {       // 검토 모드: 생성만 하고 창을 띄워 보여줌
                self.phase = .idle
                self.statusText = "해설 생성 완료 — 검토 후 ‘전체 재생’"
                self.onRequestReview?()
                return
            }
            let reading = TextSplitter.cleanInput(explanation)   // 자막: 읽기 좋은 해설
            let tts = await self.ttsScript(for: reading)         // 음성: 내부 대본(정규화 토글 따름)
            guard !Task.isCancelled else { return }
            self.synthesize(tts, displayText: reading)
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
            // 정규화가 켜져 있는데 normalizer를 못 만들면(엔드포인트 비활성·모델 미지정)
            // 조용히 원문을 흘려보내지 말고 이유를 알린다.
            if normalizeEnabled {
                statusText = "대본 엔드포인트·모델 미설정 — 원문을 그대로 사용합니다"
            }
            scriptText = src; markScriptFresh(); return src
        }

        let provider = scriptEndpointID
        let model = scriptModel
        // Normalize the WHOLE 대본 in one call so the model has full context —
        // per-paragraph calls applied instructions unevenly (the hint landed on
        // some paragraphs, missed others). Audio synthesis still chunks by
        // paragraph downstream; only the text rewrite is whole-document here.
        let nk = NormalizationCache.key(text: src, provider: provider, model: model,
                                        prompt: instruction + scriptReasoningLevel.cacheSuffix)
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
        cancelActiveWork()
        scriptTask = Task { [weak self] in _ = await self?.prepareScript(force: force) }
    }

    /// "재생성/다듬기" (sync entry): if a 대본 already exists, REFINE it (원본 +
    /// 현재 대본 + 추가 지시 → 미흡한 부분만 개선); otherwise regenerate fresh from 원본.
    func regenerateScript() {
        cancelActiveWork()
        scriptTask = Task { [weak self] in
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
            statusText = "다듬기 불가 — 엔드포인트·모델·API 키 중 하나가 미설정입니다 (설정 확인)"
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
            synthesize(scriptText, displayText: inputText)   // speak the 대본, show the 원본
        }
    }

    /// Services entry: set the source, build the script, then speak it.
    func speakSelected(_ text: String) {
        cancelActiveWork()
        playbackMode = .tts
        inputText = TextSplitter.cleanInput(text)
        scriptText = ""
        phase = .synthesizing
        statusText = normalizeEnabled ? "대본 생성 중…" : "합성 중…"
        scriptTask = Task { [weak self] in
            guard let self else { return }
            let script = await self.prepareScript()
            guard !Task.isCancelled else { return }
            self.synthesize(script, displayText: self.inputText)   // speak the 대본, show the 원본
        }
    }

    func replay(_ e: HistoryEntry) {
        cancelActiveWork()
        playbackMode = .tts
        guard let url = cache.fileURL(forKey: e.id) else { statusText = "오디오 파일 없음"; return }
        cache.touch(e.id); historyRevision += 1
        inputText = e.text; currentText = e.text; spokenChunks = [e.text]
        chunkSentenceTimes = [cache.times(forKey: e.id) ?? []]
        telemetry.reset()
        chunkCount = 1; chunkIndex = 1
        player.start(expected: 1)
        player.enqueue(url)
        phase = .playing; statusText = "캐시에서 재생"; startTimer()
    }

    func stop() { cancelActiveWork(); finish() }

    /// 생성 중단 (사용자 요청 버튼): cancel the in-flight 해설/대본 LLM streams only —
    /// playback keeps running. Both stream loops already honor cancellation:
    /// 대본 keeps the partial text (stale flag shows), 해설 keeps the streamed
    /// raw acc per the existing CancellationError conventions.
    func cancelGeneration() {
        explainTask?.cancel()
        scriptTask?.cancel()
        statusText = "생성 중단됨"
        // A command that was still PRE-playback (e.g. Services 읽기: phase was
        // set to .synthesizing before its scriptTask) must not strand the HUD;
        // anything already .playing keeps playing (this is not the transport 중지).
        if phase == .synthesizing { phase = .idle }
    }

    /// Cancel every in-flight command (LLM streams + synthesis + playback) so a
    /// new command supersedes prior ones IMMEDIATELY — rapid or mis-clicked
    /// TTS/해설 commands don't queue up and run in sequence; only the last runs.
    private func cancelActiveWork() {
        explainTask?.cancel(); explainTask = nil
        scriptTask?.cancel(); scriptTask = nil
        task?.cancel(); task = nil
        player.stop()
        stopTimer()
    }

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

    // MARK: - HUD placement & subtitle size

    /// Display ID of the screen containing a global (Cocoa) point, if any.
    static func screenID(containing point: CGPoint) -> CGDirectDisplayID? {
        let screen = NSScreen.screens.first { $0.frame.contains(point) }
        return screen.flatMap(Self.displayID(of:))
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Capture which screen the current command targets — call at the *moment* the
    /// command fires (before any async grab/synthesis), while the mouse is still on
    /// the screen the user just acted on. Falls back to the previous target.
    func captureHUDTarget() {
        if let id = Self.screenID(containing: NSEvent.mouseLocation) { hudTargetScreenID = id }
    }

    /// Record a user-dragged HUD position (bottom-left offset within `screenID`'s
    /// visible frame) in memory. Programmatic re-pins must NOT call this. The
    /// caller debounces the disk write (`saveSettings`) — a drag fires many moves.
    func setHUDPosition(_ offset: CGPoint, for screenID: CGDirectDisplayID) {
        hudPositions[screenID] = offset
    }

    /// Flip the subtitle for the current playback mode (TTS vs 해설) and persist.
    func toggleSubtitle() {
        if playbackMode == .tts { subtitleTTS.toggle() } else { subtitleExplain.toggle() }
        saveSettings()
    }

    func adjustSubtitleFont(by delta: Double) {
        let v = (subtitleFontSize + delta).rounded()
        subtitleFontSize = min(max(v, Self.subtitleFontRange.lowerBound), Self.subtitleFontRange.upperBound)
        saveSettings()
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
            "subtitleTTS": subtitleTTS, "subtitleExplain": subtitleExplain,
            "subtitleFontSize": subtitleFontSize,
            "hudPositions": Dictionary(uniqueKeysWithValues:
                hudPositions.map { (String($0.key), [$0.value.x, $0.value.y]) }),
            "normalize": normalizeEnabled,
            "explainTemperature": explainTemperature, "scriptTemperature": scriptTemperature,
            "explainReasoningLevel": explainReasoningLevel.rawValue,
            "scriptReasoningLevel": scriptReasoningLevel.rawValue,
            "visionReasoningLevel": visionReasoningLevel.rawValue,
            "explainAutoPlay": explainAutoPlay,
            "stability": voiceSettings.stability, "similarity": voiceSettings.similarityBoost,
            "style": voiceSettings.style, "speakerBoost": voiceSettings.useSpeakerBoost,
            // Endpoints are the single source of truth for LLM providers (the old
            // gemini*/zai*/ollama* keys are consumed as seed data on load only).
            "explainEndpointID": explainEndpointID, "scriptEndpointID": scriptEndpointID,
            "visionEndpointID": visionEndpointID, "visionOverridden": visionOverridden,
            "explainRoleModels": explainRoleModels,
            "scriptRoleModels": scriptRoleModels,
            "visionRoleModels": visionRoleModels,
        ]
        // Endpoints: encode via Codable. CustomEndpoint has no apiKey property at
        // all (keys live in <id>.key files), so settings.json CANNOT hold a
        // plaintext key — no scrub step to forget.
        if let data = try? JSONEncoder().encode(endpoints),
           let arr = try? JSONSerialization.jsonObject(with: data) {
            dict["endpoints"] = arr
        }
        if let data = try? JSONEncoder().encode(glossary),
           let arr = try? JSONSerialization.jsonObject(with: data) {
            dict["glossary"] = arr
        }
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
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            // No settings yet (fresh install): still seed the 3 standard
            // endpoints so the app works out of the box, then persist them.
            // 용어 사전도 여기서 심어야 한다 — 아래 saveSettings()가 "glossary" 키를
            // 빈 배열로 써버리면 다음 실행부터 그 파일은 "사용자가 전부 지웠다"로
            // 읽혀 예시가 영영 안 나온다.
            seedEndpoints(from: [:])
            glossary = Self.seedGlossary
            saveSettings()
            return
        }
        voiceId = o["voiceId"] as? String ?? voiceId
        voiceName = o["voiceName"] as? String ?? voiceName
        modelId = o["modelId"] as? String ?? modelId
        backendKind = BackendKind(rawValue: o["backend"] as? String ?? "") ?? backendKind
        useCache = o["useCache"] as? Bool ?? useCache
        localBaseURL = o["localBaseURL"] as? String ?? localBaseURL
        maxChunkChars = o["maxChunkChars"] as? Int ?? maxChunkChars
        subtitleTTS = o["subtitleTTS"] as? Bool ?? subtitleTTS
        subtitleExplain = o["subtitleExplain"] as? Bool ?? subtitleExplain
        subtitleFontSize = o["subtitleFontSize"] as? Double ?? subtitleFontSize
        if let raw = o["hudPositions"] as? [String: [Double]] {
            hudPositions = Dictionary(uniqueKeysWithValues: raw.compactMap { key, xy in
                guard let id = UInt32(key), xy.count == 2 else { return nil }
                return (CGDirectDisplayID(id), CGPoint(x: xy[0], y: xy[1]))
            })
        }
        normalizeEnabled = o["normalize"] as? Bool ?? normalizeEnabled
        normalizePrompt = o["normalizePrompt"] as? String ?? normalizePrompt
        explainPrompt = o["explainPrompt"] as? String ?? explainPrompt
        explainTemperature = o["explainTemperature"] as? Double ?? explainTemperature
        explainAutoPlay = o["explainAutoPlay"] as? Bool ?? explainAutoPlay
        scriptTemperature = o["scriptTemperature"] as? Double ?? scriptTemperature
        explainReasoningLevel = ReasoningLevel(rawValue: o["explainReasoningLevel"] as? String ?? "") ?? explainReasoningLevel
        scriptReasoningLevel = ReasoningLevel(rawValue: o["scriptReasoningLevel"] as? String ?? "") ?? scriptReasoningLevel
        visionReasoningLevel = ReasoningLevel(rawValue: o["visionReasoningLevel"] as? String ?? "") ?? visionReasoningLevel
        voiceSettings.stability = o["stability"] as? Double ?? voiceSettings.stability
        voiceSettings.similarityBoost = o["similarity"] as? Double ?? voiceSettings.similarityBoost
        voiceSettings.style = o["style"] as? Double ?? voiceSettings.style
        voiceSettings.useSpeakerBoost = o["speakerBoost"] as? Bool ?? voiceSettings.useSpeakerBoost

        // --- LLM endpoints ---
        // The PRESENCE of the "endpoints" key means this file was written by a
        // migrated build — an EMPTY array then means "the user deleted them all"
        // and must be honored, not re-seeded (or deletion would never stick).
        var didSeed = false
        if let arr = o["endpoints"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: arr),
           let list = try? JSONDecoder().decode([CustomEndpoint].self, from: data) {
            endpoints = list        // may be [] — the user deleted them all
        } else {
            // First run after the endpoints migration (or an unreadable list):
            // turn the legacy gemini/zai/ollama settings keys into the 3 seeds.
            seedEndpoints(from: o)
            didSeed = true
        }
        // Role → endpoint references (ids saved by this version; legacy role
        // rawValues were mapped to seed ids in seedEndpoints).
        explainEndpointID = o["explainEndpointID"] as? String ?? explainEndpointID
        scriptEndpointID = o["scriptEndpointID"] as? String ?? scriptEndpointID
        visionEndpointID = o["visionEndpointID"] as? String ?? visionEndpointID
        visionOverridden = o["visionOverridden"] as? Bool ?? false
        explainRoleModels = o["explainRoleModels"] as? [String: String] ?? explainRoleModels
        scriptRoleModels = o["scriptRoleModels"] as? [String: String] ?? scriptRoleModels
        visionRoleModels = o["visionRoleModels"] as? [String: String] ?? visionRoleModels
        // A saved role pointing at a deleted endpoint falls back to the first
        // enabled one so generation never resolves to nil after manual edits.
        let fallbackID = endpoints.first(where: { $0.isEnabled })?.id.uuidString ?? ""
        func resolve(_ id: String) -> String {
            endpoints.contains(where: { $0.id.uuidString == id }) ? id : fallbackID
        }
        explainEndpointID = resolve(explainEndpointID)
        scriptEndpointID = resolve(scriptEndpointID)
        visionEndpointID = resolve(visionEndpointID)

        // --- 용어 발음 사전 (glossary) ---
        // The PRESENCE of the "glossary" key means this file knows about the
        // feature — an EMPTY array then means "the user deleted them all" and is
        // honored (same rule as endpoints). Only a missing key seeds the examples;
        // 키가 있는데 못 읽히면(손상·손편집) 지운 항목이 되살아나지 않도록 빈 사전.
        if o["glossary"] == nil {
            glossary = Self.seedGlossary
        } else {
            let arr = o["glossary"] as? [[String: Any]] ?? []
            let data = (try? JSONSerialization.data(withJSONObject: arr)) ?? Data()
            glossary = (try? JSONDecoder().decode([GlossaryEntry].self, from: data)) ?? []
        }

        // Persist the migration only AFTER every field is loaded — saving inside
        // the branch above wrote the pre-load defaults for anything read below it
        // (visionOverridden in particular).
        if didSeed { saveSettings() }
    }

    /// Legacy → endpoints migration. Reads the old settings keys (URLs, 기본
    /// 모델, per-role models) as SEED DATA only and builds the 3 standard
    /// endpoints with fixed ids (so old role rawValues map deterministically).
    /// Legacy gemini/zai key files are copied to their seed <id>.key names; the
    /// originals stay in place. Afterwards saving is endpoints-based only.
    private func seedEndpoints(from o: [String: Any]) {
        func str(_ key: String, _ def: String) -> String { o[key] as? String ?? def }

        if let k = Secrets.geminiKey { Secrets.writeEndpointKey(CustomEndpoint.geminiSeedID, k) }
        if let k = Secrets.zaiKey { Secrets.writeEndpointKey(CustomEndpoint.zaiSeedID, k) }

        let gemini = CustomEndpoint(id: CustomEndpoint.geminiSeedID, name: "Gemini",
                                    baseURL: str("geminiBaseURL", GeminiNormalizer.defaultBaseURL),
                                    apiStyle: .gemini,
                                    defaultModel: str("geminiModel", "gemini-2.0-flash"))
        let zai = CustomEndpoint(id: CustomEndpoint.zaiSeedID, name: "Z.ai",
                                 baseURL: str("zaiBaseURL", ZAINormalizer.defaultBaseURL),
                                 apiStyle: .openAICompatible,
                                 defaultModel: str("zaiModel", ZAINormalizer.fallbackModels.first ?? ""))
        let ollama = CustomEndpoint(id: CustomEndpoint.ollamaSeedID, name: "Ollama",
                                    baseURL: str("ollamaURL", "http://localhost:11434"),
                                    apiStyle: .ollama,
                                    defaultModel: str("ollamaModel", "gemma4:31b-cloud"))
        endpoints = [ollama, gemini, zai]

        // Per-role model memories. A legacy value equal to the endpoint default
        // stays unset — it inherits the default (구 zaiEffective 폴백과 동일).
        // The untouched explainZAIModel quirk (old default saved unconditionally)
        // is treated as unset, same as the old loader did.
        let legacyExplainZAI = { () -> String in
            let v = str("explainZAIModel", "")
            return v == ZAINormalizer.fallbackModels.first ? "" : v
        }()
        let legacyExplainGemini = str("explainGeminiModel", gemini.defaultModel)
        let legacyExplainOllama = str("explainOllamaModel", ollama.defaultModel)
        explainRoleModels = [
            gemini.id.uuidString: legacyExplainGemini == gemini.defaultModel ? "" : legacyExplainGemini,
            zai.id.uuidString: legacyExplainZAI,
            ollama.id.uuidString: legacyExplainOllama == ollama.defaultModel ? "" : legacyExplainOllama,
        ]
        scriptRoleModels = [zai.id.uuidString: str("scriptZAIModel", "")]  // gemini/ollama 대본 모델 == 기본 모델
        visionRoleModels = [
            gemini.id.uuidString: str("explainVisionGeminiModel", ""),
            zai.id.uuidString: str("explainVisionZAIModel", ""),
            ollama.id.uuidString: str("explainVisionOllamaModel", ""),
        ]

        func seedID(forLegacy raw: String?, _ fallback: String) -> String {
            switch raw {
            case "gemini": return CustomEndpoint.geminiSeedID.uuidString
            case "zai": return CustomEndpoint.zaiSeedID.uuidString
            case "ollama": return CustomEndpoint.ollamaSeedID.uuidString
            default: return fallback
            }
        }
        let ollamaID = CustomEndpoint.ollamaSeedID.uuidString
        explainEndpointID = seedID(forLegacy: o["explainProvider"] as? String, ollamaID)
        scriptEndpointID = seedID(forLegacy: o["scriptProvider"] as? String, ollamaID)
        visionEndpointID = seedID(forLegacy: o["visionProvider"] as? String, explainEndpointID)
    }
}

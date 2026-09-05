import SwiftUI
import AppKit

/// Settings split into two conceptual channels: ① 음성 합성 (the TTS engine) and
/// ② 텍스트 생성 (the LLM endpoints used for 해설/대본). The TTS channel renders
/// from the engine seam (BackendKind descriptors) so it's not hardcoded to
/// ElevenLabs; the LLM channel renders from the endpoint list (CustomEndpoint)
/// so providers are added/removed from settings, not code.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var channel = 0               // 0 = 음성 합성, 1 = 텍스트 생성
    @State private var keyInput = ""             // ElevenLabs key entry
    // "엔드포인트 추가" form state
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newStyle: CustomEndpoint.APIStyle = .openAICompatible
    @State private var newKey = ""
    @State private var newDefaultModel = ""

    var body: some View {
        settingsForm
            .onAppear { prefillKeyInputs() }
            .onDisappear { app.saveSettings() }
            .onChange(of: settingsSaveKeys) { _, _ in app.saveSettings() }
            // settingsSaveKeys is a short-circuiting && chain whose first term is
            // false at defaults, so it never observes anything past it — endpoint
            // edits need their own triggers to persist without closing the window.
            .onChange(of: app.endpoints) { _, _ in app.saveSettings() }
            .onChange(of: app.explainEndpointID) { _, _ in app.saveSettings() }
            .onChange(of: app.scriptEndpointID) { _, _ in app.saveSettings() }
            .onChange(of: app.visionEndpointID) { _, _ in app.saveSettings() }
            .onChange(of: app.voiceId) { _, newID in
                if let v = app.voices.first(where: { $0.id == newID }) { app.voiceName = v.name }
                app.saveSettings()
            }
    }

    /// One Equatable tuple covering every field whose change should persist
    /// settings — replaces individual .onChange modifiers that pushed the body
    /// expression past the Swift type-checker's complexity limit. Endpoint edits
    /// are saved via the dedicated .onChange(of: app.endpoints) above.
    private var settingsSaveKeys: Bool {
        app.localBaseURL == "" && app.normalizeEnabled && app.maxChunkChars == 0
            && app.subtitleTTS && app.subtitleExplain && app.modelId == ""
            && app.useCache && !app.backendKind.rawValue.isEmpty && !app.voiceSettings.similarityBoost.isNaN
    }

    /// Broken out of `body` so the long modifier chain stays under the Swift
    /// type-checker's expression-complexity limit.
    private var settingsForm: some View {
        VStack(spacing: 0) {
            Picker("", selection: $channel) {
                Text("음성 합성 (TTS)").tag(0)
                Text("텍스트 생성 (LLM)").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding([.horizontal, .top])

            Form {
                if channel == 0 { ttsChannel } else { llmChannel }
            }
            .formStyle(.grouped)
        }
    }

    // MARK: - ① 음성 합성 (TTS engine)

    @ViewBuilder private var ttsChannel: some View {
        Section("엔진") {
            Picker("합성 엔진", selection: $app.backendKind) {
                ForEach(AppState.BackendKind.allCases) { Text($0.label).tag($0) }
            }
            Text("음성을 만드는 백엔드입니다. 엔진을 바꾸면 아래 보이스·모델·튜닝이 그 엔진 기준으로 바뀝니다.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("보이스 / 모델") {
            if app.backendKind.hasVoiceList {
                if app.voices.isEmpty {
                    labeledField("보이스 ID", placeholder: "voice id", text: $app.voiceId,
                                 hint: "아래 ‘연결’에서 보이스를 새로고침하면 목록에서 고를 수 있어요.")
                } else {
                    Picker("보이스", selection: $app.voiceId) {
                        ForEach(app.voices) { v in
                            Text("\(v.name)\(v.category == "cloned" ? " · 클론" : "")").tag(v.id)
                        }
                    }
                }
            } else {
                labeledField("보이스 ID", placeholder: "voice id", text: $app.voiceId,
                             hint: "이 엔진은 보이스 목록을 제공하지 않습니다. 식별자를 직접 입력하세요.")
            }
            if !app.backendKind.ttsModels.isEmpty {
                Picker("모델", selection: $app.modelId) {
                    ForEach(app.backendKind.ttsModels, id: \.id) { Text($0.label).tag($0.id) }
                }
            }
        }

        if app.backendKind == .elevenlabs {
            Section("보이스 튜닝 (ElevenLabs)") {
                slider("안정성 (stability)", $app.voiceSettings.stability)
                slider("유사도 (similarity)", $app.voiceSettings.similarityBoost)
                slider("스타일 (style)", $app.voiceSettings.style)
                Toggle("speaker boost", isOn: $app.voiceSettings.useSpeakerBoost)
            }
        }

        if app.backendKind.requiresAPIKey {
            Section("연결") {
                LabeledContent("API 키", value: app.keyPresent ? "설정됨" : "없음")
                LabeledContent("연결", value: app.connectionStatus.isEmpty ? "—" : app.connectionStatus)
                KeyField(label: "ElevenLabs API 키", text: $keyInput, hint: "App Support에 저장됩니다.")
                HStack {
                    Button("키 저장") { app.saveKey(keyInput) }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { app.refreshVoices() } label: {
                        Label("연결 테스트 / 보이스 새로고침", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                }
            }
        }

        if app.backendKind.usesLocalSidecar {
            Section("로컬 sidecar") {
                LabeledContent("Base URL") {
                    TextField("http://127.0.0.1:8765", text: $app.localBaseURL).frame(width: 240)
                }
                Text("로컬 엔진(Qwen3-TTS)을 쓰려면 Sidecar/server.py 를 실행해 두세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("캐시 / 합성") {
            Toggle("같은 텍스트는 캐시에서 재생 (API 재호출 안 함)", isOn: $app.useCache)
            LabeledContent("문단 최대 글자수") {
                TextField("", value: $app.maxChunkChars, format: .number)
                    .frame(width: 80).multilineTextAlignment(.trailing)
            }
            Text("긴 대본은 이 글자수 기준으로 문단을 나눠 합성·캐시·재생합니다 (오디오 분할 단위).")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("HUD 자막") {
            Toggle("TTS 재생 시 자막 표시", isOn: $app.subtitleTTS)
            Toggle("해설 재생 시 자막 표시", isOn: $app.subtitleExplain)
            Text("재생 중 떠 있는 HUD에 현재 읽는 문단을 자막으로 보여줍니다.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("전역 단축키 (선택 → 읽기/해설)") {
            LabeledContent("읽어주기", value: "⌃⌥⌘R")
            LabeledContent("코드 해설", value: "⌃⌥⌘E")
            LabeledContent("손쉬운 사용 권한", value: SelectionGrabber.hasPermission ? "허용됨" : "필요함")
            if !SelectionGrabber.hasPermission {
                Button("권한 요청 / 시스템 설정 열기") {
                    SelectionGrabber.requestPermission()
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(u)
                    }
                }
            }
            Text("어느 앱에서든 텍스트를 선택하고 단축키를 누르면 복사 없이 읽어주거나 해설합니다 (클립보드 자동 복원). VS Code처럼 서비스 메뉴가 없는 앱에서도 동작합니다. 단축키 합성을 위해 손쉬운 사용 권한이 필요합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - ② 텍스트 생성 (LLM endpoints for 해설/대본)

    @ViewBuilder private var llmChannel: some View {
        Section {
            Text("코드 해설·음성 대본 생성에 쓰는 텍스트 생성 엔드포인트입니다. OpenAI 호환·Gemini·Ollama 엔드포인트를 여러 개 등록할 수 있고, 모델은 해설/TTS 패널에서 등록된 엔드포인트별 통합 목록에서 고릅니다. temperature는 각 패널 인스펙터(⊟)에서 조절합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("엔드포인트") {
            if app.endpoints.isEmpty {
                Text("등록된 엔드포인트가 없습니다. 아래 폼에서 추가하세요.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            ForEach($app.endpoints) { $ep in
                EndpointRow(endpoint: $ep,
                            status: app.endpointStatus[ep.id.uuidString] ?? "",
                            onDelete: { app.deleteEndpoint(ep.id) },
                            onCheck: { app.refreshEndpointModels(ep) },
                            onSaveKey: { app.saveEndpointKey(ep.id, $0) })
            }
        }

        Section("엔드포인트 추가") {
            labeledField("이름", placeholder: "예: Z.ai, 내 vLLM", text: $newName)
            labeledField("URL", placeholder: "https://api.z.ai/api/coding/paas/v4",
                         text: $newURL,
                         hint: "OpenAI 호환: /chat/completions, Gemini: /models/{모델}:generateContent, Ollama: /api/generate 가 뒤에 붙는 API 루트")
            Picker("스타일", selection: $newStyle) {
                ForEach(CustomEndpoint.APIStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            labeledField("기본 모델 (선택)", placeholder: "비우면 첫 연결 때 목록에서 채움",
                         text: $newDefaultModel)
            KeyField(label: "API 키 (선택 — 로컬 엔드포인트는 비워 둠)", text: $newKey,
                     hint: "App Support/<엔드포인트>.key 로 저장됩니다 (settings.json에 저장 안 됨)")
            HStack {
                Button {
                    app.addEndpoint(name: newName.trimmingCharacters(in: .whitespaces),
                                    baseURL: newURL.trimmingCharacters(in: .whitespaces),
                                    style: newStyle,
                                    apiKey: newKey,
                                    defaultModel: newDefaultModel)
                    newName = ""; newURL = ""; newKey = ""; newDefaultModel = ""
                } label: {
                    Label("엔드포인트 추가", systemImage: "plus")
                }
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
        }

        Section("음성 대본 정규화") {
            Toggle("대본 생성 시 LLM으로 발음·표기 정규화", isOn: $app.normalizeEnabled)
            Text("끄면 해설을 거의 그대로 합성합니다. 켜면 숫자·기호·코드 명칭을 발음대로 다듬습니다 (경량 로컬 모델은 부정확할 수 있어 강한 모델 권장).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    /// Pre-fill key fields + kick off first model/voice refresh (moved out of
    /// .onAppear — the closure had grown past the type-checker's limit).
    private func prefillKeyInputs() {
        app.refreshAllModelsIfNeeded()
        if app.voices.isEmpty && app.keyPresent { app.refreshVoices() }
        keyInput = Secrets.elevenLabsKey ?? ""        // pre-fill so the current key is visible/editable
    }

    /// One registered endpoint: 이름·URL·스타일·활성 토글 + 삭제, plus the
    /// endpoint's 기본 모델, API key entry, and a 연결 확인 (models.list) row.
    private struct EndpointRow: View {
        @Binding var endpoint: CustomEndpoint
        let status: String
        let onDelete: () -> Void
        let onCheck: () -> Void
        let onSaveKey: (String) -> Void

        @State private var keyInput = ""
        @EnvironmentObject var app: AppState

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("이름", text: $endpoint.name).frame(width: 110)
                        .textFieldStyle(.roundedBorder)
                    Picker("", selection: $endpoint.apiStyle) {
                        ForEach(CustomEndpoint.APIStyle.allCases) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .labelsHidden().frame(width: 130)
                    Spacer()
                    Toggle("활성", isOn: $endpoint.isEnabled)
                        .toggleStyle(.checkbox).controlSize(.small)
                        .help("끄면 모델 피커와 생성에서 이 엔드포인트가 제외됩니다 (설정은 유지)")
                    Button(role: .destructive) { onDelete() } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .help("엔드포인트 삭제 (키 파일은 유지됩니다)")
                }
                TextField("http://localhost:11434", text: $endpoint.baseURL)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    TextField("기본 모델", text: $endpoint.defaultModel)
                        .textFieldStyle(.roundedBorder).frame(width: 220)
                        .help("역할별 모델 미지정 시 사용되는 이 엔드포인트의 기본 모델")
                    if !app.endpointDefaultModelValid(endpoint) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help("연결된 목록에 없는 기본 모델입니다")
                    }
                    Spacer()
                }
                KeyField(label: "API 키", text: $keyInput,
                         hint: endpointKeyHint)
                HStack {
                    Button("키 저장") { onSaveKey(keyInput) }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button { onCheck() } label: {
                        Label("연결 확인", systemImage: "arrow.clockwise")
                    }
                    Spacer()
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .onAppear { keyInput = Secrets.endpointKey(endpoint.id) ?? "" }
        }

        private var endpointKeyHint: String {
            endpoint.apiStyle == .ollama
                ? "Ollama는 보통 키가 필요 없습니다"
                : (Secrets.endpointKey(endpoint.id) != nil ? "현재: 설정됨 (App Support)" : "현재: 없음")
        }
    }

    @ViewBuilder
    private func slider(_ label: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
    }

    /// API-key field: pre-filled with the current key, masked by default with an
    /// eye toggle to reveal/verify it.
    private struct KeyField: View {
        let label: String
        @Binding var text: String
        var hint: String? = nil
        @State private var reveal = false
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Group {
                        if reveal { TextField("", text: $text) }
                        else { SecureField("", text: $text) }
                    }
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    Button { reveal.toggle() } label: {
                        Image(systemName: reveal ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(reveal ? "키 숨기기" : "키 보기")
                }
                if let hint { Text(hint).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
    }

    @ViewBuilder
    private func labeledField(_ label: String, placeholder: String, secure: Bool = false,
                              text: Binding<String>, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Group {
                if secure { SecureField(placeholder, text: text) }
                else { TextField(placeholder, text: text) }
            }
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            if let hint { Text(hint).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

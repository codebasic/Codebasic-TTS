import SwiftUI
import AppKit

/// Settings split into two conceptual channels: ① 음성 합성 (the TTS engine) and
/// ② 텍스트 생성 (the LLM used for 해설/대본). The TTS channel renders from the
/// engine seam (BackendKind descriptors) so it's not hardcoded to ElevenLabs;
/// each engine keeps its own typed tuning (ElevenVoiceSettings) untouched.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var channel = 0               // 0 = 음성 합성, 1 = 텍스트 생성
    @State private var geminiKeyInput = ""
    @State private var keyInput = ""             // ElevenLabs key entry

    var body: some View {
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
        .onAppear {
            if app.ollamaModels.isEmpty { app.refreshOllamaModels() }
            if app.voices.isEmpty && app.keyPresent { app.refreshVoices() }
            keyInput = Secrets.elevenLabsKey ?? ""        // pre-fill so the current key is visible/editable
            geminiKeyInput = Secrets.geminiKey ?? ""
        }
        .onChange(of: app.localBaseURL) { _, _ in app.saveSettings() }
        .onChange(of: app.normalizeEnabled) { _, _ in app.saveSettings() }
        .onChange(of: app.normalizeProvider) { _, _ in app.saveSettings() }
        .onChange(of: app.geminiModel) { _, _ in app.saveSettings() }
        .onChange(of: app.geminiBaseURL) { _, _ in app.saveSettings() }
        .onChange(of: app.ollamaModel) { _, _ in app.saveSettings() }
        .onChange(of: app.ollamaURL) { _, _ in app.saveSettings() }
        .onChange(of: app.maxChunkChars) { _, _ in app.saveSettings() }
        .onChange(of: app.voiceId) { _, newID in
            if let v = app.voices.first(where: { $0.id == newID }) { app.voiceName = v.name }
            app.saveSettings()
        }
        .onChange(of: app.modelId) { _, _ in app.saveSettings() }
        .onChange(of: app.backendKind) { _, _ in app.saveSettings() }
        .onChange(of: app.useCache) { _, _ in app.saveSettings() }
        .onChange(of: app.voiceSettings) { _, _ in app.saveSettings() }
        .onDisappear { app.saveSettings() }
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

    // MARK: - ② 텍스트 생성 (LLM for 해설/대본)

    @ViewBuilder private var llmChannel: some View {
        Section {
            Text("코드 해설·음성 대본 생성에 쓰는 텍스트 생성 모델입니다. Ollama와 Gemini를 동시에 연결할 수 있고, 모델은 해설/TTS 패널에서 두 제공자의 통합 목록에서 고릅니다. temperature는 각 패널 인스펙터(⊟)에서 조절합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section("Ollama") {
            labeledField("엔드포인트", placeholder: "http://localhost:11434",
                         text: $app.ollamaURL,
                         hint: "로컬/원격 모두 가능: 예) http://192.168.0.10:11434")
            HStack {
                Button("연결 확인 / 모델 목록") { app.refreshOllamaModels() }
                Spacer()
                Text(app.ollamaStatus).font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("Gemini (클라우드)") {
            labeledField("엔드포인트", placeholder: GeminiNormalizer.defaultBaseURL,
                         text: $app.geminiBaseURL,
                         hint: "API 루트. 끝에 /models/{모델}:generateContent 가 붙습니다. 프록시·게이트웨이 사용 시 변경.")
            KeyField(label: "API 키", text: $geminiKeyInput,
                     hint: app.geminiKeyPresent ? "현재: 설정됨 (App Support)" : "현재: 없음 — 키를 넣으면 모델 목록에 Gemini 모델이 함께 표시됩니다")
            HStack {
                Button("키 저장") { app.saveGeminiKey(geminiKeyInput) }
                    .disabled(geminiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("연결 확인 / 모델 목록") { app.refreshGeminiModels() }
                Spacer()
                Text(app.geminiStatus).font(.caption).foregroundStyle(.secondary)
            }
        }

        Section("음성 대본 정규화") {
            Toggle("대본 생성 시 LLM으로 발음·표기 정규화", isOn: $app.normalizeEnabled)
            Text("끄면 해설을 거의 그대로 합성합니다. 켜면 숫자·기호·코드 명칭을 발음대로 다듬습니다 (경량 로컬 모델은 부정확할 수 있어 강한 모델 권장).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

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

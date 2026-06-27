import SwiftUI

/// Generation settings: backend, voice, model, voice tuning, cache.
struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var geminiKeyInput = ""
    @State private var keyInput = ""             // ElevenLabs key entry

    var body: some View {
        Form {
            Section("백엔드") {
                Picker("엔진", selection: $app.backendKind) {
                    ForEach(AppState.BackendKind.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("보이스 / 모델") {
                if app.voices.isEmpty {
                    labeledField("보이스 ID", placeholder: "voice id", text: $app.voiceId,
                                 hint: "연결 탭에서 ‘보이스 새로고침’을 누르면 목록에서 고를 수 있어요.")
                } else {
                    Picker("보이스", selection: $app.voiceId) {
                        ForEach(app.voices) { v in
                            Text("\(v.name)\(v.category == "cloned" ? " · 클론" : "")").tag(v.id)
                        }
                    }
                }
                Picker("모델", selection: $app.modelId) {
                    ForEach(ElevenLabs.koreanModels, id: \.id) { Text($0.label).tag($0.id) }
                }
            }

            Section("보이스 설정 (ElevenLabs)") {
                slider("안정성 (stability)", $app.voiceSettings.stability)
                slider("유사도 (similarity)", $app.voiceSettings.similarityBoost)
                slider("스타일 (style)", $app.voiceSettings.style)
                Toggle("speaker boost", isOn: $app.voiceSettings.useSpeakerBoost)
            }

            Section("캐시 / 문단 분할") {
                Toggle("같은 텍스트는 캐시에서 재생 (API 재호출 안 함)", isOn: $app.useCache)
                LabeledContent("문단 최대 글자수") {
                    TextField("", value: $app.maxChunkChars, format: .number)
                        .frame(width: 80).multilineTextAlignment(.trailing)
                }
                Text("긴 문단은 이 글자수 기준으로 나눠 따로 요청한 뒤 이어 재생합니다. 캐시도 이 단위.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("TTS 친화 정규화") {
                Toggle("숫자·수식 표기를 발음대로 정규화", isOn: $app.normalizeEnabled)
                Picker("제공자", selection: $app.normalizeProvider) {
                    ForEach(AppState.NormalizeProvider.allCases) { Text($0.label).tag($0) }
                }

                if app.normalizeProvider == .gemini {
                    labeledField("Gemini 엔드포인트", placeholder: GeminiNormalizer.defaultBaseURL,
                                 text: $app.geminiBaseURL,
                                 hint: "API 루트. 끝에 /models/{모델}:generateContent 가 붙습니다. 프록시·게이트웨이 사용 시 변경.")
                    if app.geminiModels.isEmpty {
                        Picker("대본 모델", selection: $app.geminiModel) {
                            ForEach(GeminiNormalizer.models, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        Picker("대본 모델", selection: $app.geminiModel) {
                            ForEach(app.geminiModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    labeledField("Gemini API 키", placeholder: "AIza…", secure: true,
                                 text: $geminiKeyInput,
                                 hint: app.geminiKeyPresent ? "현재: 설정됨 (App Support)" : "현재: 없음")
                    HStack {
                        Button("키 저장") { app.saveGeminiKey(geminiKeyInput); geminiKeyInput = "" }
                            .disabled(geminiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("연결 확인 / 모델 목록") { app.refreshGeminiModels() }
                        Spacer()
                        Text(app.geminiStatus).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    if app.ollamaModels.isEmpty {
                        labeledField("모델", placeholder: "qwen2.5:3b", text: $app.ollamaModel)
                    } else {
                        Picker("모델", selection: $app.ollamaModel) {
                            ForEach(app.ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    labeledField("Ollama 엔드포인트", placeholder: "http://localhost:11434",
                                 text: $app.ollamaURL,
                                 hint: "로컬/원격 모두 가능: 예) http://192.168.0.10:11434")
                    HStack {
                        Button("연결 확인 / 모델 목록") { app.refreshOllamaModels() }
                        Spacer()
                        Text(app.ollamaStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("0.5→영 점 오, w1→더블유 일 처럼 다듬어 합성합니다. 경량 로컬 모델은 숫자 읽기가 부정확할 수 있어 Gemini를 권장합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("연결 상태") {
                LabeledContent("백엔드", value: app.backendKind.label)
                LabeledContent("ElevenLabs 키", value: app.keyPresent ? "설정됨" : "없음")
                LabeledContent("연결", value: app.connectionStatus.isEmpty ? "—" : app.connectionStatus)
                Button {
                    app.refreshVoices()
                } label: {
                    Label("연결 테스트 / 보이스 새로고침", systemImage: "arrow.clockwise")
                }
            }

            Section("ElevenLabs API 키") {
                SecureField("sk_...", text: $keyInput)
                HStack {
                    Button("저장") { app.saveKey(keyInput); keyInput = "" }
                        .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Spacer()
                    Text("App Support에 저장됩니다").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("로컬 sidecar") {
                LabeledContent("Base URL") {
                    TextField("http://127.0.0.1:8765", text: $app.localBaseURL).frame(width: 240)
                }
                Text("로컬 엔진(Qwen3-TTS)을 쓰려면 Sidecar/server.py 를 실행해 두세요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if app.ollamaModels.isEmpty { app.refreshOllamaModels() }
            if app.voices.isEmpty && app.keyPresent { app.refreshVoices() }
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
        .onDisappear { app.saveSettings() }
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

    @ViewBuilder
    private func labeledField(_ label: String, placeholder: String, secure: Bool = false,
                              text: Binding<String>, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Group {
                if secure { SecureField(placeholder, text: text) }
                else { TextField(placeholder, text: text) }
            }
            .labelsHidden()                       // avoid the Form auto-label duplicating our caption
            .textFieldStyle(.roundedBorder)
            if let hint { Text(hint).font(.caption2).foregroundStyle(.tertiary) }
        }
    }
}

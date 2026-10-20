import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var category: Category = .voice
    @State private var keyInput = ""
    @State private var editingKey = false
    @State private var showGlossary = false
    @State private var editingService: CustomEndpoint?
    @State private var sample = "안녕하세요. 선택한 음성입니다."
    @StateObject private var preview = VoicePreview()
    @State private var localStatus = "확인 안 됨"
    @State private var checkingLocal = false
    @State private var hasPermission = SelectionGrabber.hasPermission

    private enum Category: String, CaseIterable, Identifiable {
        case voice = "음성", services = "AI 서비스", script = "대본·발음"
        case playback = "재생·자막", shortcuts = "단축키"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .voice: return "speaker.wave.2"
            case .services: return "sparkles"
            case .script: return "doc.text"
            case .playback: return "play.rectangle"
            case .shortcuts: return "keyboard"
            }
        }
        var subtitle: String {
            switch self {
            case .voice: return "연결하고, 목소리를 고르고, 들어보세요."
            case .services: return "해설과 대본에 사용할 AI 서비스를 관리합니다."
            case .script: return "숫자와 코드도 자연스럽게 읽도록 다듬습니다."
            case .playback: return "재생 자막과 음성 캐시를 설정합니다."
            case .shortcuts: return "어느 앱에서든 선택한 텍스트를 읽거나 해설합니다."
            }
        }
    }

    // Persist the actual edited value, rather than observing a Boolean expression.
    private func saved<Value>(_ path: ReferenceWritableKeyPath<AppState, Value>) -> Binding<Value> {
        Binding(get: { app[keyPath: path] }, set: { value in
            app[keyPath: path] = value
            app.saveSettings()
        })
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("설정").font(.headline).padding(.horizontal, 12).padding(.bottom, 12)
                ForEach(Category.allCases) { item in
                    Button { category = item } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(category == item ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(category == item ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(category == item ? .isSelected : [])
                }
                Spacer()
            }
            .padding(12).frame(width: 155)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(category.rawValue).font(.title2.bold())
                    Text(category.subtitle).font(.callout).foregroundStyle(.secondary)
                }.padding(20)
                Form {
                    switch category {
                    case .voice: voiceSettings
                    case .services: services
                    case .script: scriptSettings
                    case .playback: playbackSettings
                    case .shortcuts: shortcuts
                    }
                }.formStyle(.grouped)
                Text("일반 설정은 자동으로 저장됩니다")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showGlossary) { GlossaryEditorView() }
        .sheet(item: $editingService) { endpoint in ServiceEditor(endpoint: endpoint).environmentObject(app) }
        .onAppear {
            keyInput = Secrets.elevenLabsKey ?? ""
            editingKey = !app.keyPresent
            app.refreshAllModelsIfNeeded()
            if app.voices.isEmpty && app.keyPresent { app.refreshVoices() }
        }
        .onDisappear { preview.stop() }
        .onChange(of: category) { _, _ in preview.stop() }
        .onChange(of: app.backendKind) { _, _ in preview.stop() }
        .onChange(of: app.localBaseURL) { _, _ in localStatus = "확인 안 됨" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = SelectionGrabber.hasPermission
        }
    }

    @ViewBuilder private var voiceSettings: some View {
        Section("합성 엔진") {
            Picker("엔진", selection: saved(\.backendKind)) {
                ForEach(AppState.BackendKind.allCases) { Text($0.label).tag($0) }
            }
            if app.backendKind.requiresAPIKey {
                Text(app.connectionStatus.isEmpty ? "연결 확인이 필요합니다" : app.connectionStatus)
                    .font(.callout).foregroundStyle(.secondary)
                if editingKey {
                    SecureField("API 키", text: $keyInput)
                    Button("저장 및 연결 확인") {
                        app.saveKey(keyInput)
                        editingKey = false
                    }.disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    HStack {
                        Text("API 키  ••••••••").foregroundStyle(.secondary)
                        Spacer()
                        Button("변경") { editingKey = true }
                        Button("연결 확인") { app.refreshVoices() }
                    }
                }
            } else {
                TextField("서버 주소", text: saved(\.localBaseURL))
                HStack {
                    Text(localStatus).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("연결 확인") { checkLocal() }.disabled(checkingLocal)
                }
                Text("로컬 Qwen3 서버를 실행해 주세요. 목소리는 서버에 등록된 참조 음성을 사용합니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if app.backendKind.hasVoiceList {
            Section("보이스 및 모델") {
                if app.voices.isEmpty {
                    Text("먼저 연결을 확인하면 보이스 목록이 표시됩니다.").foregroundStyle(.secondary)
                } else {
                    Picker("보이스", selection: Binding(get: { app.voiceId }, set: { id in
                        app.voiceId = id
                        app.voiceName = app.voices.first(where: { $0.id == id })?.name ?? id
                        app.saveSettings()
                    })) {
                        if !app.voices.contains(where: { $0.id == app.voiceId }) {
                            Text("현재 보이스 (목록에 없음)").tag(app.voiceId)
                        }
                        ForEach(app.voices) { Text($0.name).tag($0.id) }
                    }
                }
                Picker("합성 모델", selection: saved(\.modelId)) {
                    if !app.elevenModels.contains(where: { $0.id == app.modelId }) {
                        Text("현재 모델: \(app.modelId) (목록에 없음)").tag(app.modelId)
                    }
                    ForEach(app.elevenModels) { Text($0.name).tag($0.id) }
                }.disabled(!app.keyPresent)
                HStack {
                    Text(app.modelStatus).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("모델 새로고침") { app.refreshModels() }
                        .disabled(!app.keyPresent || app.refreshingModels)
                }
            }
        }
        Section("미리 듣기") {
            TextField("읽어 볼 문장", text: $sample, axis: .vertical).lineLimit(1...3)
                .onChange(of: sample) { _, value in if value.count > 300 { sample = String(value.prefix(300)) } }
            Text("최대 300자").font(.caption).foregroundStyle(.secondary)
            HStack {
                if preview.busy {
                    Button("중지", systemImage: "stop.fill") { preview.stop() }
                } else {
                    Button("미리 듣기", systemImage: "play.fill") { preview.start(app: app, text: sample) }
                        .buttonStyle(.borderedProminent)
                        .disabled(sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (app.backendKind.requiresAPIKey && !app.keyPresent))
                }
                Text(preview.status).font(.caption).foregroundStyle(.secondary)
            }
            Text(app.backendKind.requiresAPIKey ? "클라우드 음성은 API 사용량이 발생합니다." : "서버에 등록된 참조 음성으로 재생합니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if app.backendKind == .elevenlabs {
            Section {
                DisclosureGroup("고급 음성 설정") {
                    tuning("안정성", hint: "높을수록 목소리 변화가 줄어듭니다.", value: saved(\.voiceSettings.stability))
                    tuning("유사도", hint: "원래 목소리를 얼마나 가깝게 재현할지 조절합니다.", value: saved(\.voiceSettings.similarityBoost))
                    tuning("스타일", hint: "말투와 표현의 강도를 조절합니다.", value: saved(\.voiceSettings.style))
                        .disabled(app.elevenModels.first(where: { $0.id == app.modelId })?.canUseStyle != true)
                    Toggle("목소리 유사도 강화", isOn: saved(\.voiceSettings.useSpeakerBoost))
                        .disabled(app.elevenModels.first(where: { $0.id == app.modelId })?.canUseSpeakerBoost != true)
                    Text("선택한 모델이 지원하는 고급 설정만 적용됩니다. 모델 목록을 새로고침해 지원 여부를 확인하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var services: some View {
        Section {
            HStack {
                Text("등록된 서비스").font(.headline)
                Spacer()
                Button("서비스 추가", systemImage: "plus") {
                    editingService = CustomEndpoint(name: "OpenAI", baseURL: CustomEndpoint.Provider.openAI.baseURL, apiStyle: .openAICompatible, provider: .openAI)
                }
            }
            if app.endpoints.isEmpty {
                Text("서비스를 추가하면 TTS·해설 화면에서 모델을 선택할 수 있습니다.").foregroundStyle(.secondary)
            }
            ForEach(app.endpoints) { endpoint in
                HStack(spacing: 12) {
                    Image(systemName: endpoint.apiStyle == .ollama ? "desktopcomputer" : "network")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(endpoint.name).font(.headline)
                        Text("\(endpoint.resolvedProvider.label) · \(endpoint.connectionLabel)").font(.caption).foregroundStyle(.secondary)
                        Text(endpoint.isEnabled ? (app.endpointStatus[endpoint.id.uuidString] ?? "확인 안 됨") : "비활성")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("편집") { editingService = endpoint }
                        .accessibilityLabel("\(endpoint.name) 편집")
                }.padding(.vertical, 6)
            }
        }
    }

    private var scriptSettings: some View {
        Group {
            Section("대본 다듬기") {
                Toggle("읽기 좋게 대본 다듬기", isOn: saved(\.normalizeEnabled))
                Text("숫자·기호·코드 이름을 발음하기 좋은 형태로 바꿉니다. 끄면 원문을 그대로 사용합니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("발음 사전") {
                LabeledContent("등록된 용어", value: "\(app.glossary.count)개")
                Button("발음 사전 편집…") { showGlossary = true }
                Text("예: np → 넘파이. 대본 다듬기가 켜져 있을 때 사용하며, 해설에는 적용하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var playbackSettings: some View {
        Group {
            Section("재생 자막") {
                Toggle("읽어주기 자막 표시", isOn: saved(\.subtitleTTS))
                Toggle("해설 자막 표시", isOn: saved(\.subtitleExplain))
            }
            Section("음성 캐시") {
                Toggle("같은 텍스트는 저장된 음성으로 재생", isOn: saved(\.useCache))
                Text("같은 음성 설정으로 만든 오디오를 재사용해 API 호출을 줄입니다.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                DisclosureGroup("고급 합성 설정") {
                    Stepper("합성 분할 길이: \(app.maxChunkChars)자", value: saved(\.maxChunkChars), in: 100...5000, step: 100)
                    Text("긴 대본을 나눠 합성하는 기준입니다.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var shortcuts: some View {
        Group {
            Section("선택한 텍스트") {
                LabeledContent("읽어주기", value: "⌃⌥⌘R")
                LabeledContent("코드 해설", value: "⌃⌥⌘E")
            }
            Section("손쉬운 사용 권한") {
                Label(hasPermission ? "허용됨" : "권한이 필요합니다", systemImage: hasPermission ? "checkmark.circle" : "exclamationmark.circle")
                Button("시스템 설정 열기") {
                    SelectionGrabber.requestPermission()
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                }
                Text("텍스트를 선택하고 단축키를 누르세요. 기존 클립보드 내용은 복원됩니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func tuning(_ title: String, hint: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(title); Spacer(); Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit() }
            Slider(value: value, in: 0...1)
            Text(hint).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }

    private func checkLocal() {
        guard let url = serviceURL(app.localBaseURL) else { localStatus = "http 또는 https 서버 주소를 입력하세요"; return }
        checkingLocal = true
        localStatus = "연결 확인 중…"
        Task { @MainActor in
            defer { checkingLocal = false }
            do {
                let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url.appendingPathComponent("health"), timeoutInterval: 10))
                guard app.localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) == url.absoluteString else { localStatus = "주소가 변경되었습니다. 다시 확인하세요."; return }
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ready = body["ready"] as? Bool else { throw URLError(.badServerResponse) }
                localStatus = ready ? "연결됨 · 음성 생성 준비 완료" : "연결됨 · 모델 준비 중"
            } catch { localStatus = "연결 실패: \(error.localizedDescription)" }
        }
    }
}

func serviceURL(_ value: String) -> URL? {
    guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host, !host.isEmpty else { return nil }
    return url
}

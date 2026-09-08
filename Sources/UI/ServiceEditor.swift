import SwiftUI

/// Edits a draft: cancel never changes the registered service or its key.
struct ServiceEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State var endpoint: CustomEndpoint
    @State private var key = ""
    @State private var confirmDelete = false
    @State private var saved = false
    @StateObject private var googleLogin = AntigravityLogin()
    @StateObject private var planLogin = CodexPlanLogin()

    private var exists: Bool { app.endpoints.contains { $0.id == endpoint.id } }
    private var status: String { app.endpointStatus[endpoint.id.uuidString] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(exists ? "서비스 편집" : "서비스 추가").font(.title2.bold())
            Form {
                Section("연결 정보") {
                    Picker("공급자", selection: Binding(get: { endpoint.resolvedProvider }, set: { provider in
                        planLogin.cancel(); googleLogin.cancel()
                        endpoint.provider = provider
                        endpoint.apiStyle = provider.apiStyle
                        endpoint.baseURL = provider.baseURL
                        endpoint.name = provider.label
                        endpoint.defaultModel = ""
                        endpoint.connection = .apiKey
                        key = ""
                        saved = false
                    })) {
                        ForEach(CustomEndpoint.Provider.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("이름", text: $endpoint.name)
                    if !endpoint.usesPlan {
                        if endpoint.resolvedProvider == .compatible || endpoint.resolvedProvider == .ollama {
                            addressField
                        } else {
                            DisclosureGroup("고급 연결 설정") { addressField }
                        }
                    }
                    connectionFields
                    Toggle("이 서비스 사용", isOn: $endpoint.isEnabled)
                }
                Section("기본 모델") {
                    TextField("모델 이름 (선택)", text: $endpoint.defaultModel)
                    let models = endpoint.usesPlan && endpoint.resolvedProvider == .google && !googleLogin.models.isEmpty
                        ? googleLogin.models : app.models(for: endpoint)
                    if !models.isEmpty {
                        Menu("조회한 모델에서 선택") {
                            ForEach(models, id: \.self) { model in
                                Button(model) { endpoint.defaultModel = model }
                            }
                        }
                    }
                    Text(endpoint.usesPlan && endpoint.resolvedProvider == .google
                         ? "연결 확인 후 Antigravity 모델을 선택할 수 있습니다. 비워 두면 첫 모델을 사용합니다."
                         : "비워 두면 연결 후 첫 모델을 사용합니다. TTS·해설 화면에서 다른 모델을 선택할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if saved {
                    Section("연결 결과") {
                        Text(status.isEmpty ? "저장됨" : status).textSelection(.enabled)
                        if status.contains("실패") {
                            Text(endpoint.usesPlan ? "로그인 상태와 CLI 설치를 확인하세요. 입력 내용은 유지됩니다." : "주소와 API 키를 확인하고 다시 시도하세요. 입력 내용은 유지됩니다.").font(.caption)
                        }
                    }
                }
            }.formStyle(.grouped)
            HStack {
                if exists {
                    Button("서비스 삭제…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button(saved ? "닫기" : "취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("저장 및 연결 확인") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled((!endpoint.usesPlan && serviceURL(endpoint.baseURL) == nil) || status == "확인 중…" || planLogin.busy || googleLogin.busy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 510, height: 560)
        .onAppear { key = Secrets.endpointKey(endpoint.id) ?? "" }
        .task(id: endpoint.cacheIdentity) {
            if endpoint.usesPlan && endpoint.resolvedProvider == .google { googleLogin.check() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if endpoint.usesPlan && endpoint.resolvedProvider == .google && !googleLogin.busy {
                googleLogin.check()
            }
        }
        .onDisappear { planLogin.cancel(); googleLogin.cancel() }
        .alert("\(endpoint.name)을 삭제할까요?", isPresented: $confirmDelete) {
            Button("취소", role: .cancel) { }
            Button("삭제", role: .destructive) { app.deleteEndpoint(endpoint.id); dismiss() }
        } message: {
            Text("이 서비스를 사용하는 해설·대본 모델 선택은 남아 있는 서비스로 전환됩니다. 서비스 설정은 복구할 수 없습니다.")
        }
    }

    private var addressField: some View {
        VStack(alignment: .leading) {
            TextField("서버 주소", text: $endpoint.baseURL)
            if serviceURL(endpoint.baseURL) == nil {
                Text("http 또는 https 주소를 입력하세요.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var connectionFields: some View {
        if endpoint.resolvedProvider.supportsPlan {
            Picker("연결 방식", selection: Binding(get: { endpoint.connectionMethod }, set: { method in
                planLogin.cancel(); googleLogin.cancel()
                endpoint.connection = method
                endpoint.defaultModel = ""
                saved = false
            })) {
                ForEach(CustomEndpoint.Connection.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented)
        }
        if endpoint.usesPlan {
            if endpoint.resolvedProvider == .google {
                Text(googleLogin.status).font(.callout).foregroundStyle(.secondary)
                if AntigravityPlan.executable == nil {
                    Link("Antigravity CLI 설치 안내", destination: URL(string: "https://antigravity.google/docs/cli/install/")!)
                } else {
                    HStack {
                        Button(googleLogin.models.isEmpty ? "Google 계정 연결" : "연결 다시 확인") {
                            googleLogin.check(openLoginIfNeeded: true)
                        }.disabled(googleLogin.busy)
                        if googleLogin.busy {
                            ProgressView().controlSize(.small)
                            Button("확인 중지") { googleLogin.cancel() }
                        }
                    }
                }
                Text("구독 한도를 사용하며 API·추가 AI 크레딧으로 전환하지 않습니다. 자동 연결은 텍스트 전용이며 온도 설정은 적용되지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
            Text(planLogin.status).font(.callout).foregroundStyle(.secondary)
            if CodexPlanRPC.executable == nil {
                Link("Codex CLI 설치 안내", destination: URL(string: "https://developers.openai.com/codex/cli")!)
            } else {
                HStack {
                    Button("ChatGPT로 로그인") { planLogin.login() }.disabled(planLogin.busy)
                    if planLogin.busy { Button("로그인 취소") { planLogin.cancel(); googleLogin.cancel() } }
                }
            }
            Text("공식 Codex 연결로 구독 한도를 사용합니다. API로 자동 전환하지 않습니다. 온도 설정은 적용되지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            SecureField(endpoint.resolvedProvider == .ollama ? "API 키 (선택)" : "API 키", text: $key)
            Text(endpoint.resolvedProvider.supportsPlan
                 ? "키는 이 Mac에 저장됩니다. 기존 플랜으로 전환해도 저장된 키는 유지됩니다."
                 : "키는 이 Mac에 저장됩니다. 키가 필요한 서비스에서만 입력하세요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func save() {
        endpoint.baseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint.name = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint.defaultModel = endpoint.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.name.isEmpty { endpoint.name = endpoint.apiStyle.label }
        if exists {
            app.updateEndpoint(endpoint)
            if endpoint.usesPlan {
                app.refreshEndpointModels(endpoint)
            } else {
                app.saveEndpointKey(endpoint.id, key)
                if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && endpoint.apiStyle == .gemini {
                    app.refreshEndpointModels(endpoint)
                }
            }
        } else {
            app.addEndpoint(name: endpoint.name, baseURL: endpoint.baseURL, style: endpoint.apiStyle,
                            apiKey: key, defaultModel: endpoint.defaultModel, isEnabled: endpoint.isEnabled,
                            provider: endpoint.resolvedProvider, connection: endpoint.connectionMethod)
            if let added = app.endpoints.last { endpoint = added }
        }
        saved = true
    }
}

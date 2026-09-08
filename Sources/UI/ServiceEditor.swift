import SwiftUI

/// Edits a draft: cancel never changes the registered service or its key.
struct ServiceEditor: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State var endpoint: CustomEndpoint
    @State private var key = ""
    @State private var confirmDelete = false
    @State private var saved = false

    private var exists: Bool { app.endpoints.contains { $0.id == endpoint.id } }
    private var status: String { app.endpointStatus[endpoint.id.uuidString] ?? "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(exists ? "서비스 편집" : "서비스 추가").font(.title2.bold())
            Form {
                Section("연결 정보") {
                    Picker("서비스 유형", selection: $endpoint.apiStyle) {
                        ForEach(CustomEndpoint.APIStyle.allCases) { Text($0.label).tag($0) }
                    }
                    TextField("이름", text: $endpoint.name)
                    TextField("서버 주소", text: $endpoint.baseURL)
                    if serviceURL(endpoint.baseURL) == nil {
                        Text("http:// 또는 https://로 시작하는 주소를 입력하세요.").font(.caption).foregroundStyle(.secondary)
                    }
                    SecureField("API 키 (로컬 서비스는 선택)", text: $key)
                    Text("키는 이 Mac에 저장됩니다. 빈 값으로 저장하면 기존 키를 지웁니다.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("이 서비스 사용", isOn: $endpoint.isEnabled)
                }
                Section("기본 모델") {
                    TextField("모델 이름 (선택)", text: $endpoint.defaultModel)
                    let models = app.models(for: endpoint)
                    if !models.isEmpty {
                        Menu("조회한 모델에서 선택") {
                            ForEach(models, id: \.self) { model in
                                Button(model) { endpoint.defaultModel = model }
                            }
                        }
                    }
                    Text("비워 두면 연결 후 첫 모델을 사용합니다. TTS·해설 화면에서 다른 모델을 선택할 수 있습니다.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if saved {
                    Section("연결 결과") {
                        Text(status.isEmpty ? "저장됨" : status).textSelection(.enabled)
                        if status.contains("실패") {
                            Text("주소와 API 키를 확인하고 다시 시도하세요. 입력 내용은 유지됩니다.").font(.caption)
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
                    .disabled(serviceURL(endpoint.baseURL) == nil || status == "확인 중…")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 510, height: 560)
        .onAppear { key = Secrets.endpointKey(endpoint.id) ?? "" }
        .onChange(of: endpoint.apiStyle) { _, style in
            guard !exists else { return }
            switch style {
            case .gemini: endpoint.baseURL = "https://generativelanguage.googleapis.com/v1beta"; endpoint.name = "Gemini"
            case .ollama: endpoint.baseURL = "http://localhost:11434"; endpoint.name = "Ollama"
            case .openAICompatible: endpoint.baseURL = ""; endpoint.name = ""
            }
        }
        .alert("\(endpoint.name)을 삭제할까요?", isPresented: $confirmDelete) {
            Button("취소", role: .cancel) { }
            Button("삭제", role: .destructive) { app.deleteEndpoint(endpoint.id); dismiss() }
        } message: {
            Text("이 서비스를 사용하는 해설·대본 모델 선택은 남아 있는 서비스로 전환됩니다. 서비스 설정은 복구할 수 없습니다.")
        }
    }

    private func save() {
        endpoint.baseURL = endpoint.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint.name = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint.defaultModel = endpoint.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if endpoint.name.isEmpty { endpoint.name = endpoint.apiStyle.label }
        if let index = app.endpoints.firstIndex(where: { $0.id == endpoint.id }) {
            app.endpoints[index] = endpoint
            app.saveSettings()
            app.saveEndpointKey(endpoint.id, key)
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && endpoint.apiStyle == .gemini {
                app.refreshEndpointModels(endpoint)
            }
        } else {
            app.addEndpoint(name: endpoint.name, baseURL: endpoint.baseURL, style: endpoint.apiStyle,
                            apiKey: key, defaultModel: endpoint.defaultModel, isEnabled: endpoint.isEnabled)
            if let added = app.endpoints.last { endpoint = added }
        }
        saved = true
    }
}

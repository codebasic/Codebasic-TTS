import SwiftUI

/// Connection management: status, API key, voice refresh, local sidecar URL.
struct ConnectionView: View {
    @EnvironmentObject var app: AppState
    @State private var keyInput = ""

    var body: some View {
        Form {
            Section("상태") {
                LabeledContent("백엔드", value: app.backendKind.label)
                LabeledContent("API 키", value: app.keyPresent ? "설정됨" : "없음")
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
        .onAppear { if app.voices.isEmpty && app.keyPresent { app.refreshVoices() } }
        .onChange(of: app.localBaseURL) { _, _ in app.saveSettings() }
    }
}

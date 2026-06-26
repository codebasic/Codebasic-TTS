import SwiftUI

/// Generation settings: backend, voice, model, voice tuning, cache.
struct SettingsView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Form {
            Section("백엔드") {
                Picker("엔진", selection: $app.backendKind) {
                    ForEach(AppState.BackendKind.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("보이스 / 모델") {
                if app.voices.isEmpty {
                    LabeledContent("보이스 ID") {
                        TextField("voice id", text: $app.voiceId).frame(width: 220)
                    }
                    Text("연결 탭에서 ‘보이스 새로고침’을 누르면 목록에서 고를 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
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

            Section("캐시") {
                Toggle("같은 텍스트는 캐시에서 재생 (API 재호출 안 함)", isOn: $app.useCache)
            }
        }
        .formStyle(.grouped)
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
}

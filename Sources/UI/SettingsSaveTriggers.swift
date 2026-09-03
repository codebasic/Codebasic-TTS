import SwiftUI

/// Settings 화면의 저장 트리거 묶음. 관찰 필드가 많아 body의 onChange 체인이
/// 컴파일러 타입체크 한계를 넘기면서 body에서 분리했고, 체인 하나가 너무 길어지면
/// 역시 타입체크가 느려지므로 두 개로 쪼갰다. 새 저장 대상 필드는 둘 중 알맞은
/// 쪽에 onChange 한 줄을 더한다.
struct SettingsSaveTriggersA: ViewModifier {
    @ObservedObject var app: AppState
    let voiceId: String

    func body(content: Content) -> some View {
        content
            .onChange(of: app.localBaseURL) { _, _ in app.saveSettings() }
            .onChange(of: app.maxChunkChars) { _, _ in app.saveSettings() }
            .onChange(of: app.subtitleTTS) { _, _ in app.saveSettings() }
            .onChange(of: app.subtitleExplain) { _, _ in app.saveSettings() }
            .onChange(of: voiceId) { _, newID in
                if let v = app.voices.first(where: { $0.id == newID }) { app.voiceName = v.name }
                app.saveSettings()
            }
            .onChange(of: app.modelId) { _, _ in app.saveSettings() }
            .onChange(of: app.backendKind) { _, _ in app.saveSettings() }
            .onChange(of: app.useCache) { _, _ in app.saveSettings() }
            .onChange(of: app.voiceSettings) { _, _ in app.saveSettings() }
    }
}

struct SettingsSaveTriggersB: ViewModifier {
    @ObservedObject var app: AppState

    func body(content: Content) -> some View {
        content
            .onChange(of: app.normalizeEnabled) { _, _ in app.saveSettings() }
            .onChange(of: app.normalizeProvider) { _, _ in app.saveSettings() }
            .onChange(of: app.geminiModel) { _, _ in app.saveSettings() }
            .onChange(of: app.geminiBaseURL) { _, _ in app.saveSettings() }
            .onChange(of: app.openCodeModel) { _, _ in app.saveSettings() }
            .onChange(of: app.openCodeBaseURL) { _, _ in app.saveSettings() }
            .onChange(of: app.openAIModel) { _, _ in app.saveSettings() }
            .onChange(of: app.openAIBaseURL) { _, _ in app.saveSettings() }
            .onChange(of: app.reviewEnabled) { _, _ in app.saveSettings() }
            .onChange(of: app.ollamaModel) { _, _ in app.saveSettings() }
            .onChange(of: app.ollamaURL) { _, _ in app.saveSettings() }
    }
}

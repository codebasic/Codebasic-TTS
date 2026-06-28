import SwiftUI

/// In-panel model selector for one LLM role. Lists models from ALL connected
/// providers (Ollama + Gemini) — picking one sets both the role's provider and
/// that provider's model field. Ollama and Gemini can be configured at once.
struct LLMModelPicker: View {
    @EnvironmentObject var app: AppState
    let label: String
    @Binding var provider: AppState.NormalizeProvider
    @Binding var geminiModel: String
    @Binding var ollamaModel: String
    var onChange: () -> Void = {}

    private var current: AppState.LLMChoice {
        AppState.LLMChoice(provider: provider, model: provider == .gemini ? geminiModel : ollamaModel)
    }

    /// Connected models, with the current selection folded in so a saved model
    /// from an offline/unfetched provider still shows.
    private var options: [AppState.LLMChoice] {
        var m = app.connectedModels
        if !current.model.isEmpty && !m.contains(where: { $0.id == current.id }) { m.insert(current, at: 0) }
        return m
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if options.isEmpty {
                Text("연결된 모델 없음").font(.caption).foregroundStyle(.tertiary)
            } else {
                Picker("", selection: Binding(
                    get: { current.id },
                    set: { id in
                        guard let c = options.first(where: { $0.id == id }) else { return }
                        provider = c.provider
                        if c.provider == .gemini { geminiModel = c.model } else { ollamaModel = c.model }
                        onChange()
                    }
                )) {
                    ForEach(options) { Text($0.label).tag($0.id) }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
            Button { app.refreshAllModels() } label: { Image(systemName: "arrow.clockwise") }
                .controlSize(.small)
                .help("연결된 제공자(Ollama·Gemini)에서 모델 목록 새로고침")
        }
        .onAppear { app.refreshAllModelsIfNeeded() }
    }
}

import SwiftUI

/// Compact, in-panel model selector for one LLM role (해설 or 대본). Lists the
/// models the current provider's endpoint exposes — Ollama `api/tags`, Gemini
/// `models.list` (static fallback until fetched) — so 해설 and 대본 can run on
/// different models. The bound value is per-provider; only the active one shows.
struct LLMModelPicker: View {
    @EnvironmentObject var app: AppState
    let label: String
    @Binding var ollamaModel: String
    @Binding var geminiModel: String
    var onChange: () -> Void = {}

    /// Endpoint models, with the current selection folded in so a saved model
    /// that the endpoint doesn't list still shows (instead of a blank popup).
    private var options: [String] {
        let sel = app.normalizeProvider == .gemini ? geminiModel : ollamaModel
        var m = app.providerModels
        if !sel.isEmpty && !m.contains(sel) { m.insert(sel, at: 0) }
        return m
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if options.isEmpty {
                TextField(app.normalizeProvider == .gemini ? "gemini-2.0-flash" : "qwen2.5:3b",
                          text: app.normalizeProvider == .gemini ? $geminiModel : $ollamaModel)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
            } else {
                Picker("", selection: app.normalizeProvider == .gemini ? $geminiModel : $ollamaModel) {
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 220)
            }
            Button {
                if app.normalizeProvider == .gemini { app.refreshGeminiModels() }
                else { app.refreshOllamaModels() }
            } label: { Image(systemName: "arrow.clockwise") }
            .controlSize(.small)
            .help("엔드포인트(\(app.normalizeProvider.label))에서 모델 목록 새로고침")
        }
        .onChange(of: ollamaModel) { _, _ in onChange() }
        .onChange(of: geminiModel) { _, _ in onChange() }
        .onAppear {
            if app.normalizeProvider == .ollama && app.ollamaModels.isEmpty { app.refreshOllamaModels() }
            if app.normalizeProvider == .gemini && app.geminiModels.isEmpty { app.refreshGeminiModels() }
        }
    }
}

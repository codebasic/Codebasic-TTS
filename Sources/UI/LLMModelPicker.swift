import SwiftUI

/// In-panel model selector for one LLM role. Lists models from ALL connected
/// providers (Ollama · Gemini · OpenCode · OpenRouter) — picking one sets both
/// the role's provider and that provider's model field. All four channels can
/// be configured at once (Settings → 텍스트 생성).
struct LLMModelPicker: View {
    @EnvironmentObject var app: AppState
    let label: String
    let role: AppState.LLMRole
    var onChange: () -> Void = {}

    private var current: AppState.LLMChoice {
        AppState.LLMChoice(provider: app.roleProvider(role), model: app.roleModel(role))
    }

    /// Connected models, with the current selection folded in so a saved model
    /// from an offline/unfetched provider still shows.
    private var options: [AppState.LLMChoice] {
        var m = app.connectedModels
        if !current.model.isEmpty && !m.contains(where: { $0.id == current.id }) { m.append(current) }
        return m
    }

    private struct Group: Identifiable {
        let provider: AppState.NormalizeProvider
        let models: [AppState.LLMChoice]
        var id: String { provider.rawValue }
    }
    /// Models grouped by provider (declaration order), sorted by name within each.
    private var grouped: [Group] {
        AppState.NormalizeProvider.allCases.compactMap { prov -> Group? in
            let ms = options.filter { $0.provider == prov }
                .sorted { $0.model.lowercased() < $1.model.lowercased() }
            return ms.isEmpty ? nil : Group(provider: prov, models: ms)
        }
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
                        app.setRole(role, provider: c.provider, model: c.model)
                        onChange()
                    }
                )) {
                    ForEach(grouped) { group in
                        Section(group.provider.label) {
                            ForEach(group.models) { Text($0.model).tag($0.id) }
                        }
                    }
                }
                .labelsHidden().frame(maxWidth: 260)
            }
        }
        .onAppear { app.refreshAllModelsIfNeeded() }
    }
}

import SwiftUI

/// In-panel model selector for one LLM role. Lists models from ALL enabled
/// endpoints, grouped per endpoint — picking one sets both the role's endpoint
/// reference and that endpoint's remembered model for the role. Any number of
/// endpoints can be configured at once (settings → 엔드포인트).
struct LLMModelPicker: View {
    @EnvironmentObject var app: AppState
    let label: String
    @Binding var endpointID: String                    // role → endpoint reference
    @Binding var roleModels: [String: String]          // endpoint id → the role's model there
    var onChange: () -> Void = {}

    private var current: AppState.LLMChoice? {
        guard let e = app.activeEndpoint(byID: endpointID) else { return nil }
        return AppState.LLMChoice(endpointID: e.id.uuidString, endpointName: e.name,
                                  model: app.roleModel(roleModels, e))
    }

    /// Connected models, with the current selection folded in so a saved model
    /// from an offline/unfetched endpoint still shows.
    private var options: [AppState.LLMChoice] {
        var m = app.connectedModels
        if let c = current, !c.model.isEmpty, !m.contains(where: { $0.id == c.id }) { m.append(c) }
        return m
    }

    private struct Group: Identifiable {
        let endpointID: String
        let name: String
        let models: [AppState.LLMChoice]
        var id: String { endpointID }
    }
    /// Models grouped per endpoint (in registration order), sorted by name within each.
    private var grouped: [Group] {
        app.endpoints.compactMap { e -> Group? in
            guard e.isEnabled else { return nil }
            let id = e.id.uuidString
            let ms = options.filter { $0.endpointID == id }
                .sorted { $0.model.lowercased() < $1.model.lowercased() }
            return ms.isEmpty ? nil : Group(endpointID: id, name: e.name, models: ms)
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if options.isEmpty {
                Text("연결된 모델 없음").font(.caption).foregroundStyle(.tertiary)
            } else {
                Picker("", selection: Binding(
                    get: { current?.id ?? "" },
                    set: { id in
                        guard let c = options.first(where: { $0.id == id }) else { return }
                        endpointID = c.endpointID
                        roleModels[c.endpointID] = c.model
                        onChange()
                    }
                )) {
                    ForEach(grouped) { group in
                        Section(group.name) {
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

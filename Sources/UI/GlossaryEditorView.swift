import SwiftUI

/// 용어 발음 사전(glossary) 편집 패널: term/pronunciation/note 3열 리스트 +
/// 행 추가·삭제 + 검색. 편집은 app.glossary에 곧바로 반영되고 변경마다
/// settings.json에 저장된다 (설정 → 텍스트 생성 채널의 "편집…" 시트).
struct GlossaryEditorView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    /// 검색 필터를 통과한 행. 원본 배열의 offset을 함께 들고 다녀야
    /// 바인딩·삭제가 필터 상태와 무관하게 올바른 행을 가리킨다.
    private var visible: [(offset: Int, element: GlossaryEntry)] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return app.glossary.enumerated().filter { pair in
            q.isEmpty
                || pair.element.term.localizedCaseInsensitiveContains(q)
                || pair.element.pronunciation.localizedCaseInsensitiveContains(q)
                || pair.element.note.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("용어 발음 사전 (대본)").font(.headline)
                Text("\(app.glossary.count)개 항목").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    // 검색 중이면 빈 새 행이 필터에 걸려 보이지 않는다 — 버튼이
                    // 먹통처럼 보이지 않도록 검색을 먼저 푼다.
                    search = ""
                    app.glossary.append(GlossaryEntry(term: "", pronunciation: "", note: ""))
                } label: {
                    Label("행 추가", systemImage: "plus")
                }
                .help("빈 행을 추가합니다")
                Button("완료") { dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
            Text("대본(정규화) 생성 시 이 사전이 few-shot으로 주입됩니다: 등록된 용어는 발음 그대로 변환되고, 사전에 없는 표기는 기존 정규화 규칙을 따릅니다.")
                .font(.caption).foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("검색 (용어·발음·메모)", text: $search)
                    .textFieldStyle(.roundedBorder)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .help("검색 지우기")
                }
            }

            List {
                ForEach(visible, id: \.element.id) { pair in
                    row(index: pair.offset)
                }
            }
            .listStyle(.inset)
        }
        .padding()
        .frame(minWidth: 580, minHeight: 420)
        .onChange(of: app.glossary) { _, _ in app.saveSettings() }
        .onDisappear { app.saveSettings() }
    }

    @ViewBuilder private func row(index: Int) -> some View {
        HStack(spacing: 6) {
            TextField("용어 (예: np)", text: binding(index, \.term))
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
            TextField("발음 (예: 넘파이)", text: binding(index, \.pronunciation))
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
            TextField("메모 (선택)", text: binding(index, \.note))
                .textFieldStyle(.roundedBorder)
            Spacer()
            Button(role: .destructive) {
                if app.glossary.indices.contains(index) { app.glossary.remove(at: index) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("행 삭제")
        }
    }

    /// index가 배열 범위를 벗어나면(삭제 직후 재계산 사이 등) 안전하게 빈 값을 쓴다.
    private func binding(_ index: Int, _ keyPath: WritableKeyPath<GlossaryEntry, String>) -> Binding<String> {
        Binding(
            get: { app.glossary.indices.contains(index) ? app.glossary[index][keyPath: keyPath] : "" },
            set: { if app.glossary.indices.contains(index) { app.glossary[index][keyPath: keyPath] = $0 } }
        )
    }
}

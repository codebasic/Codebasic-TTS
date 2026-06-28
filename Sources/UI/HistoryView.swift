import SwiftUI

/// Cache / history backed by SQLite: searchable, sortable, and paged (show N,
/// load more) so it stays usable as it grows — the full set is reachable via
/// search/sort without loading or rendering everything at once.
struct HistoryView: View {
    @EnvironmentObject var app: AppState
    @State private var search = ""
    @State private var sort: HistorySort = .recent
    @State private var limit = 50
    @State private var results: [HistoryEntry] = []
    @State private var total = 0
    private let page = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("히스토리").font(.headline)
                Text(countLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("정렬", selection: $sort) {
                    ForEach(HistorySort.allCases) { Text($0.label).tag($0) }
                }
                .controlSize(.small).fixedSize()
                Button(role: .destructive) { app.clearHistory() } label: {
                    Label("전체 삭제", systemImage: "trash")
                }
                .controlSize(.small).disabled(total == 0)
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("검색 (본문·보이스)", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(6).background(Color.secondary.opacity(0.08)).cornerRadius(6)

            if total == 0 {
                emptyState(search.isEmpty ? "아직 생성 기록이 없습니다." : "검색 결과가 없습니다.")
            } else {
                List {
                    ForEach(results) { row($0) }
                    if results.count < total {
                        HStack {
                            Spacer()
                            Button("더 보기 (+\(min(page, total - results.count)))") {
                                limit = results.count + page; reload()
                            }
                            Button("모두 표시 (\(total))") { limit = total; reload() }
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: app.historyRevision) { _, _ in reload() }
        .onChange(of: sort) { _, _ in reload() }
        .onChange(of: search) { _, _ in limit = page; reload() }
    }

    private func reload() {
        total = app.historyTotal(search: search)
        results = app.historyPage(search: search, sort: sort, limit: limit, offset: 0)
    }

    private var countLabel: String {
        if search.isEmpty {
            return results.count < total ? "· 전체 \(total)개 중 \(results.count)개 표시" : "· \(total)개"
        }
        return "· 검색 \(total)개 중 \(results.count)개 표시"
    }

    @ViewBuilder private func emptyState(_ text: String) -> some View {
        Spacer()
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center)
        Spacer()
    }

    @ViewBuilder private func row(_ e: HistoryEntry) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(e.text).lineLimit(2)
                Text("\(e.voiceName) · \(e.modelId) · "
                     + e.createdAt.formatted(date: .abbreviated, time: .shortened)
                     + " · \(e.bytes / 1024)KB")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { app.replay(e) } label: { Image(systemName: "play.circle") }
                .buttonStyle(.borderless).help("재생")
            Button(role: .destructive) { app.deleteHistory(e.id) } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless).help("삭제")
        }
        .padding(.vertical, 2)
    }
}

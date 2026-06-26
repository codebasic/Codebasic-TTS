import SwiftUI

/// Cache / history: past generations, replay from disk, delete.
struct HistoryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("히스토리 · \(app.history.count)개").font(.headline)
                Spacer()
                Button(role: .destructive) { app.clearHistory() } label: {
                    Label("전체 삭제", systemImage: "trash")
                }
                .disabled(app.history.isEmpty)
            }

            if app.history.isEmpty {
                Spacer()
                Text("아직 생성 기록이 없습니다.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                Spacer()
            } else {
                List {
                    ForEach(app.history) { e in
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
            }
        }
        .padding()
    }
}

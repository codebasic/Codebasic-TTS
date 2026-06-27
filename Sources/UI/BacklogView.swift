import SwiftUI
import AppKit

/// Collected problem cases: flagged generations with their full stage context
/// (input + prompt + hint + output), filterable by stage and tag, exportable
/// for offline analysis.
struct BacklogView: View {
    @EnvironmentObject var app: AppState
    @State private var stageFilter = "전체"
    @State private var tagFilter = "전체"

    private var filtered: [BacklogEntry] {
        app.backlog.filter { e in
            (stageFilter == "전체" || e.stage == stageFilter)
                && (tagFilter == "전체" || e.tags.contains(tagFilter))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("단계", selection: $stageFilter) {
                    Text("전체").tag("전체"); Text("해설").tag("해설"); Text("대본").tag("대본")
                }.fixedSize()
                Picker("태그", selection: $tagFilter) {
                    Text("전체 태그").tag("전체")
                    ForEach(app.backlogTags, id: \.self) { Text($0).tag($0) }
                }.fixedSize()
                Spacer()
                Text("\(filtered.count)건").font(.caption).foregroundStyle(.secondary)
                Button {
                    if let url = app.exportBacklog() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
                    .controlSize(.small).disabled(app.backlog.isEmpty)
                Button { app.clearBacklog() } label: { Label("전체 삭제", systemImage: "trash") }
                    .controlSize(.small).disabled(app.backlog.isEmpty)
            }

            if filtered.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("기록된 사례가 없습니다.").foregroundStyle(.secondary)
                    Text("해설/TTS 패널에서 ‘이슈 기록’을 누르면 현재 생성 컨텍스트(입력·프롬프트·추가 지시·출력)가 여기 모입니다.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { entry in
                    BacklogRow(entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .padding()
        .onChange(of: app.backlogTags) { _, tags in
            if tagFilter != "전체" && !tags.contains(tagFilter) { tagFilter = "전체" }
        }
    }
}

/// One backlog entry: a disclosure row with a summary header and an editable,
/// copy-enabled detail body.
private struct BacklogRow: View {
    @EnvironmentObject var app: AppState
    let entry: BacklogEntry
    @State private var expanded = false
    @State private var note = ""
    @State private var tagsText = ""

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                field("입력", entry.input)
                field("프롬프트", entry.prompt)
                if !entry.hint.isEmpty { field("추가 지시", entry.hint) }
                field("출력", entry.output)
                Text("\(entry.provider) · \(entry.model)").font(.caption2).foregroundStyle(.secondary)

                TextField("메모 (무엇이 문제였는지)", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...3)
                HStack {
                    TextField("태그 (쉼표로 구분)", text: $tagsText).textFieldStyle(.roundedBorder)
                    Button("저장") { commit() }
                    Spacer()
                    Button { app.deleteBacklog(entry.id) } label: { Image(systemName: "trash") }
                        .foregroundStyle(.red)
                }
            }
            .padding(.vertical, 4)
            .onAppear { note = entry.note; tagsText = entry.tags.joined(separator: ", ") }
        } label: {
            HStack(spacing: 6) {
                Text(entry.stage)
                    .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background((entry.stage == "해설" ? Color.blue : Color.purple).opacity(0.15))
                    .clipShape(Capsule())
                ForEach(entry.tags, id: \.self) { t in
                    Text(t).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.orange.opacity(0.18)).clipShape(Capsule())
                }
                Text(entry.note.isEmpty ? String(entry.input.replacingOccurrences(of: "\n", with: " ").prefix(48))
                                        : entry.note)
                    .font(.callout).lineLimit(1).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func commit() {
        var e = entry
        e.note = note
        e.tags = tagsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if e.tags.isEmpty { e.tags = ["이슈"] }
        app.updateBacklog(e)
    }

    @ViewBuilder
    private func field(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(text.isEmpty ? "—" : text)
                .font(.callout.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6).background(Color.secondary.opacity(0.06)).cornerRadius(4)
        }
    }
}

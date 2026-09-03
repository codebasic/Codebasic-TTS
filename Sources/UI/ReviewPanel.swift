import SwiftUI

/// 검수 블록 — 해설 탭·TTS 탭 공용. 자동 검수 토글, 수정 자동 반영 토글(공통),
/// 수동 실행, 검수 모델, 판정 배지, 리포트, 검수 지시문 편집(접이식).
/// 리포트는 원문을 덮어쓰지 않는다 — 수정 반영은 AppState가 판정을 읽어 수행.
struct ReviewPanel: View {
    @EnvironmentObject var app: AppState
    let title: String
    let autoLabel: String
    @Binding var enabled: Bool
    let reviewing: Bool
    let report: String
    let verdict: ReviewVerdict?
    let flagged: Bool            // 재검수 미통과로 원본을 유지한 상태
    @Binding var prompt: String
    let defaultPrompt: String
    let canRun: Bool
    let runHelp: String
    let run: () -> Void
    @State private var showPrompt = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(spacing: 16) {
                LLMModelPicker(label: "검수 모델", role: .review, onChange: { app.saveSettings() })
                Spacer()
            }
            if showPrompt { promptEditor }
            if !report.isEmpty {
                ScrollView {
                    Text(report).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(title).font(.headline)
            Toggle(autoLabel, isOn: $enabled)
                .toggleStyle(.checkbox).controlSize(.small)
                .onChange(of: enabled) { _, _ in app.saveSettings() }
            Toggle("수정 지시 자동 반영", isOn: $app.reviewAutoFix)
                .toggleStyle(.checkbox).controlSize(.small)
                .help("판정이 '수정'이면 검수 지시를 반영해 1회 재생성한 뒤 재검수합니다 (해설·대본 공통)")
                .onChange(of: app.reviewAutoFix) { _, _ in app.saveSettings() }
            if reviewing {
                ProgressView().controlSize(.small)
                Text("검수 중…").font(.caption).foregroundStyle(.secondary)
            } else if flagged {
                Label("재검수 미통과 — 원본 유지 (백로그 기록)", systemImage: "flag.fill")
                    .font(.caption.bold()).foregroundStyle(.red)
                    .help("수정 지시를 반영한 재생성본이 재검수에서도 '수정' 판정을 받아 버리고 원본을 유지했습니다. 상세는 백로그 탭")
            } else if let v = verdict {
                Text("판정: \(v.label)").font(.caption.bold()).foregroundStyle(color(for: v))
            }
            Spacer()
            Button { showPrompt.toggle() } label: { Image(systemName: "text.badge.checkmark") }
                .controlSize(.small)
                .help("검수 지시문 편집")
            Button(action: run) { Label("검수 실행", systemImage: "checkmark.seal") }
                .controlSize(.small)
                .disabled(!canRun || reviewing)
                .help(runHelp)
        }
    }

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $prompt)
                .font(.callout.monospaced()).frame(minHeight: 80, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: prompt) { _, _ in app.saveSettings() }
            HStack {
                Button("기본값 복원") { prompt = defaultPrompt; app.saveSettings() }.controlSize(.small)
                Text("마지막 줄의 '판정: 통과' / '판정: 수정 — 지시' 형식을 유지해야 자동 반영이 동작합니다")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    private func color(for v: ReviewVerdict) -> Color {
        switch v {
        case .pass: return .green
        case .revise: return .orange
        case .none: return .secondary
        }
    }
}

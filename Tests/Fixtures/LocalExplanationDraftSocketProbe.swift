import Darwin
import Foundation
import Security

enum CodeExplanation { static let noChange = "변경 없음" }

@MainActor final class AgentFixture {
    let access: AgentSessionController
    let drafts = ExplanationDraftWorkspace()
    let selector = "66666666-6666-4666-8666-666666666666"
    let original = "합성 지시 e\u{301}\n"
    var current: AgentInstructionSnapshot?
    var edits = AgentInstructionEditBuffer()
    let alternate = AgentInstructionSnapshot(selector: "continue", generation: UUID(), text: "두 번째 합성 지시")

    init(directory: String, expectedHelper: String, wait: Duration) {
        access = AgentSessionController(directory: directory, bundledHelper: {
            AgentPeerSigning.signedHash(at: URL(fileURLWithPath: expectedHelper))
        }, selectionWaiting: wait)
        current = AgentInstructionSnapshot(selector: selector, generation: UUID(), text: original)
        drafts.editDisplay("manual untouched")
    }

    func command(_ line: String) {
        func report(_ value: String) { print(value); fflush(stdout) }
        let pieces = line.split(separator: " ")
        switch pieces.first {
        case "pair": report(access.startPairing() ? "ok" : "no")
        case "disconnect": access.disconnect(); report("ok")
        case "select", "select-alternate":
            let selection = pieces.first == "select-alternate" ? alternate : current
            report(selection.map { chosen in
                access.select(chosen, current: { [weak self] value in
                    guard let self else { return nil }
                    if value == self.alternate.selector { return self.alternate }
                    return self.current?.selector == value ? self.current : nil
                }, workspace: drafts)
            } == true ? "ok" : "no")
        case "edit-buffer":
            guard let current else { report("no"); return }
            var entry = edits.entry(for: selector, expected: current.generation, label: "합성", text: current.text)
            entry.text = "저장하지 않은 합성 지시"
            edits.update(entry, for: selector)
            report("ok")
        case "save-buffer":
            guard let old = current, let entry = edits.drafts[selector], entry.expected == old.generation else {
                report("no"); return
            }
            let file = URL(fileURLWithPath: "inline-preset.json")
            guard let saved = try? AgentPresetInstructions.write(entry.text, for: "explain", expectedOverride: nil, at: file),
                  let text = saved["explain"] else { report("no"); return }
            current = AgentInstructionSnapshot(selector: selector, generation: UUID(), text: text)
            access.invalidate(selector, deleted: false)
            edits.revert(selector)
            report("ok")
        case "revert-buffer": edits.revert(selector); report("ok")
        case "revoke": access.revokeSelection(); report("ok")
        case "reject":
            access.rejectSelection(.catalogUnavailable)
            report("ok")
        case "invalidate-pending":
            access.invalidate(selector, deleted: false)
            report("ok")
        case "change", "revert", "delete":
            let verb = pieces[0]
            access.invalidate(selector, deleted: verb == "delete")
            current = verb == "delete" ? nil : AgentInstructionSnapshot(selector: selector, generation: UUID(),
                         text: verb == "revert" ? original : "합성 지시 다른 버전\n")
            report("ok")
        case "snapshot":
            let body: [String: Any] = [
                "selection": access.selectionStatus.rawValue,
                "diagnostics": access.selectionDiagnostics.map(\.rawValue),
                "previews": drafts.immediatePreviews.map(\.display), "paired": access.pair != nil, "count": drafts.pending.count, "editor": drafts.display, "shared": access.shared != nil,
                "receiving": access.receiving, "old": drafts.pending.map { $0.provenance?.older ?? false },
                "labels": drafts.pending.map { $0.provenance?.agentLabel ?? "" },
                "pairs": drafts.pending.map { ($0.provenance?.principal.uuidString ?? "") },
            ]
            report(String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        case "end": access.stopPairing(); report("ok"); exit(0)
        default: exit(2)
        }
    }
}

@main struct LocalExplanationDraftSocketProbe {
    @MainActor static func main() {
        let fixture = AgentFixture(directory: CommandLine.arguments[1],
                                   expectedHelper: CommandLine.arguments.dropFirst(2).first ?? "helper",
                                   wait: .milliseconds(Int64(CommandLine.arguments.dropFirst(3).first ?? "90000") ?? 90000))
        print("ready"); fflush(stdout)
        DispatchQueue.global().async {
            while let cmd = readLine() { DispatchQueue.main.async { fixture.command(cmd) } }
            DispatchQueue.main.async { fixture.command("end") }
        }
        dispatchMain()
    }
}

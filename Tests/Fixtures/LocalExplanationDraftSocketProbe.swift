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
    init(directory: String, expectedHelper: String) {
        access = AgentSessionController(directory: directory, bundledHelper: {
            AgentPeerSigning.signedHash(at: URL(fileURLWithPath: expectedHelper))
        })
        current = AgentInstructionSnapshot(selector: selector, generation: UUID(), text: original)
        drafts.editDisplay("manual untouched")
    }

    func command(_ line: String) {
        func report(_ value: String) { print(value); fflush(stdout) }
        let pieces = line.split(separator: " ")
        switch pieces.first {
        case "pair": report(access.startPairing() ? "ok" : "no")
        case "disconnect": access.disconnect(); report("ok")
        case "share":
            report(current.map { access.share($0) } == true ? "ok" : "no")
        case "receipt":
            report(access.receive(current: { [weak self] value in
                guard let self, self.current?.selector == value else { return nil }
                return self.current
            }, workspace: drafts) ? "ok" : "no")
        case "stopreceipt": access.stopReceipt(); report("ok")
        case "change", "revert", "delete":
            let verb = pieces[0]
            access.invalidate(selector, deleted: verb == "delete")
            current = verb == "delete" ? nil : AgentInstructionSnapshot(selector: selector, generation: UUID(),
                         text: verb == "revert" ? original : "합성 지시 다른 버전\n")
            report("ok")
        case "snapshot":
            let body: [String: Any] = [
                "paired": access.pair != nil, "count": drafts.pending.count, "editor": drafts.display, "shared": access.shared != nil,
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
                                   expectedHelper: CommandLine.arguments.dropFirst(2).first ?? "helper")
        print("ready"); fflush(stdout)
        DispatchQueue.global().async {
            while let cmd = readLine() { DispatchQueue.main.async { fixture.command(cmd) } }
            DispatchQueue.main.async { fixture.command("end") }
        }
        dispatchMain()
    }
}

import Darwin
import Foundation
import Security

enum CodeExplanation { static let noChange = "변경 없음" }

private final class ProbeCounter {
    private let lock = NSLock()
    private var count = 0
    func record() { lock.lock(); count += 1; lock.unlock() }
    func value() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}

@MainActor final class AgentFixture {
    let access: AgentSessionController
    let drafts = ExplanationDraftWorkspace()
    let selector = "66666666-6666-4666-8666-666666666666"
    let original = "합성 지시 e\u{301}\n"
    var current: AgentInstructionSnapshot?
    private let directory: String
    private let probeCount = ProbeCounter()
    private var probeSocket: LocalApprovedSocket?
    init(directory: String, expectedHelper: String) {
        self.directory = directory
        access = AgentSessionController(directory: directory, bundledHelper: {
            AgentPeerSigning.signedHash(at: URL(fileURLWithPath: directory).appendingPathComponent(expectedHelper))
        })
        current = AgentInstructionSnapshot(selector: selector, generation: UUID(), text: original)
        drafts.editDisplay("manual untouched")
    }

    func command(_ line: String) {
        func report(_ value: String) { print(value); fflush(stdout) }
        let pieces = line.split(separator: " ")
        switch pieces.first {
        case "bind":
            report(pieces.count == 2 && access.bind(pid: Int32(pieces[1]) ?? 0, name: "Owner label") ? "ok" : "no")
        case "inspect-signing-info":
            var selfCode: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
            precondition(SecCodeCopySelf([], &selfCode) == errSecSuccess)
            precondition(SecCodeCopyStaticCode(selfCode!, [], &staticCode) == errSecSuccess)
            precondition(SecCodeCopySigningInformation(staticCode!, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess)
            let values = info as! [String: Any]
            let dictionary = values[kSecCodeInfoEntitlementsDict as String] as? [String: Bool]
            let raw = values[kSecCodeInfoEntitlements as String] as? Data
            report(dictionary?["com.apple.security.network.client"] == false && raw?.isEmpty == false ? "dict+raw" : "missing")
        case "observe-request":
            guard pieces.count == 2, let pid = Int32(pieces[1]),
                  let peer = LocalInstructionPeer.current(pid: pid) else { report("no"); return }
            // Only verifies whether the production helper sends a request.
            // This isolated test listener cannot disclose any payload or return a body.
            let socket = LocalApprovedSocket(peer: peer, endpoint: "i.sock", directory: directory,
                                            lifetime: .seconds(30), maxFrame: 128) { [probeCount] _, _ in
                probeCount.record()
                return nil
            }
            guard socket.start() else { report("no"); return }
            probeSocket = socket; report("ok")
        case "stop-observing":
            probeSocket?.stop(); probeSocket = nil
            report(String(probeCount.value()))
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
                "count": drafts.pending.count, "editor": drafts.display, "shared": access.shared != nil,
                "receiving": access.receiving, "old": drafts.pending.map { $0.provenance?.older ?? false },
                "labels": drafts.pending.map { $0.provenance?.agentLabel ?? "" },
                "pairs": drafts.pending.map { ($0.provenance?.principal.uuidString ?? "") },
            ]
            report(String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        case "end": probeSocket?.stop(); access.disconnect(); exit(0)
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

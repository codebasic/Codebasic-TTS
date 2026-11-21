import Darwin
import Foundation

// Only names the sentinel for the unrelated UI playback method; the real
// AppState and CodeExplanation are exercised in the pronunciation fixture.
enum CodeExplanation { static let noChange = "변경 없음" }

@main struct LocalExplanationDraftSocketProbe {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 4,
              let pid = Int32(CommandLine.arguments[1]),
              let peer = LocalInstructionPeer.current(pid: pid),
              let lifetime = Int(CommandLine.arguments[3]) else { exit(2) }
        let workspace = ExplanationDraftWorkspace()
        workspace.editDisplay("synthetic manual text")
        let receiver = LocalExplanationDraftSocket(peer: peer, directory: CommandLine.arguments[2],
                                                   lifetime: .milliseconds(lifetime)) { workspace.receive($0) }
        guard receiver.start() else { exit(3) }
        print("ready"); fflush(stdout)
        DispatchQueue.global().async {
            while let command = readLine() {
                DispatchQueue.main.async {
                    switch command {
                    case "snapshot":
                        let values: [String: Any] = [
                            "editor": workspace.display,
                            "count": workspace.pending.count,
                            "lastDisplay": workspace.pending.last?.display ?? "",
                            "lastSpeech": workspace.pending.last?.speech ?? "",
                        ]
                        let data = try! JSONSerialization.data(withJSONObject: values)
                        print(String(decoding: data, as: UTF8.self)); fflush(stdout)
                    case "revoke":
                        receiver.stop(); print("revoked"); fflush(stdout)
                    default: exit(4)
                    }
                }
            }
            DispatchQueue.main.async { receiver.stop(); exit(0) }
        }
        dispatchMain()
    }
}

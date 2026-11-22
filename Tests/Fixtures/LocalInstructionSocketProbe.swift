import Darwin
import Foundation

@main enum LocalInstructionSocketProbe {
    static func main() {
        guard CommandLine.arguments.count == 3,
              let pid = Int32(CommandLine.arguments[1]), let peer = LocalInstructionPeer.current(pid: pid),
              let profile = LocalInstructionProfile(name: .explain, text: "합성 지시만 반환합니다. __init__, 0.84\n") else {
            fputs("Invalid probe arguments\n", stderr); exit(2)
        }
        let directory = CommandLine.arguments[2]
        let build = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
        let target = URL(fileURLWithPath: directory).resolvingSymlinksInPath()
        guard build.lastPathComponent == "build",
              target.deletingLastPathComponent().path == build.path,
              target.lastPathComponent.hasPrefix("i") else { exit(2) }
        let listener = LocalInstructionSocket(peer: peer, profile: profile, directory: directory)
        guard listener.start() else { print("socket-unavailable"); exit(3) }
        print("ready"); fflush(stdout)
        while let command = readLine(), command != "quit" {
            if command == "revoke" { listener.stop(); print("revoked"); fflush(stdout) }
        }
        listener.stop()
    }
}

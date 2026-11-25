import Darwin
import Foundation

@main struct LocalApprovedSocketLifecycleTests {
    static func transport(_ directory: String, _ endpoint: String) -> LocalApprovedSocket {
        LocalApprovedSocket(peer: LocalInstructionPeer.current(pid: getpid())!,
                            endpoint: endpoint, directory: directory, lifetime: .seconds(60),
                            maxFrame: 128) { _, _ in nil }
    }

    static func main() throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if CommandLine.arguments.count == 4 {
            let socket = transport("native", CommandLine.arguments[3])
            precondition(socket.start())
            print("ready"); fflush(stdout)
            while true { pause() } // parent terminates this synthetic fixture without cleanup
        }
        precondition(chdir(root.path) == 0) // short AF_UNIX paths, all files remain in this fixture
        for endpoint in ["i.sock", "d.sock", "p.sock"] {
            let proc = Process(), output = Pipe()
            proc.executableURL = executable
            proc.currentDirectoryURL = root
            proc.arguments = [root.path, "child", endpoint]
            proc.standardOutput = output
            try proc.run()
            let ready = try output.fileHandleForReading.read(upToCount: 6)
            precondition(ready == Data("ready\n".utf8))
            let path = "native/" + endpoint
            var live = stat(), current = stat()
            precondition(lstat(path, &live) == 0 && (live.st_mode & S_IFMT) == S_IFSOCK)
            let contender = transport("native", endpoint)
            precondition(!contender.start() && !contender.requiresPathInspection)
            precondition(lstat(path, &current) == 0 && live.st_ino == current.st_ino)
            precondition(kill(proc.processIdentifier, SIGKILL) == 0)
            proc.waitUntilExit()
            precondition(proc.terminationReason == .uncaughtSignal && lstat(path, &current) == 0)
            precondition(contender.start())
            precondition(lstat(path, &current) == 0 && current.st_mode & 0o777 == 0o600)
            contender.stop()
            precondition(lstat(path, &current) != 0 && errno == ENOENT)

            // A different inode, regular file or symlink is never recovered.
            let wrong = "native/" + endpoint + ".other"
            try Data("safe fixture".utf8).write(to: URL(fileURLWithPath: wrong))
            precondition(symlink(wrong.split(separator: "/").last.map(String.init)!, path) == 0)
            let unknown = transport("native", endpoint)
            precondition(!unknown.start() && unknown.requiresPathInspection && lstat(path, &current) == 0 &&
                         (current.st_mode & S_IFMT) == S_IFLNK)
            precondition(unlink(path) == 0 && rename(wrong, path) == 0)
            precondition(!unknown.start() && unknown.requiresPathInspection)
            let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
            precondition(bytes == Data("safe fixture".utf8) && unlink(path) == 0)

            let unmanaged = socket(AF_UNIX, SOCK_STREAM, 0)
            precondition(unmanaged >= 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            let pathBytes = Array(path.utf8CString)
            withUnsafeMutableBytes(of: &address.sun_path) { dst in pathBytes.withUnsafeBytes { dst.copyBytes(from: $0) } }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(unmanaged, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            precondition(bound == 0 && listen(unmanaged, 1) == 0 && lstat(path, &live) == 0)
            precondition(!unknown.start() && unknown.requiresPathInspection)
            precondition(lstat(path, &current) == 0 && live.st_ino == current.st_ino)
            close(unmanaged)
            precondition(!unknown.start() && unknown.requiresPathInspection) // unknown even after close
            precondition(lstat(path, &current) == 0 && live.st_ino == current.st_ino && unlink(path) == 0)
        }
        precondition(!transport("native", "not-allowed.sock").start())
        print("Approved sockets: live ownership preserved, crash recovery for all endpoints, no recovery of unknown inode/symlink/file/path")
    }
}

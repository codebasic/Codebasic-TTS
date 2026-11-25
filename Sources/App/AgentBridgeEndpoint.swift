// AgentBridgeEndpoint.swift
// Shared by the app and by the signed agent bridge helper (Integrations/AgentBridge/main.swift).
//
// Naming only. Nothing here is a security decision: a generation name is a hint that lets the
// helper find the running app without any owner-entered value. Trust always comes from the kernel
// audit token of the connected peer (AgentPeerSignature) plus the exact PID and start time.

import Darwin
import Foundation

enum AgentBridgeEndpoint {
    /// Version of the consent rendezvous (c.sock). ai.sock and ad.sock keep their v2 framing.
    static let protocolVersion = 3
    static let rendezvousName = "c.sock"
    static let maxGenerationsScanned = 8

    static func root(uid: uid_t) -> String { "/private/tmp/codebasic-tts-mcp-" + String(uid) }

    /// One running app process: PID plus kernel start time. A restarted app is a new generation
    /// with a new private directory, so endpoints left by a crash are never reused or unlinked.
    struct Generation: Equatable {
        let pid: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64

        var name: String { "g" + String(pid) + "." + String(startSeconds) + "." + String(startMicroseconds) }

        init(pid: pid_t, startSeconds: UInt64, startMicroseconds: UInt64) {
            self.pid = pid
            self.startSeconds = startSeconds
            self.startMicroseconds = startMicroseconds
        }

        /// Accepts only the exact canonical form produced by `name`.
        init?(name: String) {
            let parts = name.split(separator: ".", omittingEmptySubsequences: false)
            guard name.utf8.count <= 48, parts.count == 3, parts[0].utf8.first == 0x67,
                  let pid = Int32(parts[0].dropFirst()), pid > 1,
                  let seconds = UInt64(parts[1]), seconds > 0, let micro = UInt64(parts[2]) else { return nil }
            self.init(pid: pid, startSeconds: seconds, startMicroseconds: micro)
            guard self.name == name else { return nil }
        }

        /// Kernel view of a live process of this user. Nil when it is gone or belongs to someone else.
        static func live(pid: pid_t) -> Generation? {
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == geteuid(), info.pbi_ruid == getuid(), info.pbi_start_tvsec > 0 else { return nil }
            return Generation(pid: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec)
        }

        var isLive: Bool { Generation.live(pid: pid) == self }
    }
}

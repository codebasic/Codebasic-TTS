// AgentBridgeAdmissionTests.swift
// Offline tests for the consent rendezvous: decision state, generation naming and the private
// listener. Synthetic only: no app, no provider, no signing identity, no credentials.
//
// The listener is exercised twice: with a synthetic authenticator (kernel peer identity and UID
// only, standing in for the signature check) and with the production authenticator and an
// impossible pin, which must refuse every unsigned, ad hoc or differently signed client.

import Darwin
import Foundation

@main
struct AgentBridgeAdmissionTests {
    static var failures = 0

    static func check(_ condition: @autoclosure () -> Bool, _ label: String, line: Int = #line) {
        if !condition() {
            failures += 1
            print("FAIL line \(line): \(label)")
        }
    }

    static func id(_ pid: Int32, _ start: UInt64 = 100) -> AgentBridgeIdentity {
        AgentBridgeIdentity(pid: pid, pidVersion: 7, startSeconds: start, startMicroseconds: 5)
    }

    static func admissionState() {
        let limits = AgentBridgeAdmissionLimits.self
        let a = AgentBridgeAdmission()
        check(a.approved == nil, "nothing is approved initially")
        check(a.knock(id(10), now: 0) == .pending, "first knock is pending")
        check(a.knock(id(10), now: 1) == .pending, "repeated knocks never turn into a grant")
        check(!a.approve(id(11), now: 1), "an identity that never knocked cannot be approved")
        check(a.knock(id(11), now: 2) == .pending, "second bridge is pending")
        check(a.candidates(now: 2).count == 2 && a.approved == nil, "ambiguity is listed, not resolved")
        check(a.approve(id(10), now: 3), "owner approves one listed candidate")
        check(a.knock(id(10), now: 4) == .approved, "approved identity")
        check(a.knock(id(11), now: 4) == .pending, "the other candidate stays pending")
        check(a.knock(id(10, 101), now: 4) == .pending, "same PID, other start time: different identity")
        let reexec = AgentBridgeIdentity(pid: 10, pidVersion: 8, startSeconds: 100, startMicroseconds: 5)
        check(a.knock(reexec, now: 4) == .pending, "same PID, other PID version: different identity")
        a.deny(id(11), now: 5)
        check(a.knock(id(11), now: 6) == .denied, "declined candidate is answered denied")
        check(a.knock(id(11), now: 5 + limits.denialLifetime) == .pending, "a denial lapses to pending only")
        a.revoke()
        check(a.knock(id(10), now: 70) == .pending, "after revoke the same process needs a new decision")
        a.reset()
        check(a.approved == nil && a.candidates(now: 70).isEmpty, "reset forgets everything")

        let b = AgentBridgeAdmission()
        _ = b.knock(id(1), now: 0)
        check(!b.approve(id(1), now: limits.candidateLifetime), "an expired candidate cannot be approved")

        let c = AgentBridgeAdmission()
        for n in 0..<limits.maxCandidates { check(c.knock(id(Int32(20 + n)), now: 0) == .pending, "fill") }
        check(c.knock(id(99), now: 0) == .busy, "candidate list is bounded")
        c.prune(now: 1) { $0.pid == 20 }
        check(c.candidates(now: 1).map { $0.identity } == [id(20)], "dead processes are pruned")
    }

    static func generationNames() {
        typealias Generation = AgentBridgeEndpoint.Generation
        let g = Generation(pid: 4321, startSeconds: 1_700_000_000, startMicroseconds: 42)
        check(g.name == "g4321.1700000000.42", "canonical name")
        check(Generation(name: g.name) == g, "name round trip")
        for bad in ["", "g", "ai.sock", "c.sock", "g1.5.5", "g+7.5.5", "g07.5.5", "g7.5", "g7.5.5.5",
                    "g7.0.5", "x7.5.5", "g7.5.5 ", "g7..5", "g-7.5.5", "G7.5.5", "g7.5.5/.."] {
            check(Generation(name: bad) == nil, "rejects \(bad)")
        }
        let me = Generation.live(pid: getpid())
        check(me?.isLive == true, "own process is a live generation")
        check(!Generation(pid: getpid(), startSeconds: 1, startMicroseconds: 0).isLive, "wrong start time is not live")
    }

    static let clientScript = """
    import socket, sys
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect(sys.argv[1])
    s.sendall(sys.argv[2].encode() + b"\\n")
    s.shutdown(socket.SHUT_WR)
    data = b""
    while True:
        chunk = s.recv(4096)
        if not chunk:
            break
        data += chunk
    sys.stdout.buffer.write(data)
    """

    /// A separate same-user process: connects, sends one frame, half-closes, returns the reply.
    static func client(_ path: String, _ frame: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", clientScript, path, frame]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "spawn-failed" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Leaves a bound but dead socket file behind, like a process that crashed without cleanup.
    static func leaveStaleSocket(_ path: String) -> Bool {
        var addr = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { dst in bytes.withUnsafeBytes { dst.copyBytes(from: $0) } }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        return bound == 0
    }

    static func listener() {
        let hello = "{\"operation\":\"hello\",\"protocol\":3}"
        let pending = "{\"protocol\":3,\"status\":\"pending\"}\n"
        let root = "/private/tmp/cbtts-test-\(getpid())-\(UUID().uuidString.prefix(8))"
        guard mkdir(root, 0o700) == 0, let me = AgentBridgeEndpoint.Generation.live(pid: getpid()),
              let made = AgentBridgeRendezvous.makeGenerationDirectory(root: root, generation: me) else {
            check(false, "temporary generation directory")
            return
        }
        defer { rmdir(made.path); rmdir(root) }
        check(AgentBridgeRendezvous.makeGenerationDirectory(root: root, generation: me) == nil,
              "an existing generation directory is never reused")
        let path = made.path + "/" + AgentBridgeEndpoint.rendezvousName
        let admission = AgentBridgeAdmission()
        // Synthetic authenticator: kernel peer identity and UID only, standing in for the signature.
        let synthetic: AgentRendezvousListener.Authenticator = { fd in
            guard let peer = AgentPeerSignature.peer(ofConnectedSocket: fd), peer.effectiveUID == getuid(),
                  peer.pid != getpid(), let start = AgentBridgeEndpoint.Generation.live(pid: peer.pid) else { return nil }
            return AgentBridgeIdentity(pid: peer.pid, pidVersion: peer.pidVersion,
                                       startSeconds: start.startSeconds, startMicroseconds: start.startMicroseconds)
        }
        let open = AgentRendezvousListener(directory: made.path, authenticate: synthetic) {
            admission.knock($0, now: 0).rawValue
        }
        check(open.start(), "listener starts in a fresh generation directory")
        check(client(path, hello) == pending, "a verified hello is answered pending")
        check(admission.candidates(now: 0).count == 1 && admission.approved == nil, "a knock grants nothing")
        check(client(path, "{\"operation\":\"hello\",\"protocol\":2}").isEmpty, "other versions get no reply")
        check(client(path, "{\"operation\":\"hello\",\"pid\":1,\"protocol\":3}").isEmpty,
              "extra handshake fields are refused, never trusted")
        if let first = admission.candidates(now: 0).first {
            check(admission.approve(first.identity, now: 0), "owner approval of the listed process")
            check(client(path, hello) == pending, "approval is bound to that process; another one stays pending")
        }
        // A second listener on the same path: the existing endpoint is refused and left alone.
        let second = AgentRendezvousListener(directory: made.path, authenticate: synthetic) { _ in "approved" }
        var st = stat()
        check(!second.start(), "an existing endpoint path is refused")
        second.stop()
        check(lstat(path, &st) == 0, "a listener that never bound does not unlink the path")
        check(client(path, hello) == pending, "the first listener keeps answering")
        open.stop()
        check(lstat(path, &st) != 0, "clean shutdown removes its own socket")

        // Abrupt restart: the previous generation left a dead socket behind. It is neither reused
        // nor removed, and the new generation opens in its own directory.
        let earlier = AgentBridgeEndpoint.Generation(pid: me.pid, startSeconds: me.startSeconds - 1, startMicroseconds: 0)
        if let stale = AgentBridgeRendezvous.makeGenerationDirectory(root: root, generation: earlier) {
            let stalePath = stale.path + "/" + AgentBridgeEndpoint.rendezvousName
            check(leaveStaleSocket(stalePath), "stale socket fixture")
            let revived = AgentRendezvousListener(directory: stale.path, authenticate: synthetic) { _ in "approved" }
            check(!revived.start(), "a stale endpoint is never taken over")
            check(lstat(stalePath, &st) == 0, "and never unlinked")
            check(client(stalePath, hello).isEmpty, "nobody answers on the stale path")
            let reopened = AgentRendezvousListener(directory: made.path, authenticate: synthetic) { _ in "pending" }
            check(reopened.start(), "the current generation opens next to the stale one")
            check(client(path, hello) == pending, "and answers")
            reopened.stop()
            unlink(stalePath)
            rmdir(stale.path)
        } else {
            check(false, "stale generation directory fixture")
        }

        // Production authenticator with an impossible pin: every unsigned, ad hoc or differently
        // signed same-user client is closed without a single reply byte.
        let strict = AgentRendezvousListener(
            directory: made.path,
            authenticate: AgentRendezvousListener.signedBridge(leafSHA1: String(repeating: "0", count: 40))
        ) { _ in "approved" }
        check(strict.start(), "strict listener starts")
        check(client(path, hello).isEmpty, "a client without the pinned bridge signature gets nothing")
        strict.stop()
    }

    static func main() {
        admissionState()
        generationNames()
        listener()
        if AgentPeerSignature.ownSignerSHA1() == nil {
            // This test binary has no certificate: like an ad hoc app build it must not listen at all.
            let availability = MainActor.assumeIsolated { () -> AgentBridgeRendezvous.Availability in
                let rendezvous = AgentBridgeRendezvous()
                rendezvous.start()
                return rendezvous.availability
            }
            check(availability == .unsigned, "an unsigned or ad hoc app never opens the rendezvous")
        }
        if failures > 0 {
            print("agent bridge admission tests: \(failures) failure(s)")
            exit(1)
        }
        print("agent bridge admission tests passed")
    }
}

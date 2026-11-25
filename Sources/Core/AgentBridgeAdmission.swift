// AgentBridgeAdmission.swift
// Pure decision state for the consent rendezvous. No sockets, no UI, no persistence.
//
// A verified bridge process that knocks becomes a candidate. Only an explicit owner approval of one
// listed candidate creates the single approved identity: nothing is granted implicitly, by timeout
// or by being the only candidate. Identities are derived from the kernel, never from the wire.

import Foundation

/// Exact kernel identity of one live bridge process.
struct AgentBridgeIdentity: Hashable, Sendable {
    let pid: Int32
    let pidVersion: UInt32
    let startSeconds: UInt64
    let startMicroseconds: UInt64
}

enum AgentBridgeAdmissionLimits {
    static let maxCandidates = 4
    static let candidateLifetime: TimeInterval = 120
    static let denialLifetime: TimeInterval = 60
}

final class AgentBridgeAdmission: @unchecked Sendable {
    enum Answer: String { case pending, approved, denied, busy }

    struct Candidate: Equatable, Identifiable {
        let identity: AgentBridgeIdentity
        let firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var id: AgentBridgeIdentity { identity }
    }

    private let lock = NSLock()
    private var pending: [Candidate] = []
    private var denied: [AgentBridgeIdentity: TimeInterval] = [:]
    private var approvedIdentity: AgentBridgeIdentity?
    /// Set once before use. Called without the lock held when candidates or the approval changed.
    var onChange: (() -> Void)?

    private func expire(_ now: TimeInterval) -> Bool {
        let before = pending.count
        pending.removeAll { now - $0.lastSeen >= AgentBridgeAdmissionLimits.candidateLifetime }
        denied = denied.filter { now - $0.value < AgentBridgeAdmissionLimits.denialLifetime }
        return pending.count != before
    }

    /// A verified bridge asked for its state. Never grants anything.
    func knock(_ identity: AgentBridgeIdentity, now: TimeInterval) -> Answer {
        lock.lock()
        var changed = expire(now)
        let answer: Answer
        if approvedIdentity == identity {
            answer = .approved
        } else if denied[identity] != nil {
            answer = .denied
        } else if let index = pending.firstIndex(where: { $0.identity == identity }) {
            pending[index].lastSeen = now
            answer = .pending
        } else if pending.count < AgentBridgeAdmissionLimits.maxCandidates {
            pending.append(Candidate(identity: identity, firstSeen: now, lastSeen: now))
            changed = true
            answer = .pending
        } else {
            answer = .busy
        }
        lock.unlock()
        if changed { onChange?() }
        return answer
    }

    func candidates(now: TimeInterval) -> [Candidate] {
        lock.lock()
        defer { lock.unlock() }
        _ = expire(now)
        return pending
    }

    var approved: AgentBridgeIdentity? {
        lock.lock()
        defer { lock.unlock() }
        return approvedIdentity
    }

    /// Owner decision for one listed candidate. Replaces any earlier approval. Never persisted.
    func approve(_ identity: AgentBridgeIdentity, now: TimeInterval) -> Bool {
        lock.lock()
        _ = expire(now)
        guard let index = pending.firstIndex(where: { $0.identity == identity }) else {
            lock.unlock()
            return false
        }
        pending.remove(at: index)
        approvedIdentity = identity
        lock.unlock()
        onChange?()
        return true
    }

    /// Owner declined: the candidate is dropped and answered `denied` for a short time.
    func deny(_ identity: AgentBridgeIdentity, now: TimeInterval) {
        lock.lock()
        pending.removeAll { $0.identity == identity }
        if approvedIdentity != identity, denied.count < 64 { denied[identity] = now }
        lock.unlock()
        onChange?()
    }

    /// Ends the approval. The same process needs a new owner decision afterwards.
    func revoke() {
        lock.lock()
        approvedIdentity = nil
        lock.unlock()
        onChange?()
    }

    /// Drops candidates whose process is gone. `isLive` is a kernel lookup supplied by the caller.
    func prune(now: TimeInterval, isLive: (AgentBridgeIdentity) -> Bool) {
        lock.lock()
        var changed = expire(now)
        let before = pending.count
        pending.removeAll { !isLive($0.identity) }
        if pending.count != before { changed = true }
        lock.unlock()
        if changed { onChange?() }
    }

    /// Quit or shutdown: forget everything.
    func reset() {
        lock.lock()
        pending.removeAll()
        denied.removeAll()
        approvedIdentity = nil
        lock.unlock()
    }
}

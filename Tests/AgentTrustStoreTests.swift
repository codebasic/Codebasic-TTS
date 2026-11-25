import CryptoKit
import Foundation

/// An approved agent app stays approved across restarts and idle time until the
/// user revokes it; approvals of different apps stay independent.
@main struct AgentTrustStoreTests {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let url = directory.appendingPathComponent("agent-clients.json")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        func store() -> AgentTrustStore { AgentTrustStore(url: url, now: { clock }) }
        let hostA = AgentPairing.registeredHostPrefix + "team.ABCDE12345:com.example.agent-a"
        let hostB = AgentPairing.registeredHostPrefix + "team.ABCDE12345:com.example.agent-b"
        let keyA = P256.Signing.PrivateKey().publicKey.x963Representation
        let keyB = P256.Signing.PrivateKey().publicKey.x963Representation
        let idA = AgentPairingProof.keyID(keyA)!, idB = AgentPairingProof.keyID(keyB)!

        let first = store()
        let a = try first.trust(publicKey: keyA, label: "Agent", host: hostA)
        let b = try first.trust(publicKey: keyB, label: "Agent", host: hostB)
        precondition(a.id != b.id)

        // A year without reconnecting and an app restart keep the approval.
        clock = clock.addingTimeInterval(365 * 24 * 3600)
        let reopened = store()
        precondition(reopened.lookup(keyID: idA, host: hostA) == .trusted(reopened.clients.first { $0.id == a.id }!))
        precondition(reopened.lookup(keyID: idB, host: hostB) != .unknown)

        // The same key presented through another app is not the approved app.
        precondition(reopened.lookup(keyID: idA, host: hostB) == .hostChanged)

        // Revoking A leaves B approved, also after a restart.
        precondition(reopened.forget(a.id))
        let afterRevoke = store()
        precondition(afterRevoke.lookup(keyID: idA, host: hostA) == .revoked)
        if case .trusted = afterRevoke.lookup(keyID: idB, host: hostB) {} else { preconditionFailure("B lost approval") }
        print("agent trust store tests passed")
    }
}

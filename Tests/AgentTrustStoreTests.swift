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
        // Receipt choice (#31): a first launch may connect by itself, the user's
        // off sticks, and an older file saved as off stays off with a notice.
        let fresh = AgentTrustStore(url: directory.appendingPathComponent("fresh.json"))
        precondition(fresh.receiptChoice == .auto && !fresh.autoReceive && !fresh.legacyReceiptOff)
        precondition(fresh.setAutoReceive(true, byUser: false) && fresh.receiptChoice == .auto)
        precondition(fresh.setAutoReceive(false) && fresh.receiptChoice == .off)
        let freshAgain = AgentTrustStore(url: directory.appendingPathComponent("fresh.json"))
        precondition(freshAgain.receiptChoice == .off && !freshAgain.autoReceive && !freshAgain.legacyReceiptOff)
        precondition(freshAgain.setAutoReceive(true) && freshAgain.receiptChoice == .auto)

        let legacyURL = directory.appendingPathComponent("legacy.json")
        try AgentTrustStore.writePrivately(Data(#"{"version":1,"autoReceive":false,"clients":[],"revoked":[]}"#.utf8), legacyURL)
        let legacy = AgentTrustStore(url: legacyURL)
        precondition(legacy.receiptChoice == .off && legacy.legacyReceiptOff)
        precondition(legacy.setAutoReceive(true) && !legacy.legacyReceiptOff && legacy.receiptChoice == .auto)
        try AgentTrustStore.writePrivately(Data(#"{"version":1,"autoReceive":true,"clients":[],"revoked":[]}"#.utf8), legacyURL)
        precondition(AgentTrustStore(url: legacyURL).receiptChoice == .auto)

        // A standby instance that takes the socket over adopts what the previous
        // holder saved; an unreadable file then means no trust and receipt off.
        let sharedURL = directory.appendingPathComponent("shared.json")
        let holder = AgentTrustStore(url: sharedURL), standby = AgentTrustStore(url: sharedURL)
        let sharedKey = P256.Signing.PrivateKey().publicKey.x963Representation
        let sharedClient = try holder.trust(publicKey: sharedKey, label: "Agent", host: hostA)
        precondition(holder.setAutoReceive(true))
        precondition(holder.forget(sharedClient.id) && holder.setAutoReceive(false))
        standby.adoptDisk()
        precondition(standby.clients.isEmpty && !standby.autoReceive && standby.receiptChoice == .off)
        precondition(standby.lookup(keyID: AgentPairingProof.keyID(sharedKey)!, host: hostA) == .revoked)
        precondition(!standby.setAutoReceive(true, byUser: false) && !standby.autoReceive)
        let onBadFile = AgentTrustStore(url: directory.appendingPathComponent("fresh.json"))
        // An older app writing beside the holder is noticed; a deleted file after
        // approvals were known means no trust, with the revocation kept.
        let readd = try holder.trust(publicKey: P256.Signing.PrivateKey().publicKey.x963Representation, label: "B", host: hostB)
        precondition(!holder.changedOnDisk && standby.changedOnDisk)
        standby.adoptDisk()
        precondition(standby.clients.map(\.id) == [readd.id] && !standby.changedOnDisk)
        // An older writer saving a list from before a revocation does not bring the key back.
        let staleCopy = try Data(contentsOf: sharedURL)
        precondition(standby.forget(readd.id))
        try AgentTrustStore.writePrivately(staleCopy, sharedURL)
        precondition(standby.changedOnDisk)
        standby.adoptDisk()
        precondition(standby.clients.isEmpty && standby.lookup(keyID: readd.keyID, host: hostB) == .revoked)
        precondition(AgentTrustStore(url: sharedURL).lookup(keyID: readd.keyID, host: hostB) == .revoked)
        precondition(unlink(sharedURL.path) == 0 && standby.changedOnDisk)
        standby.adoptDisk()
        precondition(standby.clients.isEmpty && standby.receiptChoice == .off && !standby.autoReceive)
        precondition(standby.lookup(keyID: AgentPairingProof.keyID(sharedKey)!, host: hostA) == .revoked)
        precondition(chmod(directory.appendingPathComponent("fresh.json").path, 0o644) == 0)
        onBadFile.adoptDisk()
        precondition(onBadFile.clients.isEmpty && onBadFile.receiptChoice == .off && !onBadFile.autoReceive)

        // Reconnect policy shared with the helper.
        precondition(AgentReconnect.next(after: "receiving_only", attempt: 3) == .done)
        precondition(AgentReconnect.next(after: "ready", attempt: 0) == .done)
        precondition(AgentReconnect.next(after: "revoked", attempt: 0) == .stop)
        precondition(AgentReconnect.next(after: "upgrade_required", attempt: 0) == .stop)
        for status in ["locked", "disabled", "other_agent", "approval_required"] {
            precondition(AgentReconnect.next(after: status, attempt: 5) == .waitForSignal)
        }
        precondition(AgentReconnect.next(after: "app_unavailable", attempt: 0) == .retry(after: 2))
        precondition(AgentReconnect.next(after: "unavailable", attempt: 2) == .retry(after: 8))
        precondition(AgentReconnect.delay(attempt: 7) == 256 && AgentReconnect.delay(attempt: 8) == 300
                     && AgentReconnect.delay(attempt: 1000) == 300)
        precondition(abs(AgentReconnect.jittered(10, unit: 0) - 8) < 1e-9 && abs(AgentReconnect.jittered(10, unit: 1) - 12) < 1e-9)
        precondition(AgentPairing.readyNotification(appID: "com.example.app", uid: 501) == "com.example.app.agent.ready.501")
        print("agent trust store tests passed")
    }
}

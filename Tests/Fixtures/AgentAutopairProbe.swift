import Darwin
import Foundation

@main struct AgentAutopairProbe {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: app-probe <ipc-dir> <profile-dir>\n", stderr)
            exit(2)
        }
        let ipcDir = CommandLine.arguments[1]
        let profileDir = CommandLine.arguments[2]
        let catalog = AgentInstructionCatalogStore(directory: profileDir)
        let drafts = ExplanationDraftWorkspace()
        var explainPrompt = "SYNTHETIC_BUILTIN_EXPLAIN: as_frame을 설명하세요."
        let controller = AgentSessionController(
            catalog: catalog,
            drafts: drafts,
            directory: ipcDir,
            builtinTextProvider: { name in
                switch name {
                case "explain": return CodeExplanation.effectiveInstruction(explainPrompt)
                case "continue": return CodeExplanation.effectiveInstruction(explainPrompt) + "\n\n" + CodeExplanation.continueInstruction
                default: return "SYNTHETIC_NORMALIZE"
                }
            }
        )

        print("ready"); fflush(stdout)
        DispatchQueue.global().async {
            while let line = readLine() {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                DispatchQueue.main.async {
                    switch parts.first {
                    case "start_pairing":
                        respond(["ok": controller.startPairing(duration: 60)])
                    case "stop_pairing":
                        controller.stopPairing()
                        respond(["ok": true])
                    case "candidates":
                        let list = controller.pendingCandidates.map {
                            ["pid": Int($0.principal.pid), "fp": $0.principal.fingerprint, "client": $0.clientName]
                        }
                        respond(["candidates": list])
                    case "approve_pid":
                        guard parts.count == 2, let pid = Int32(parts[1]),
                              let cand = controller.pendingCandidates.first(where: { $0.principal.pid == pid }) else {
                            respond(["ok": false]); return
                        }
                        respond(["ok": controller.approveCandidate(fingerprint: cand.principal.fingerprint)])
                    case "create_local":
                        guard parts.count == 3 else { respond(["ok": false]); return }
                        switch catalog.create(label: parts[1], body: parts[2]) {
                        case .success(let entry):
                            respond(["ok": true, "id": entry.id, "revision": entry.revision, "body": entry.body])
                        case .failure(let err):
                            respond(["ok": false, "error": err.localizedDescription])
                        }
                    case "update_local":
                        guard parts.count == 4 else { respond(["ok": false]); return }
                        switch catalog.update(id: parts[1], label: parts[2], body: parts[3]) {
                        case .success(let res):
                            if res.changed { controller.revokeReadIfMutated(targetWireName: parts[1]) }
                            respond(["ok": true, "changed": res.changed, "revision": res.entry.revision])
                        case .failure(let err):
                            respond(["ok": false, "error": err.localizedDescription])
                        }
                    case "delete_local":
                        guard parts.count == 2 else { respond(["ok": false]); return }
                        switch catalog.delete(id: parts[1]) {
                        case .success:
                            controller.revokeReadIfDeleted(entryID: parts[1])
                            respond(["ok": true, "tombstoned": catalog.isTombstoned(id: parts[1])])
                        case .failure(let err):
                            respond(["ok": false, "error": err.localizedDescription])
                        }
                    case "mutate_explain":
                        guard parts.count == 2 else { respond(["ok": false]); return }
                        if !explainPrompt.utf8.elementsEqual(parts[1].utf8) {
                            explainPrompt = parts[1]
                            controller.revokeReadIfMutated(targetWireName: "explain")
                        }
                        respond(["ok": true, "readActive": controller.activeReadGrant != nil])
                    case "grant_read":
                        guard parts.count == 2, let target = InstructionTarget(wireName: parts[1]) else {
                            respond(["ok": false]); return
                        }
                        respond(["ok": controller.grantRead(target: target)])
                    case "revoke_read":
                        controller.revokeRead(reason: .manual)
                        respond(["ok": true])
                    case "grant_receipt":
                        respond(["ok": controller.grantReceipt()])
                    case "revoke_receipt":
                        controller.revokeReceipt()
                        respond(["ok": true])
                    case "snapshot":
                        respond([
                            "pairingOpen": controller.isPairingOpen,
                            "candidateCount": controller.pendingCandidates.count,
                            "pinnedPID": controller.pinnedSession.map { Int($0.principal.pid) } as Any,
                            "readActive": controller.activeReadGrant != nil,
                            "readRevokeReason": controller.lastReadRevokeReason.map { String(describing: $0) } as Any,
                            "receiptActive": controller.activeReceiptGrant != nil,
                            "proofCount": controller.proofCount,
                            "remainingGrant": controller.remainingDraftsInGrant,
                            "inboxCount": drafts.pending.count,
                            "inboxIDs": drafts.pending.map(\.id),
                            "verifiedLateFlags": drafts.pending.map { $0.provenance?.verifiedLate ?? false },
                        ])
                    case "quit":
                        controller.endSession()
                        respond(["ok": true])
                        exit(0)
                    default:
                        respond(["error": "unknown_command"])
                    }
                }
            }
            DispatchQueue.main.async { controller.endSession(); exit(0) }
        }
        dispatchMain()
    }

    static func respond(_ obj: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
    }
}

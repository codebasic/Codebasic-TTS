import Darwin
import Foundation

@main struct AgentCatalogPolicyTests {
    static var checks = 0

    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        if !condition() {
            fputs("FAILED: \(name)\n", stderr)
            exit(1)
        }
        checks += 1
    }

    static func makePrincipal(pid: Int32, cdHash: String = "0123456789abcdef0123456789abcdef01234567") -> HelperPrincipal {
        HelperPrincipal(
            uid: 501,
            pid: pid,
            startSeconds: 1000,
            startMicroseconds: 200,
            signingIdentifier: "com.seongjoo.SelectedTextTTS.agent-mcp",
            leafCertSHA1: "abcdef0123456789abcdef0123456789abcdef01",
            cdHashHex: cdHash
        )
    }

    @MainActor
    static func main() {
        var now = Date(timeIntervalSince1970: 10_000)
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-catalog-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // 1. Catalog CRUD, limits (32 profiles, 96 UTF-8 bytes / 80 chars, 8 KiB body), atomic 0600, tombstones, corrupt preservation
        let store = AgentInstructionCatalogStore(directory: tmpDir.path, clock: { now })
        check(store.entries.isEmpty && store.loadError == nil, "fresh catalog starts empty")

        // Label boundary checks: 81 chars rejected, 97 UTF-8 bytes (<= 80 chars) rejected, 96 UTF-8 bytes / 32 Korean chars accepted
        let over80Chars = String(repeating: "a", count: 81)
        check(store.create(label: over80Chars, body: "body") == .failure(.invalidLabel), "81-char label rejected")
        let over96Bytes = String(repeating: "가", count: 33) // 33 chars, 99 UTF-8 bytes
        check(store.create(label: over96Bytes, body: "body") == .failure(.invalidLabel), "99-byte Korean label rejected")
        let exact96Bytes = String(repeating: "가", count: 32) // 32 chars, 96 UTF-8 bytes
        let created = store.create(label: exact96Bytes, body: "합성 로컬 지시 본문")
        guard case .success(let firstEntry) = created else {
            preconditionFailure("Expected exact 96-byte label to succeed")
        }
        check(firstEntry.origin == "local", "entry labeled local")
        check(firstEntry.revision == AgentInstructionEntry.computeRevision(id: firstEntry.id, label: exact96Bytes, body: "합성 로컬 지시 본문"),
              "revision binds exact id, label, and body")

        // File permissions 0600
        var st = stat()
        check(lstat(store.fileURL.path, &st) == 0 && (st.st_mode & 0o777) == 0o600, "catalog file mode is 0600")

        // Body 8 KiB boundary
        let exact8KiB = String(repeating: "b", count: 8192)
        let over8KiB = String(repeating: "b", count: 8193)
        check(store.create(label: "exact8k", body: over8KiB) == .failure(.invalidBody), "8193-byte body rejected")
        check((try? store.create(label: "exact8k", body: exact8KiB).get()) != nil, "8192-byte body accepted")

        // Fill up to 32 profiles, verify 33rd fails
        for idx in 2..<32 {
            guard case .success = store.create(label: "entry-\(idx)", body: "body-\(idx)") else {
                preconditionFailure("Failed creating entry \(idx)")
            }
        }
        check(store.entries.count == 32, "32 profiles stored")
        check(store.create(label: "overflow", body: "body") == .failure(.maxProfilesReached), "33rd profile rejected")

        // Reload from disk preserves exact entries & IDs
        let reloaded = AgentInstructionCatalogStore(directory: tmpDir.path, clock: { now })
        check(reloaded.entries == store.entries && reloaded.loadError == nil, "reload preserved all 32 entries")

        // Update binds new revision; delete leaves tombstone
        let secondID = store.entries[1].id
        guard case .success(let updated) = store.update(id: secondID, label: "updated-2", body: "new body") else {
            preconditionFailure("Update failed")
        }
        check(updated.changed && updated.entry.id == secondID && updated.entry.revision != store.entries[0].revision,
              "update preserves stable ID and updates revision")
        guard case .success(let tombstone) = store.delete(id: secondID) else {
            preconditionFailure("Delete failed")
        }
        check(tombstone.id == secondID && store.isTombstoned(id: secondID) && store.entries.count == 31,
              "delete records tombstone")
        let tombstonedUpdateBlocked: Bool
        if case .failure(.tombstonedID) = store.update(id: secondID, label: "revive", body: "no") {
            tombstonedUpdateBlocked = true
        } else {
            tombstonedUpdateBlocked = false
        }
        check(tombstonedUpdateBlocked, "tombstoned ID cannot be updated")

        // Corrupt store preservation (separate dir)
        let corruptDir = tmpDir.appendingPathComponent("corrupt")
        try! FileManager.default.createDirectory(at: corruptDir, withIntermediateDirectories: true)
        let corruptURL = corruptDir.appendingPathComponent(AgentInstructionCatalogStore.fileName)
        let corruptBytes = Data("{ not valid json".utf8)
        try! corruptBytes.write(to: corruptURL)
        let corruptStore = AgentInstructionCatalogStore(directory: corruptDir.path)
        check(corruptStore.loadError != nil, "corrupt store sets loadError")
        check((try? Data(contentsOf: corruptURL)) == corruptBytes, "corrupt file untouched on load")
        if case .failure(.corruptStore) = corruptStore.create(label: "x", body: "y") { } else {
            preconditionFailure("corrupt store must refuse writes")
        }

        // 2. AgentSessionPolicy: single pinned session, harness knock, separate 10-min leases, sticky revocation
        let policy = AgentSessionPolicy(clock: { now })
        let helperA = makePrincipal(pid: 1001)
        let helperB = makePrincipal(pid: 1002, cdHash: "fedcba9876543210fedcba9876543210fedcba98")

        // Knock rejected before pairing open
        check(policy.recordPairingKnock(helperA, clientName: "Codex") == .closed, "knock closed by default")
        check(policy.startPairing(duration: 120), "pairing window opened")
        if case .queued(let candA) = policy.recordPairingKnock(helperA, clientName: "Codex") {
            check(candA.clientName == "Codex", "knock queued without granting capabilities")
        } else {
            preconditionFailure("Expected queued candidate")
        }
        check(policy.readGrant == nil && policy.receiptGrant == nil && policy.pinnedSession == nil,
              "knock alone grants nothing")

        guard case .success(let sessionA) = policy.approvePairing(candidateFingerprint: helperA.fingerprint) else {
            preconditionFailure("Approve pairing failed")
        }
        check(!policy.isPairingOpen && policy.pinnedSession?.sessionID == sessionA.sessionID,
              "approval pins single session and closes pairing")

        let explainTarget = InstructionTarget.builtin("explain")
        let payload1 = ApprovedInstructionPayload(
            target: explainTarget, label: "전체 해설", origin: "builtin",
            revision: "a".padding(toLength: 64, withPad: "a", startingAt: 0),
            instructions: "합성 지시 v1"
        )
        // Granting read without receipt leaves receipt nil; granting read does NOT mint proofs
        check((try? policy.grantRead(payload: payload1).get()) != nil, "read grant succeeds")
        check(policy.receiptGrant == nil && policy.deliveryProofs.isEmpty,
              "read grant does not enable receipt or mint proofs")

        // Wrong helper rejected on read
        check(policy.serveRead(from: helperB, targetWireName: "explain") == .unauthorizedPeer,
              "other helper rejected on read")

        // Real read mints delivery proof
        guard case .served(let servedPayload, let proof1) = policy.serveRead(from: helperA, targetWireName: "explain") else {
            preconditionFailure("Expected read serve")
        }
        check(servedPayload == payload1 && policy.deliveryProofs.count == 1, "read serve minted 1 proof")

        // Sticky edit revocation (even if reverted)
        check(policy.revokeReadForContentMutation(targetWireName: "explain"), "mutation revokes active read")
        check(policy.readGrant == nil && policy.lastReadRevokeReason == .edited, "read revoked as edited")
        check(policy.serveRead(from: helperA, targetWireName: "explain") == .readDisabled, "subsequent read blocked")

        // Delete revocation on local entry
        let localTarget = InstructionTarget.local(firstEntry.id)
        let localPayload = ApprovedInstructionPayload(
            target: localTarget, label: firstEntry.label, origin: "local",
            revision: firstEntry.revision, instructions: firstEntry.body
        )
        check((try? policy.grantRead(payload: localPayload).get()) != nil, "local read granted")
        check(policy.revokeReadForDeletion(entryID: firstEntry.id), "delete revokes local read")
        check(policy.lastReadRevokeReason == .deleted && policy.readGrant == nil, "delete reason recorded")

        // 3. Receipt grant, late-draft delivery proofs (cap 32, <= 10m), rate caps (6/min, 20/grant)
        check((try? policy.grantReceipt().get()) != nil, "receipt granted separately")
        let lateUnproven = DraftSubmissionMeta(lateDraft: true, instructionTarget: "explain", instructionRevision: payload1.revision, deliveryProof: "00000000000000000000000000000000")
        check(policy.authorizeDraft(from: helperA, meta: lateUnproven, isKnownDuplicateOrConflict: false) == .unprovenLateDraft,
              "forged late proof rejected")
        let lateWrongPrincipal = DraftSubmissionMeta(lateDraft: true, instructionTarget: "explain", instructionRevision: payload1.revision, deliveryProof: proof1)
        check(policy.authorizeDraft(from: helperB, meta: lateWrongPrincipal, isKnownDuplicateOrConflict: false) == .unauthorizedPeer,
              "other principal cannot use helperA proof")
        check(policy.authorizeDraft(from: helperA, meta: lateWrongPrincipal, isKnownDuplicateOrConflict: false) == .authorized(verifiedLate: true),
              "valid prior-delivery proof accepted for same principal after read revoked")

        // 32 proof cap
        check((try? policy.grantRead(payload: payload1).get()) != nil, "re-granted read for proof cap test")
        for _ in 0..<35 {
            _ = policy.serveRead(from: helperA, targetWireName: "explain")
        }
        check(policy.deliveryProofs.count == 32, "delivery proofs capped at 32")
        check(policy.deliveryProofs.allSatisfy { $0.token != proof1 }, "oldest proof evicted after 32")
        check(policy.authorizeDraft(from: helperA, meta: lateWrongPrincipal, isKnownDuplicateOrConflict: false) == .unprovenLateDraft,
              "evicted proof no longer authorizes late draft")

        // 6/min sliding window + 20/grant limit
        for i in 0..<6 {
            check(policy.authorizeDraft(from: helperA, meta: DraftSubmissionMeta(), isKnownDuplicateOrConflict: false) == .authorized(verifiedLate: false),
                  "draft \(i) allowed within 6/min")
            policy.recordAcceptedDraft()
        }
        check(policy.authorizeDraft(from: helperA, meta: DraftSubmissionMeta(), isKnownDuplicateOrConflict: false) == .rateLimited,
              "7th draft in same minute rate limited")
        // Duplicates bypass rate limit check cleanly
        check(policy.authorizeDraft(from: helperA, meta: DraftSubmissionMeta(), isKnownDuplicateOrConflict: true) == .authorized(verifiedLate: false),
              "duplicate retry does not fail rate limit")

        // Advance clock past 60s across batches up to 20 per grant
        for batch in 1...2 {
            now = now.addingTimeInterval(65)
            for _ in 0..<6 {
                check(policy.authorizeDraft(from: helperA, meta: DraftSubmissionMeta(), isKnownDuplicateOrConflict: false) == .authorized(verifiedLate: false),
                      "batch \(batch) draft allowed")
                policy.recordAcceptedDraft()
            }
        }
        now = now.addingTimeInterval(65)
        for _ in 0..<2 {
            check(policy.authorizeDraft(from: helperA, meta: DraftSubmissionMeta(), isKnownDuplicateOrConflict: false) == .authorized(verifiedLate: false),
                  "final grant capacity allowed up to 20")
            policy.recordAcceptedDraft()
        }
        check(policy.remainingDraftsInGrant == 0, "remaining count reached 0 at 20")
        check(policy.authorizeDraft(from: helperA, meta: DraftSubmissionMeta(), isKnownDuplicateOrConflict: false) == .grantLimitReached,
              "21st draft in same grant rejected")

        // Proofs expire with receipt / 10 minutes
        now = now.addingTimeInterval(600)
        policy.pruneExpired()
        check(policy.receiptGrant == nil && policy.deliveryProofs.isEmpty, "proofs expire with 10-min lease")

        // Pinning a new helper wipes prior session completely
        _ = policy.startPairing()
        _ = policy.recordPairingKnock(helperB, clientName: "Claude")
        _ = policy.approvePairing(candidateFingerprint: helperB.fingerprint)
        check(policy.pinnedSession?.principal == helperB && policy.readGrant == nil && policy.receiptGrant == nil && policy.deliveryProofs.isEmpty,
              "only one pinned session at a time")

        // 4. ExplanationDraftWorkspace: separate spoken hash, first-difference + sticky post-edit confirmation, no inbox overwrite
        let ws = ExplanationDraftWorkspace()
        for i in 0..<8 {
            check(ws.receive(ExplanationDraft(id: "d-\(i)", display: "display \(i)", speech: nil)!) == .accepted,
                  "inbox accepts up to 8")
        }
        check(ws.receive(ExplanationDraft(id: "d-8", display: "overflow", speech: nil)!) == .busy,
              "9th inbox draft returns busy without dropping existing 8")
        check(ws.pending.count == 8 && ws.pending.first?.id == "d-0", "existing inbox items preserved")

        let splitDraft = ExplanationDraft(id: "split-1", display: "as_frame 옵션", speech: "애즈 프레임 옵션")!
        ws.discard("d-0")
        check(ws.receive(splitDraft) == .accepted, "accepted split draft")
        check(ws.open("split-1"), "opened split draft")
        check(ws.speechNeedsReview && ws.hasDifferentSpeech && ws.playback() == nil,
              "first difference between display and speech requires confirmation before playback")
        check(ws.playback(displayOnly: true)?.speech == "as_frame 옵션", "display-only playback allowed without confirming separate speech")
        ws.confirmSpeech()
        check(!ws.speechNeedsReview && ws.playback()?.speech == "애즈 프레임 옵션", "confirmed separate speech plays")
        ws.editDisplay("as_frame 옵션을 수정함")
        check(ws.speechNeedsReview && ws.playback() == nil, "edit flags speechNeedsReview")
        ws.editDisplay("as_frame 옵션") // revert back without confirming!
        check(ws.speechNeedsReview && ws.playback() == nil, "edit-then-revert keeps confirmation requirement sticky")
        ws.confirmSpeech()
        check(ws.playback()?.speech == "애즈 프레임 옵션", "re-confirmed speech plays")

        // 5. SSMLGuard: raw + encoded rejected; normal prose/code/math preserved
        let ssmlAttacks = [
            "<speak>안녕하세요</speak>",
            "잠시 멈춤 <break time=\"500ms\"/> 계속",
            "<prosody rate=\"slow\">천천히</prosody>",
            "<phoneme alphabet=\"ipa\" ph=\"æz\">as</phoneme>",
            "<say-as interpret-as=\"digits\">1234</say-as>",
            "<sub alias=\"애즈 프레임\">as_frame</sub>",
            "<ssml:break strength=\"strong\"/>",
            "<amazon:effect name=\"whispered\">속삭임</amazon:effect>",
            "&lt;speak&gt;encoded&lt;/speak&gt;",
            "&amp;lt;break time='1s'/&amp;gt;",
            "&#60;speak&#62;numeric&#60;/speak&#62;",
            "&#x3C;prosody rate='fast'&#x3E;hex&#x3C;/prosody&#x3E;",
            "%3Cspeak%3Epercent%3C%2Fspeak%3E",
            "%253Cbreak%2520time%3D%2522500ms%2522%252F%253E",
            "\\u003cspeak\\u003eunicode\\u003c/speak\\u003e",
            "\\x3cbreak/\\x3e",
            "＜speak＞fullwidth＜/speak＞",
            "<\u{200B}speak>zwsp</speak>",
        ]
        for payload in ssmlAttacks {
            check(SSMLGuard.containsSSML(payload), "SSML detected: \(payload)")
            ws.editDisplay(payload)
            check(ws.playback(displayOnly: true) == nil && ws.lastPlaybackError != nil,
                  "workspace blocked SSML playback: \(payload)")
        }

        let safeTexts = [
            "x < 5 이고 y > 0 입니다.",
            "a < b && c > d 조건을 검사합니다.",
            "List<String> 타입을 반환하며 Map<String, Int>를 씁니다.",
            "as_frame 옵션을 켜면 0.5% 오차 미만으로 반환합니다.",
            "np.where(arr < 0.5) 와 x < break_limit 비교입니다.",
            "100% 신뢰도 & 50% 확률",
        ]
        for safe in safeTexts {
            check(!SSMLGuard.containsSSML(safe), "ordinary text preserved: \(safe)")
            ws.editDisplay(safe)
            check(ws.playback(displayOnly: true)?.speech == safe, "ordinary text playable: \(safe)")
        }

        print("AgentCatalogPolicy tests passed (\(checks) checks).")
    }
}

import Combine
import CryptoKit
import Foundation

// Compile with: Sources/Core/AgentInstructionCatalog.swift, AgentSessionAuthorization.swift,
// ExplanationDraftWorkspace.swift and the baseline ExplanationConversation.swift
// (for CodeExplanation.noChange). Fixtures are written only below the working directory.

final class TestClock {
    var now: TimeInterval = 1_000
}

final class MemoryCatalogStorage: AgentInstructionCatalogStorage {
    struct Failure: Error {}
    var data: Data?
    var failSaves = false

    func load() throws -> Data? { data }

    func save(_ data: Data) throws {
        if failSaves { throw Failure() }
        self.data = data
    }

    func quarantine() throws -> URL? {
        data = nil
        return nil
    }
}

@main
@MainActor
struct AgentCatalogCoreTests {
    static var failures = 0
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String, line: Int = #line) {
        checks += 1
        if !condition {
            failures += 1
            print("FAIL line " + String(line) + ": " + message)
        }
    }

    static func value<T, E: Error>(_ result: Result<T, E>) -> T? {
        if case .success(let v) = result { return v }
        return nil
    }

    static func failure<T, E: Error>(_ result: Result<T, E>) -> E? {
        if case .failure(let e) = result { return e }
        return nil
    }

    static func main() {
        let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/test-fixtures/AgentCatalogCoreTests-" + UUID().uuidString)
        catalogFileTests(fixtures)
        catalogCorruptStoreTests(fixtures)
        catalogMemoryTests()
        authorizationFlowTests()
        authorizationRepairTests()
        authorizationBoundsTests()
        workspaceTests()
        integrationTests()
        try? FileManager.default.removeItem(at: fixtures)
        print(String(checks) + " checks, " + String(failures) + " failures")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Catalog

    static func catalogFileTests(_ fixtures: URL) {
        let url = AgentInstructionCatalog.storeURL(inApplicationSupportDirectory: fixtures.appendingPathComponent("catalog-a"))
        let catalog = AgentInstructionCatalog(storeURL: url)
        expect(!catalog.builtInProfiles.isEmpty && catalog.builtInProfiles.count == AgentInstructionBuiltIn.standard.count, "built-ins present")
        expect(catalog.builtInProfiles.first?.id == UUID(uuidString: "6F0C2B5E-3A41-4D7B-9C1E-0A5D8E2F7B10"), "stable built-in id")
        expect(Set(catalog.builtInProfiles.map { $0.id }).count == catalog.builtInProfiles.count, "unique built-in ids")
        expect(catalog.builtInProfiles.allSatisfy { $0.canTransmit }, "built-ins shareable")
        expect(catalog.persistenceState == .clean, "clean state")

        var events: [AgentInstructionCatalogChange] = []
        let subscription = catalog.changes.sink { events.append($0) }
        defer { subscription.cancel() }

        let exact = "  Say cafe" + "\u{301}" + " plainly.  \n"
        guard let a = value(catalog.addProfile(label: "Alpha", body: exact)) else {
            expect(false, "add profile")
            return
        }
        let snap1 = value(catalog.shareSnapshot(for: a.id))
        expect(snap1?.bodyUTF8 == Data(exact.utf8), "snapshot keeps exact bytes")
        expect(snap1?.sha256 == Data(SHA256.hash(data: Data(exact.utf8))), "snapshot hash over exact bytes")
        expect(snap1?.profileID == a.id && snap1?.revision == a.revision, "snapshot identity")
        expect(snap1?.text.utf8.elementsEqual(exact.utf8) == true, "preview is exact")
        expect(snap1?.sha256Hex.count == 64, "hex digest")

        let reloaded = AgentInstructionCatalog(storeURL: url)
        expect(reloaded.profile(id: a.id)?.body.utf8.elementsEqual(exact.utf8) == true, "bytes survive reload")
        expect(reloaded.profile(id: a.id)?.revision == a.revision, "revision survives reload")
        expect(AgentInstructionRevision(wireString: a.revision.wireString) == a.revision, "revision wire round trip")

        // Edit then revert: three distinct, increasing revisions.
        guard let b = value(catalog.updateProfile(id: a.id, body: "Different body")),
              let c = value(catalog.updateProfile(id: a.id, body: exact)) else {
            expect(false, "edit and revert")
            return
        }
        expect(b.revision != a.revision && c.revision != a.revision && c.revision != b.revision, "unique revisions")
        expect(a.revision < b.revision && b.revision < c.revision, "monotonic revisions")
        let snap3 = value(catalog.shareSnapshot(for: a.id))
        expect(snap3?.sha256 == snap1?.sha256 && snap3?.revision != snap1?.revision && snap3 != snap1, "revert is a new share version")

        let renamed = value(catalog.updateProfile(id: a.id, label: "Alpha renamed"))
        expect(renamed?.revision == c.revision && renamed?.label == "Alpha renamed", "label edit keeps revision")
        let bodyEvents = events.filter { if case .bodyChanged = $0 { return true }; return false }.count
        let labelEvents = events.filter { if case .labelChanged = $0 { return true }; return false }.count
        expect(bodyEvents == 2 && labelEvents == 1, "change events")

        // Validation limits.
        expect(AgentInstructionValidator.labelError(String(repeating: "a", count: 80)) == nil, "80 chars ok")
        expect(AgentInstructionValidator.labelError(String(repeating: "a", count: 81)) == .labelTooLong, "81 chars rejected")
        expect(AgentInstructionValidator.labelError(String(repeating: "가", count: 32)) == nil, "96 bytes ok")
        expect(AgentInstructionValidator.labelError(String(repeating: "가", count: 33)) == .labelTooLong, "99 bytes rejected")
        expect(AgentInstructionValidator.labelError("   ") == .labelBlank, "blank label")
        expect(AgentInstructionValidator.labelError("a\0b") == .labelContainsNUL, "NUL label")
        expect(AgentInstructionValidator.bodyError(String(repeating: "x", count: 8192)) == nil, "8192 bytes ok")
        expect(AgentInstructionValidator.bodyError(String(repeating: "x", count: 8193)) == .bodyTooLarge, "8193 bytes rejected")
        expect(AgentInstructionValidator.bodyError(" \n") == .bodyBlank, "blank body")
        expect(AgentInstructionValidator.bodyError("a\0b") == .bodyContainsNUL, "NUL body")
        expect(failure(catalog.addProfile(label: "Too big", body: String(repeating: "x", count: 8193))) == .bodyTooLarge, "add rejects oversize")

        // Imported oversize text stays visible and exact but cannot be transmitted.
        let big = String(repeating: "가", count: 3000)
        guard let imported = value(catalog.importProfile(label: "Imported", body: big)) else {
            expect(false, "import oversize")
            return
        }
        expect(catalog.exactText(for: imported.id)?.utf8.elementsEqual(big.utf8) == true, "oversize not truncated")
        expect(failure(catalog.shareSnapshot(for: imported.id)) == .oversize, "oversize cannot transmit")
        expect(AgentInstructionCatalog(storeURL: url).exactText(for: imported.id)?.utf8.count == 9000, "oversize persisted whole")

        // Built-ins are immutable; search and delete.
        let builtIn = catalog.builtInProfiles[0]
        expect(failure(catalog.updateProfile(id: builtIn.id, body: "changed")) == .builtInImmutable, "built-in immutable")
        expect(catalog.deleteProfile(id: builtIn.id) == .builtInImmutable, "built-in not deletable")
        expect(catalog.search("alpha REN").contains { $0.id == a.id }, "search label")
        expect(catalog.search("plainly").contains { $0.id == a.id }, "search body")
        expect(catalog.search("zzzz-no-such-text").isEmpty, "search miss")
        expect(catalog.search("  ").count == catalog.profiles.count, "empty search lists all")
        catalog.selectedProfileID = a.id
        expect(catalog.deleteProfile(id: a.id) == nil, "delete")
        expect(catalog.profile(id: a.id) == nil && catalog.selectedProfileID == nil, "deleted and deselected")
        expect(failure(catalog.shareSnapshot(for: a.id)) == .notFound, "deleted has no snapshot")
        expect(events.contains(.deleted(profileID: a.id, lastRevision: c.revision)), "delete event")
    }

    static func catalogCorruptStoreTests(_ fixtures: URL) {
        let directory = fixtures.appendingPathComponent("catalog-corrupt")
        let url = AgentInstructionCatalog.storeURL(inApplicationSupportDirectory: directory)
        let garbage = Data("{ this is not a catalog".utf8)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        try? garbage.write(to: url)

        let seed = AgentLegacyPromptSeed(key: "explainPrompt", suggestedLabel: "Explain prompt", body: "Legacy narrator text")
        let catalog = AgentInstructionCatalog(storeURL: url, legacySeed: [seed])
        var unreadable = false
        if case .storeUnreadable = catalog.persistenceState { unreadable = true }
        expect(unreadable, "corrupt store detected")
        expect(!catalog.builtInProfiles.isEmpty, "built-ins still usable")
        expect(catalog.customProfiles.count == 1, "legacy seed held in memory")
        expect(failure(catalog.addProfile(label: "New", body: "New body")) == .storeUnreadable, "no save over corrupt store")
        expect((try? Data(contentsOf: url)) == garbage, "corrupt bytes untouched")

        expect(catalog.quarantineUnreadableStoreAndStartFresh() == nil, "explicit quarantine")
        expect(catalog.persistenceState == .clean, "clean after quarantine")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let kept = names.first { $0.contains(".unreadable-") }
        expect(kept != nil, "corrupt file kept aside")
        if let kept = kept {
            expect((try? Data(contentsOf: directory.appendingPathComponent(kept))) == garbage, "quarantined bytes intact")
        }
        expect(value(catalog.addProfile(label: "New", body: "New body")) != nil, "saving works again")
        let reloaded = AgentInstructionCatalog(storeURL: url, legacySeed: [seed])
        expect(reloaded.customProfiles.count == 2 && reloaded.persistenceState == .clean, "fresh store reloads without reseeding")
    }

    static func catalogMemoryTests() {
        // Failed save: last good state held, every UI draft preserved.
        let storage = MemoryCatalogStorage()
        let catalog = AgentInstructionCatalog(storage: storage)
        guard let kept = value(catalog.addProfile(label: "Keep", body: "Original body")) else {
            expect(false, "memory add")
            return
        }
        let otherKey = UUID()
        catalog.setEditorDraft(AgentInstructionEditorDraft(label: "Other", body: "Other draft body"), for: otherKey)
        catalog.setEditorDraft(AgentInstructionEditorDraft(label: "Keep", body: "Edited body"), for: kept.id)
        let savedBefore = storage.data
        storage.failSaves = true
        var saveFailed = false
        if case .failure(.saveFailed) = catalog.commitEditorDraft(for: kept.id) { saveFailed = true }
        expect(saveFailed, "failed save reported")
        expect(catalog.profile(id: kept.id)?.body == "Original body", "last good body held")
        expect(catalog.profile(id: kept.id)?.revision == kept.revision, "last good revision held")
        expect(catalog.editorDrafts.count == 2, "drafts preserved on failure")
        expect(storage.data == savedBefore, "store untouched on failure")
        var stateFailed = false
        if case .saveFailed = catalog.persistenceState { stateFailed = true }
        expect(stateFailed, "save failure is observable")
        storage.failSaves = false
        let committed = value(catalog.commitEditorDraft(for: kept.id))
        expect(committed?.body == "Edited body" && committed?.revision != kept.revision, "commit after recovery")
        expect(catalog.editorDrafts.count == 1 && catalog.editorDrafts[otherKey]?.body == "Other draft body", "other draft intact")
        expect(value(catalog.commitEditorDraft(for: otherKey))?.label == "Other", "new profile from draft")
        expect(catalog.editorDrafts.isEmpty && catalog.persistenceState == .clean, "drafts cleared after success")

        // Capacity: 32 custom profiles.
        let full = AgentInstructionCatalog(storage: MemoryCatalogStorage())
        var added = 0
        for i in 0..<32 where value(full.addProfile(label: "P" + String(i), body: "Body " + String(i))) != nil { added += 1 }
        expect(added == 32 && !full.canAddCustomProfile, "32 custom profiles")
        expect(failure(full.addProfile(label: "Extra", body: "Extra")) == .catalogFull, "33rd rejected")
        expect(failure(full.importProfile(label: "Extra", body: "Extra")) == .catalogFull, "33rd import rejected")

        // Legacy seed: exact, recorded, applied once.
        let seedStorage = MemoryCatalogStorage()
        let legacyBody = "  You are my narrator.\r\n\tKeep tabs.  "
        let oversize = String(repeating: "L", count: 9000)
        let seeds = [
            AgentLegacyPromptSeed(key: "explainPrompt", suggestedLabel: "Explain prompt", body: legacyBody),
            AgentLegacyPromptSeed(key: "bigPrompt", suggestedLabel: "", body: oversize),
            AgentLegacyPromptSeed(key: "blankPrompt", suggestedLabel: "Blank", body: "  ")
        ]
        let seeded = AgentInstructionCatalog(storage: seedStorage, legacySeed: seeds)
        expect(seeded.customProfiles.count == 2, "two seeds adopted")
        if seeded.customProfiles.count == 2 {
            let first = seeded.customProfiles[0]
            let second = seeded.customProfiles[1]
            expect(first.body.utf8.elementsEqual(legacyBody.utf8) && first.kind == .legacySeed && first.label == "Explain prompt", "exact legacy prompt")
            expect(second.label == "Legacy prompt 2" && second.body.utf8.count == 9000, "oversize legacy visible")
            expect(failure(seeded.shareSnapshot(for: second.id)) == .oversize, "oversize legacy cannot transmit")
            expect(seeded.legacySeedRecord.count == 3, "seed record complete")
            if seeded.legacySeedRecord.count == 3 {
                expect(seeded.legacySeedRecord[0].bodyUTF8 == Data(legacyBody.utf8), "seed record exact")
                expect(seeded.legacySeedRecord[0].adoptedProfileID == first.id, "seed record links profile")
                expect(seeded.legacySeedRecord[2].adoptedProfileID == nil, "blank seed not adopted")
            }
            expect(seeded.deleteProfile(id: first.id) == nil, "delete seeded")
            let again = AgentInstructionCatalog(storage: seedStorage, legacySeed: seeds)
            expect(again.customProfiles.count == 1 && again.legacySeedApplied, "seed applied only once")
        }

        // A built-in update under the same stable ID is distinguishable.
        let presetID = UUID()
        let v1 = AgentInstructionBuiltIn(id: presetID, label: "Preset", body: "Preset body one", sequence: 1)
        let v2 = AgentInstructionBuiltIn(id: presetID, label: "Preset", body: "Preset body two", sequence: 1)
        expect(v1.revision != v2.revision, "built-in update changes revision")
        expect(v1.revision == AgentInstructionBuiltIn(id: presetID, label: "Preset", body: "Preset body one", sequence: 1).revision, "built-in revision stable")
        let s1 = value(AgentInstructionCatalog(storage: MemoryCatalogStorage(), builtIns: [v1]).shareSnapshot(for: presetID))
        let s2 = value(AgentInstructionCatalog(storage: MemoryCatalogStorage(), builtIns: [v2]).shareSnapshot(for: presetID))
        expect(s1 != nil && s2 != nil && s1?.sha256 != s2?.sha256 && s1?.revision != s2?.revision, "built-in update changes hash")

        // Duplicate creates an independent custom profile.
        let dupCatalog = AgentInstructionCatalog(storage: MemoryCatalogStorage(), builtIns: [v1])
        let copy = value(dupCatalog.duplicateProfile(id: presetID))
        expect(copy?.id != presetID && copy?.kind == .custom && copy?.body == "Preset body one" && copy?.label == "Preset copy", "duplicate built-in")
    }

    // MARK: Authorization helpers

    static func snapshot(_ profile: UUID, _ sequence: UInt64, _ body: String) -> AgentInstructionShareSnapshot {
        AgentInstructionShareSnapshot(profileID: profile, revision: AgentInstructionRevision(sequence: sequence, nonce: UUID()), body: body)!
    }

    static func submission(_ helper: UUID, _ snap: AgentInstructionShareSnapshot, key: String, display: String, speech: String? = nil) -> AgentDraftSubmission {
        AgentDraftSubmission(instanceID: helper, profileID: snap.profileID, revision: snap.revision,
                             instructionSHA256: snap.sha256, idempotencyKey: key, display: display, speech: speech)
    }

    static func deliver(_ session: AgentSessionAuthorization, _ snap: AgentInstructionShareSnapshot, to helper: UUID) -> AgentDeliveryRecordResult? {
        guard let grant = value(session.grantShare(snap, to: helper)),
              let ticket = value(session.beginShareRead(shareID: grant.shareID, instanceID: helper)) else { return nil }
        return session.completeShareRead(ticket)
    }

    static func isAccepted(_ outcome: AgentSubmissionOutcome) -> Bool {
        if case .accepted = outcome { return true }
        return false
    }

    static func isRecorded(_ result: AgentDeliveryRecordResult?) -> Bool {
        if let result = result, case .proofRecorded = result { return true }
        return false
    }

    // MARK: Authorization

    static func authorizationFlowTests() {
        let clock = TestClock()
        let s = AgentSessionAuthorization(clock: { clock.now })
        let helper = UUID()
        let other = UUID()
        let profA = UUID()
        let profB = UUID()
        let a1 = snapshot(profA, 1, "Instruction A v1")

        expect(failure(s.grantShare(a1, to: helper)) == .notPaired, "no share without pairing")
        expect(failure(s.grantReceipt(to: helper)) == .notPaired, "no receipt without pairing")
        expect(failure(s.pair(instanceID: helper, ownerLabel: "  ")) == .invalidOwnerLabel, "blank owner label")
        expect(value(s.pair(instanceID: helper, ownerLabel: "Desk helper"))?.ownerLabel == "Desk helper", "paired")

        // Nothing is granted by pairing or selection alone.
        expect(failure(s.beginShareRead(shareID: UUID(), instanceID: helper)) == .noShareGrant, "selection grants nothing")
        expect(failure(s.grantShare(a1, to: other)) == .wrongPrincipal, "share to unpaired instance")
        expect(failure(s.grantShare(a1, to: helper, lifetime: 0)) == .invalidLifetime, "zero lifetime")
        guard let g = value(s.grantShare(a1, to: helper, lifetime: 10_000)) else {
            expect(false, "grant share")
            return
        }
        expect(g.expiresAt - g.grantedAt == 600, "share lifetime capped")
        expect(failure(s.beginShareRead(shareID: g.shareID, instanceID: other)) == .wrongPrincipal, "wrong principal read")
        guard let ticket = value(s.beginShareRead(shareID: g.shareID, instanceID: helper)) else {
            expect(false, "begin read")
            return
        }
        expect(ticket.bytes == a1.bodyUTF8, "ticket carries exact bytes")

        var enqueued = 0
        let accept: (AgentDraftProvenance) -> Bool = { _ in
            enqueued += 1
            return true
        }
        let sub1 = submission(helper, a1, key: "k1", display: "as_frame", speech: "애즈 프레임")
        expect(s.submit(sub1, enqueue: accept) == .denied(.noReceiptGrant), "no receipt grant yet")
        let receiptInfo = value(s.grantReceipt(to: helper, lifetime: 10_000))
        expect(receiptInfo != nil && receiptInfo!.expiresAt - receiptInfo!.grantedAt == 600, "receipt lifetime capped")
        expect(s.submit(sub1, enqueue: accept) == .denied(.noDeliveryProof), "no proof before full write")
        expect(enqueued == 0, "denied drafts are never enqueued")

        expect(isRecorded(s.completeShareRead(ticket)), "proof recorded after full write")
        expect(s.completeShareRead(ticket) == .rejected(.staleTicket), "ticket is single use")
        expect(s.hasProof(instanceID: helper, profileID: profA, revision: a1.revision, sha256: a1.sha256), "proof visible")

        let first = s.submit(sub1, enqueue: accept)
        expect(isAccepted(first), "accepted with proof and receipt")
        if case .accepted(let provenance) = first {
            expect(provenance.helperInstanceID == helper && provenance.helperLabel == "Desk helper", "provenance principal")
            expect(provenance.profileID == profA && provenance.revision == a1.revision && provenance.instructionSHA256 == a1.sha256, "provenance instruction")
        }

        // Dedupe by content regardless of key; same key with altered data conflicts.
        expect(s.submit(submission(helper, a1, key: "k2", display: "as_frame", speech: "애즈 프레임"), enqueue: accept) == .duplicate, "same data other key")
        expect(s.submit(sub1, enqueue: accept) == .duplicate, "same data same key")
        expect(s.submit(submission(helper, a1, key: "k1", display: "as_frame changed", speech: "애즈 프레임"), enqueue: accept) == .conflict, "same key altered data")
        expect(s.submit(submission(helper, a1, key: "k1", display: "as_frame", speech: nil), enqueue: accept) == .conflict, "missing speech is different data")
        expect(enqueued == 1, "duplicates and conflicts not enqueued")

        // Wrong principal, revision or hash: no fallback.
        expect(s.submit(submission(other, a1, key: "w1", display: "x"), enqueue: accept) == .denied(.wrongPrincipal), "wrong principal")
        expect(s.submit(submission(helper, snapshot(profA, 1, "Instruction A v1"), key: "w2", display: "x"), enqueue: accept) == .denied(.noDeliveryProof), "wrong revision")
        let wrongHash = AgentDraftSubmission(instanceID: helper, profileID: profA, revision: a1.revision,
                                             instructionSHA256: Data(SHA256.hash(data: Data("other".utf8))),
                                             idempotencyKey: "w3", display: "x", speech: nil)
        expect(s.submit(wrongHash, enqueue: accept) == .denied(.noDeliveryProof), "wrong hash")
        expect(s.submit(submission(helper, a1, key: "", display: "x"), enqueue: accept) == .denied(.invalidIdempotencyKey), "empty key")
        expect(s.submit(submission(helper, a1, key: "w4", display: String(repeating: "x", count: 8193)), enqueue: accept) == .denied(.invalidContent), "oversize field")

        // A queue refusal is not success and consumes nothing.
        let sub3 = submission(helper, a1, key: "k3", display: "third")
        expect(s.submit(sub3, enqueue: { _ in false }) == .refusedByQueue, "queue refusal")
        expect(s.status().receipt?.acceptedCount == 1, "refusal consumes no quota")
        expect(isAccepted(s.submit(sub3, enqueue: accept)), "refused draft can be retried")
        expect(s.status().receipt?.acceptedCount == 2, "quota counts accepted only")

        // Instruction edit revokes reads only; a late draft for the proven version is fine.
        expect(s.instructionBodyChanged(profileID: profA), "edit revokes share")
        expect(failure(s.beginShareRead(shareID: g.shareID, instanceID: helper)) == .noShareGrant, "old share unreadable")
        expect(isAccepted(s.submit(submission(helper, a1, key: "k4", display: "late draft"), enqueue: accept)), "late draft with proof")

        // Revert produces a new revision with the same bytes: nothing is re-enabled.
        let a3 = snapshot(profA, 3, "Instruction A v1")
        expect(a3.sha256 == a1.sha256 && a3.revision != a1.revision, "revert identity")
        expect(failure(s.beginShareRead(shareID: g.shareID, instanceID: helper)) == .noShareGrant, "revert does not revive share")
        expect(s.submit(submission(helper, a3, key: "k-rev", display: "for reverted"), enqueue: accept) == .denied(.noDeliveryProof), "reverted revision unproven")

        // A then B: one share only.
        let b1 = snapshot(profB, 1, "Instruction B")
        guard let ga = value(s.grantShare(a3, to: helper)), let gb = value(s.grantShare(b1, to: helper)) else {
            expect(false, "grant A then B")
            return
        }
        expect(failure(s.beginShareRead(shareID: ga.shareID, instanceID: helper)) == .noShareGrant, "A share replaced by B")
        expect(s.submit(submission(helper, b1, key: "kb0", display: "for b"), enqueue: accept) == .denied(.noDeliveryProof), "B unproven until delivered")

        // Race: revoked after authorization but before the write completed.
        guard let tb = value(s.beginShareRead(shareID: gb.shareID, instanceID: helper)) else {
            expect(false, "begin read B")
            return
        }
        s.revokeShare()
        var afterEnd = false
        if case .proofRecordedAfterShareEnded = s.completeShareRead(tb) { afterEnd = true }
        expect(afterEnd, "race result exposed")
        expect(failure(s.beginShareRead(shareID: gb.shareID, instanceID: helper)) == .noShareGrant, "revoked share stays unreadable")
        expect(isAccepted(s.submit(submission(helper, b1, key: "k5", display: "for b"), enqueue: accept)), "delivered B accepted")

        // Deletion tombstones the profile for new receipts.
        s.profileDeleted(profileID: profA)
        expect(s.submit(submission(helper, a1, key: "k6", display: "after delete"), enqueue: accept) == .denied(.profileDeleted), "deleted profile refused")
        expect(failure(s.grantShare(a3, to: helper)) == .profileDeleted, "deleted profile cannot be shared")
        expect(enqueued == 4, "earlier accepted drafts untouched")

        // Receipt revoke is independent of the share and clears proofs.
        guard let gb2 = value(s.grantShare(b1, to: helper)) else {
            expect(false, "regrant B")
            return
        }
        s.revokeReceipt()
        let tb2 = value(s.beginShareRead(shareID: gb2.shareID, instanceID: helper))
        expect(tb2 != nil, "share survives receipt revoke")
        expect(s.submit(submission(helper, b1, key: "k7", display: "after revoke"), enqueue: accept) == .denied(.noReceiptGrant), "revoked receipt")
        expect(value(s.grantReceipt(to: helper)) != nil, "new receipt grant")
        expect(s.submit(submission(helper, b1, key: "k7", display: "after revoke"), enqueue: accept) == .denied(.noDeliveryProof), "proofs cleared by receipt revoke")
        if let tb2 = tb2 { expect(isRecorded(s.completeShareRead(tb2)), "fresh proof") }
        expect(isAccepted(s.submit(submission(helper, b1, key: "k7", display: "after revoke"), enqueue: accept)), "accepted with fresh proof")

        // A read in flight across a receipt revocation cannot restore proof; a new read can.
        let midRevoke = value(s.beginShareRead(shareID: gb2.shareID, instanceID: helper))
        expect(midRevoke != nil, "read begins before receipt revoke")
        s.revokeReceipt()
        expect(value(s.grantReceipt(to: helper)) != nil, "receipt regranted during in-flight read")
        if let midRevoke = midRevoke {
            expect(s.completeShareRead(midRevoke) == .rejected(.staleTicket), "in-flight read rejected after receipt ended")
        }
        expect(s.status().proofCount == 0, "no proof restored across receipt termination")
        if let afterRegrant = value(s.beginShareRead(shareID: gb2.shareID, instanceID: helper)) {
            expect(isRecorded(s.completeShareRead(afterRegrant)), "new read records proof")
        } else {
            expect(false, "new read after regrant")
        }
        expect(s.status().proofCount == 1, "only the new read holds proof")

        // Expiry.
        clock.now += 600
        expect(s.submit(submission(helper, b1, key: "k8", display: "after expiry"), enqueue: accept) == .denied(.noReceiptGrant), "receipt expired")
        let status = s.status()
        expect(status.share == nil && status.receipt == nil && status.proofCount == 0 && status.principal != nil, "grants and proofs expired")
        expect(failure(s.beginShareRead(shareID: gb2.shareID, instanceID: helper)) == .noShareGrant, "share expired")
    }

    static func authorizationRepairTests() {
        let clock = TestClock()
        let s = AgentSessionAuthorization(clock: { clock.now })
        let helper = UUID()
        let a = snapshot(UUID(), 1, "Instruction A")
        _ = s.pair(instanceID: helper, ownerLabel: "Desk helper")
        _ = s.grantReceipt(to: helper)
        expect(isRecorded(deliver(s, a, to: helper)), "delivered")
        guard let grant = s.status().share, let pending = value(s.beginShareRead(shareID: grant.shareID, instanceID: helper)) else {
            expect(false, "pending read")
            return
        }
        s.unpair()
        let cleared = s.status()
        expect(cleared.principal == nil && cleared.share == nil && cleared.receipt == nil && cleared.proofCount == 0, "unpair clears everything")
        var rejected = false
        if case .rejected = s.completeShareRead(pending) { rejected = true }
        expect(rejected, "write finishing after unpair records nothing")
        expect(s.submit(submission(helper, a, key: "r1", display: "x"), enqueue: { _ in true }) == .denied(.notPaired), "unpaired")

        _ = s.pair(instanceID: helper, ownerLabel: "Desk helper")
        expect(s.submit(submission(helper, a, key: "r1", display: "x"), enqueue: { _ in true }) == .denied(.noReceiptGrant), "re-pair restores no receipt")
        expect(failure(s.beginShareRead(shareID: grant.shareID, instanceID: helper)) == .noShareGrant, "re-pair restores no share")
        _ = s.grantReceipt(to: helper)
        expect(s.submit(submission(helper, a, key: "r1", display: "x"), enqueue: { _ in true }) == .denied(.noDeliveryProof), "re-pair restores no proof")

        // Pairing another helper wipes the previous one.
        let second = UUID()
        expect(isRecorded(deliver(s, a, to: helper)), "delivered again")
        _ = s.pair(instanceID: second, ownerLabel: "Laptop helper")
        expect(s.status().proofCount == 0 && s.status().principal?.instanceID == second, "only one paired instance")
        expect(s.submit(submission(helper, a, key: "r2", display: "y"), enqueue: { _ in true }) == .denied(.wrongPrincipal), "old helper refused")
    }

    static func authorizationBoundsTests() {
        // Rate (6 per minute) and per-grant quota (20).
        let clock = TestClock()
        let s = AgentSessionAuthorization(clock: { clock.now })
        let helper = UUID()
        let a = snapshot(UUID(), 1, "Instruction A")
        _ = s.pair(instanceID: helper, ownerLabel: "Desk helper")
        _ = s.grantReceipt(to: helper)
        expect(isRecorded(deliver(s, a, to: helper)), "delivered for bounds")
        var accepted = 0
        for _ in 0..<6 {
            if isAccepted(s.submit(submission(helper, a, key: "q" + String(accepted), display: "line " + String(accepted)), enqueue: { _ in true })) { accepted += 1 }
        }
        expect(accepted == 6, "six per minute")
        expect(s.submit(submission(helper, a, key: "q-over", display: "over rate"), enqueue: { _ in true }) == .denied(.rateLimited), "seventh rate limited")
        for _ in 0..<3 {
            clock.now += 61
            for _ in 0..<6 where accepted < 20 {
                if isAccepted(s.submit(submission(helper, a, key: "q" + String(accepted), display: "line " + String(accepted)), enqueue: { _ in true })) { accepted += 1 }
            }
        }
        expect(accepted == 20, "twenty per receipt grant")
        clock.now += 61
        expect(s.submit(submission(helper, a, key: "q-quota", display: "over quota"), enqueue: { _ in true }) == .denied(.grantQuotaExhausted), "quota exhausted")
        expect(s.submit(submission(helper, a, key: "q-again", display: "line 19"), enqueue: { _ in true }) == .duplicate, "duplicate reported after quota")
        _ = s.grantReceipt(to: helper)
        expect(isRecorded(deliver(s, a, to: helper)), "redelivered for new grant")
        expect(isAccepted(s.submit(submission(helper, a, key: "q-quota", display: "over quota"), enqueue: { _ in true })), "new grant has fresh quota")

        // At most 32 proofs, each expiring within 600 seconds.
        let proofClock = TestClock()
        let p = AgentSessionAuthorization(clock: { proofClock.now })
        let profile = UUID()
        _ = p.pair(instanceID: helper, ownerLabel: "Desk helper")
        var snaps: [AgentInstructionShareSnapshot] = []
        for i in 0..<33 {
            let snap = snapshot(profile, UInt64(i + 1), "body " + String(i))
            snaps.append(snap)
            expect(isRecorded(deliver(p, snap, to: helper)), "proof " + String(i))
        }
        expect(p.status().proofCount == 32, "proof cap")
        expect(!p.hasProof(instanceID: helper, profileID: profile, revision: snaps[0].revision, sha256: snaps[0].sha256), "oldest proof evicted")
        expect(p.hasProof(instanceID: helper, profileID: profile, revision: snaps[32].revision, sha256: snaps[32].sha256), "newest proof kept")
        proofClock.now += 600
        expect(p.status().proofCount == 0, "proofs expire")

        // Dedupe window of 128 recent accepted submissions.
        let dedupeClock = TestClock()
        let d = AgentSessionAuthorization(clock: { dedupeClock.now })
        _ = d.pair(instanceID: helper, ownerLabel: "Desk helper")
        var total = 0
        for _ in 0..<22 {
            _ = d.grantReceipt(to: helper)
            _ = deliver(d, a, to: helper)
            for _ in 0..<6 {
                if isAccepted(d.submit(submission(helper, a, key: "d" + String(total), display: "dedupe " + String(total)), enqueue: { _ in true })) { total += 1 }
            }
            dedupeClock.now += 61
        }
        expect(total == 132, "132 accepted across grants")
        _ = d.grantReceipt(to: helper)
        _ = deliver(d, a, to: helper)
        expect(d.submit(submission(helper, a, key: "d-new", display: "dedupe 131"), enqueue: { _ in true }) == .duplicate, "recent entry still deduped")
        expect(isAccepted(d.submit(submission(helper, a, key: "d0", display: "dedupe 0"), enqueue: { _ in true })), "entry beyond 128 forgotten")
    }

    // MARK: Workspace

    static func provenance() -> AgentDraftProvenance {
        AgentDraftProvenance(helperInstanceID: UUID(), helperLabel: "Desk helper", profileID: UUID(),
                             revision: AgentInstructionRevision(sequence: 7, nonce: UUID()),
                             instructionSHA256: Data(SHA256.hash(data: Data("instruction".utf8))), receiptGrantID: UUID())
    }

    static func workspaceTests() {
        let ws = ExplanationDraftWorkspace()
        let prov = provenance()
        guard let first = ExplanationDraft(id: "draft-1", display: "as_frame", speech: "애즈 프레임", provenance: prov),
              let second = ExplanationDraft(id: "draft-2", display: "second", speech: nil, provenance: prov) else {
            expect(false, "build drafts")
            return
        }

        // Receiving never plays, focuses or overwrites the editor.
        expect(ws.enqueueAgentDraft(first), "queued")
        expect(ws.display.isEmpty && ws.speech.isEmpty && ws.origin == nil && ws.pending.count == 1, "editor untouched by receipt")
        expect(ws.playback() == nil, "nothing to play from the queue")
        ws.editDisplay("my own notes")
        expect(ws.enqueueAgentDraft(second), "queued while editing")
        expect(ws.display == "my own notes" && ws.hasManualEdits && ws.origin == .manual && ws.editorProvenance == nil, "manual text not overwritten")
        expect(!ws.open("draft-1"), "open refuses to overwrite")
        expect(ws.display == "my own notes" && ws.pending.count == 2, "still not overwritten")

        // Separate incoming speech starts blocked.
        expect(ws.open("draft-1", replace: true), "explicit replace")
        expect(ws.display == "as_frame" && ws.speech == "애즈 프레임" && ws.origin == .received, "opened")
        expect(ws.editorProvenance == prov, "provenance frozen on opened draft")
        expect(ws.speechNeedsReview && ws.playback() == nil && ws.playbackBlock() == .speechNeedsReview, "speech blocked until confirmed")
        expect(ws.playback(displayOnly: true)?.speech == "as_frame", "explicit display fallback")
        ws.confirmSpeech()
        expect(ws.confirmedDisplaySHA256 == Data(SHA256.hash(data: Data("as_frame".utf8))), "display hash paired at confirmation")
        expect(ws.playback()?.speech == "애즈 프레임" && ws.playback()?.display == "as_frame", "confirmed speech plays")

        // Edits void the confirmation even when edited back.
        ws.editSpeech("애즈 프레임!")
        ws.editSpeech("애즈 프레임")
        expect(ws.speechNeedsReview && ws.playback() == nil, "speech edit and revert needs review")
        ws.confirmSpeech()
        expect(ws.playback()?.speech == "애즈 프레임", "reconfirmed")
        ws.editDisplay("as_frame2")
        ws.editDisplay("as_frame")
        expect(ws.speechNeedsReview && ws.playback() == nil && ws.confirmedDisplaySHA256 == nil, "display edit and revert needs review")
        ws.confirmSpeech()
        expect(ws.playback()?.speech == "애즈 프레임", "reconfirmed after display edit")

        // Raw and encoded markup fails closed for speech and for display fallback.
        let blocked = ["<speak>hi</speak>", "&lt;speak&gt;hi", "&amp;lt;speak&amp;gt;", "&#60;speak&#62;",
                       "&#x3C;speak&#x3E;", "say &LT;break/&GT; now", "a</b", "%3Cspeak%3E", "<!-- note -->",
                       "%253Cspeak%253E", "%25253cspeak", "%26lt;speak", "%2526lt;speak", "%5Cu003cspeak",
                       "\\\\u003Cspeak", "\\u005cu003cspeak", "\\u0026lt;speak", "\\x26lt;speak", "\\u0025253Cspeak"]
        for bad in blocked {
            expect(SpeechMarkupGuard.containsMarkup(bad), "markup detected: " + bad)
            ws.clearEditor()
            ws.editDisplay("as_frame")
            ws.editSpeech(bad)
            ws.confirmSpeech()
            expect(ws.playback() == nil && ws.playbackBlock() == .markup, "speech markup blocked: " + bad)
            expect(ws.speech == bad, "markup text not transformed: " + bad)
            ws.clearEditor()
            ws.editDisplay(bad)
            expect(ws.playback(displayOnly: true) == nil && ws.playback() == nil, "display markup blocked: " + bad)
        }

        // Legitimate punctuation is spoken unchanged.
        let allowed = ["a < b && c > d", "R&D and Q&A, 50% < 60%", "if x > 3: print(x)", "Tom & Jerry", "3 < 5", "애즈 프레임: 값 < 10", "\\frac{1}{2} < 1, 25%25"]
        for good in allowed {
            expect(!SpeechMarkupGuard.containsMarkup(good), "punctuation allowed: " + good)
            ws.clearEditor()
            ws.editDisplay("as_frame")
            ws.editSpeech(good)
            ws.confirmSpeech()
            expect(ws.playback()?.speech == good, "speech punctuation plays: " + good)
            ws.clearEditor()
            ws.editDisplay(good)
            expect(ws.playback()?.speech == good && ws.playback(displayOnly: true)?.speech == good, "display punctuation plays: " + good)
        }

        // Markup that is only displayed does not block a clean confirmed script.
        ws.clearEditor()
        ws.editDisplay("<div>as_frame</div>")
        ws.editSpeech("디브 태그 안의 애즈 프레임")
        ws.confirmSpeech()
        expect(ws.playback()?.speech == "디브 태그 안의 애즈 프레임", "clean speech for code display")
        expect(ws.playback(displayOnly: true) == nil, "display fallback with markup blocked")

        // Byte-exact comparison, not Unicode canonical equality.
        let precomposed = "caf\u{E9}"
        let decomposed = "cafe\u{301}"
        expect(precomposed == decomposed, "canonically equal in Swift")
        ws.clearEditor()
        if let nfc = ExplanationDraft(id: "nfc", display: precomposed, speech: decomposed, provenance: prov) {
            expect(ws.enqueueAgentDraft(nfc) && ws.open("nfc"), "open byte-different draft")
            expect(ws.speechNeedsReview && ws.playback() == nil, "byte-different speech needs review")
        } else {
            expect(false, "build nfc draft")
        }

        // Paste and manual state are retained.
        ws.clearEditor()
        expect(ws.editorProvenance == nil && !ws.hasEditorContent, "cleared")
        ws.editDisplay("pasted text", pasted: true)
        expect(ws.origin == .pasted && !ws.hasManualEdits && ws.playback()?.speech == "pasted text", "paste plays display")
        ws.editSpeech("typed script")
        expect(ws.hasManualEdits && ws.playback() == nil, "typed separate script needs confirmation")
        ws.editSpeech("")
        expect(!ws.speechNeedsReview && ws.playback()?.speech == "pasted text", "blank script falls back to display")

        ws.clearEditor()
        ws.editDisplay(CodeExplanation.noChange)
        expect(ws.playback() == nil && ws.playback(displayOnly: true) == nil, "no-change literal is never spoken")

        // Inbox cap, provenance requirement, field limits, idempotent receive.
        let inbox = ExplanationDraftWorkspace()
        var queued = 0
        for i in 0..<8 {
            if let draft = ExplanationDraft(id: "cap-" + String(i), display: "text " + String(i), speech: nil, provenance: prov),
               inbox.enqueueAgentDraft(draft) { queued += 1 }
        }
        expect(queued == 8 && inbox.pending.count == ExplanationDraftWorkspace.maxPending, "eight pending")
        if let ninth = ExplanationDraft(id: "cap-8", display: "text 8", speech: nil, provenance: prov),
           let same = ExplanationDraft(id: "cap-0", display: "text 0", speech: nil, provenance: prov),
           let altered = ExplanationDraft(id: "cap-0", display: "text zero", speech: nil, provenance: prov) {
            expect(inbox.receive(ninth) == .busy && !inbox.enqueueAgentDraft(ninth), "ninth refused")
            expect(inbox.receive(same) == .duplicate && inbox.receive(altered) == .conflict, "duplicate and conflict")
            inbox.discard("cap-3")
            expect(inbox.enqueueAgentDraft(ninth) && inbox.pending.count == 8, "accepted once a slot is free")
            expect(inbox.display.isEmpty && inbox.origin == nil, "inbox never opens itself")
        } else {
            expect(false, "build cap drafts")
        }
        let plain = ExplanationDraftWorkspace()
        if let legacy = ExplanationDraft(id: "legacy", display: "no provenance", speech: nil) {
            expect(legacy.provenance == nil && !plain.enqueueAgentDraft(legacy) && plain.pending.isEmpty, "agent path requires provenance")
            expect(plain.receive(legacy) == .accepted, "existing receive API preserved")
        } else {
            expect(false, "build legacy draft")
        }
        expect(ExplanationDraft(id: "big", display: String(repeating: "a", count: 8193), speech: nil) == nil, "display over 8 KiB")
        expect(ExplanationDraft(id: "big", display: "ok", speech: String(repeating: "a", count: 8193)) == nil, "speech over 8 KiB")
        expect(ExplanationDraft(id: "fits", display: String(repeating: "a", count: 8192), speech: nil) != nil, "exactly 8 KiB")
        expect(ExplanationDraft(id: "nul", display: "ok", speech: "a\0b") == nil, "NUL refused")
        expect(ExplanationDraft(id: "bad id!", display: "ok", speech: nil) == nil, "id charset")
    }

    // MARK: Session + workspace

    static func integrationTests() {
        let clock = TestClock()
        let session = AgentSessionAuthorization(clock: { clock.now })
        let ws = ExplanationDraftWorkspace()
        let helper = UUID()
        let a = snapshot(UUID(), 1, "Instruction A")
        _ = session.pair(instanceID: helper, ownerLabel: "Desk helper")
        _ = session.grantReceipt(to: helper)
        expect(isRecorded(deliver(session, a, to: helper)), "integration delivery")

        // Three slots are already taken, so the sixth helper draft meets a full inbox.
        let filler = provenance()
        for i in 0..<3 {
            if let draft = ExplanationDraft(id: "filler-" + String(i), display: "filler " + String(i), speech: nil, provenance: filler) {
                _ = ws.enqueueAgentDraft(draft)
            }
        }
        ws.editDisplay("owner is typing")

        func send(_ n: Int) -> AgentSubmissionOutcome {
            let key = "int-" + String(n)
            let sub = submission(helper, a, key: key, display: "as_frame " + String(n), speech: "애즈 프레임")
            return session.submit(sub, enqueue: { prov in
                guard let draft = ExplanationDraft(id: key, display: sub.display, speech: sub.speech, provenance: prov) else { return false }
                return ws.enqueueAgentDraft(draft)
            })
        }

        var accepted = 0
        for n in 0..<5 where isAccepted(send(n)) { accepted += 1 }
        expect(accepted == 5 && ws.pending.count == 8, "inbox filled")
        expect(send(5) == .refusedByQueue, "full inbox is a refusal")
        expect(session.status().receipt?.acceptedCount == 5, "refusal consumed no quota")
        ws.discard("filler-0")
        expect(isAccepted(send(5)), "same draft accepted once a slot is free")
        expect(session.status().receipt?.acceptedCount == 6 && ws.pending.count == 8, "quota counts queued drafts")
        expect(send(5) == .duplicate, "resend is a duplicate")
        expect(ws.display == "owner is typing" && ws.speech.isEmpty && ws.origin == .manual, "editor never touched by receipts")
        let last = ws.pending.last?.provenance
        expect(last?.helperLabel == "Desk helper" && last?.helperInstanceID == helper, "queued provenance principal")
        expect(last?.profileID == a.profileID && last?.revision == a.revision && last?.instructionSHA256 == a.sha256, "queued provenance instruction")
    }
}

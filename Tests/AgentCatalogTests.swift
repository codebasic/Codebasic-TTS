import Darwin
import Foundation

enum CodeExplanation { static let noChange = "변경 없음" }

@main struct AgentCatalogTests {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let url = directory.appendingPathComponent("agent-instructions-v1.json")
        let stale = "e\u{301}\n"
        let new = "é\n"
        precondition(stale == new && !AgentBytes.same(stale, new))
        var failWrite = false
        let catalog = AgentCatalog(url: url) { bytes, dest in
            if failWrite { throw POSIXError(.EIO) }
            try AgentCatalog.writeAtomically(bytes, dest)
        }
        let original = try catalog.save(label: "뉴스", body: stale)
        let renamed = try catalog.save(id: original.id, expected: original.editVersion, label: "뉴 스", body: stale)
        precondition(original.id == renamed.id && original.generation == renamed.generation && original.editVersion != renamed.editVersion)
        do {
            _ = try catalog.save(id: original.id, expected: original.editVersion, label: "old edit", body: "fail")
            preconditionFailure("stale edit accepted")
        } catch AgentCatalog.Failure.conflict {}
        failWrite = true
        do {
            _ = try catalog.save(id: renamed.id, expected: renamed.editVersion, label: "unchanged", body: new)
            preconditionFailure("broken write accepted")
        } catch let e as POSIXError { precondition(e.code == .EIO) }
        precondition(catalog.record(original.selector)?.editVersion == renamed.editVersion)
        failWrite = false
        let edited = try catalog.save(id: renamed.id, expected: renamed.editVersion, label: renamed.label, body: new)
        let reverted = try catalog.save(id: edited.id, expected: edited.editVersion, label: edited.label, body: stale)
        precondition(edited.generation != reverted.generation && original.generation != reverted.generation)
        let reload = AgentCatalog(url: url)
        let stored = reload.record(reverted.selector)!
        precondition(stored.editVersion == reverted.editVersion && AgentBytes.same(stored.body, stale))
        var st = stat()
        precondition(lstat(url.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        try catalog.delete(reverted.id, expected: reverted.editVersion)
        precondition(catalog.record(reverted.selector) == nil)
        precondition(AgentCatalog(url: url).records.isEmpty)

        let oversized = AgentCatalogRecord(id: UUID(), generation: UUID(), label: "oversize",
                                           body: String(repeating: "가", count: 3000), editRecord: nil)
        let raw = try JSONEncoder().encode(AgentCatalog.File(version: 1, records: [oversized]))
        try AgentCatalog.writeAtomically(raw, url)
        let imported = AgentCatalog(url: url)
        precondition(imported.records.count == 1 && imported.records[0].body.utf8.count == 9000)
        precondition(!AgentInstructionSnapshot(selector: oversized.selector, generation: oversized.generation, text: oversized.body).shareable)
        let disk = try Data(contentsOf: url)
        precondition(disk == raw)

        let proofs = AgentDeliveryProofs()
        let snapshot = AgentInstructionSnapshot(selector: "explain", generation: UUID(), text: stale)
        let nonce = UUID()
        let now = ContinuousClock.now
        let epoch = proofs.epochForSend()
        precondition(proofs.resolve(nonce, selector: snapshot.selector, revision: snapshot.generation, digest: snapshot.digest, now: now) == nil)
        proofs.delivered(nonce, snapshot: snapshot, epoch: epoch, now: now)
        precondition(proofs.resolve(nonce, selector: snapshot.selector, revision: snapshot.generation, digest: snapshot.digest, now: now) != nil)
        precondition(proofs.resolve(nonce, selector: snapshot.selector, revision: snapshot.generation, digest: snapshot.digest, now: now.advanced(by: .seconds(600))) == nil)
        proofs.clear()
        let currentEpoch = proofs.epochForSend()
        for i in 0...AgentLimits.proofCount {
            proofs.delivered(i == 0 ? nonce : UUID(), snapshot: snapshot, epoch: currentEpoch, now: now)
        }
        precondition(proofs.resolve(nonce, selector: snapshot.selector, revision: snapshot.generation, digest: snapshot.digest, now: now) == nil)
        proofs.clear()
        proofs.delivered(nonce, snapshot: snapshot, epoch: epoch, now: now)
        precondition(proofs.resolve(nonce, selector: snapshot.selector, revision: snapshot.generation, digest: snapshot.digest, now: now) == nil)

        var rate = AgentRateLimit()
        for window in 0..<4 {
            let t = now.advanced(by: .seconds(window * 61))
            for _ in 0..<min(6, 20 - window * 6) {
                precondition(rate.canAccept(now: t)); rate.mark(now: t)
            }
            precondition(!rate.canAccept(now: t))
        }

        for unsafe in ["<break time=\"1s\"/>", "&lt;break&gt;", "&#x3c;break&#62;",
                       "&amp;lt;break", "%3Cbreak%3E", "\\u003cbreak\\u003e", "＜break＞", "[whispering]"] {
            precondition(!AgentBytes.safeForSpeech(unsafe), unsafe)
        }
        let draft = ExplanationDraftWorkspace()
        let from = AgentDraftOrigin(principal: UUID(), agentLabel: "Local", selector: "explain", revision: UUID(), bodyHash: snapshot.digest, older: true)
        let first = ExplanationDraft(id: "one", display: "표기", speech: "발음", provenance: from)!
        precondition(draft.receive(first) == .accepted && draft.display.isEmpty)
        precondition(draft.receive(ExplanationDraft(id: "two", display: "표기", speech: "발음", provenance: from)!) == .duplicate)
        precondition(draft.open(first.id) && draft.speechNeedsReview && draft.playback() == nil)
        precondition(draft.playback(displayOnly: true)?.speech == "표기")
        draft.confirmSpeech()
        precondition(draft.playback()?.speech == "발음")
        draft.editDisplay("바꿈"); draft.editDisplay("표기")
        precondition(draft.speechNeedsReview && draft.playback() == nil)
        draft.editSpeech("&lt;break&gt;"); draft.confirmSpeech()
        precondition(draft.playback() == nil)
        print("Agent catalog: atomic persistence/failure, stable identity, oversized preservation, exact generations, proof cap/epoch/TTL, rate, speech guard passed")
    }
}

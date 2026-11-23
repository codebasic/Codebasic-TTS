import CryptoKit
import Darwin
import Foundation

enum CodeExplanation { static let noChange = "변경 없음" }

@main struct AgentCatalogTests {
    @MainActor static func main() throws {
        if CommandLine.arguments.count == 4 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let mode = CommandLine.arguments[2]
            if mode == "hold-lock" {
                let lock = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".lock")
                let fd = Darwin.open(lock.path, O_RDWR | O_NOFOLLOW)
                precondition(fd >= 0 && flock(fd, LOCK_EX) == 0)
                print("ready"); fflush(stdout)
                precondition(readLine() == "go")
                close(fd)
            } else {
                let catalog = AgentCatalog(url: url)
                let entry = catalog.record(CommandLine.arguments[3])!
                print("ready"); fflush(stdout)
                precondition(readLine() == "go")
                _ = try catalog.save(id: entry.id, expected: entry.editVersion, label: entry.label, body: "other process")
            }
            return
        }
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
        try crossProcess(at: directory.appendingPathComponent("concurrent.json"))

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

        // Both windows slide: six a minute, sixty an hour, and never used up for good.
        var rate = AgentRateLimit()
        for window in 0..<10 {
            let t = now.advanced(by: .seconds(window * 61))
            for _ in 0..<6 { precondition(rate.canAccept(now: t)); rate.mark(now: t) }
            precondition(!rate.canAccept(now: t))
        }
        precondition(!rate.canAccept(now: now.advanced(by: .seconds(11 * 61))))
        precondition(rate.canAccept(now: now.advanced(by: .seconds(3601))))

        try trustStore(directory)

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

        let documents = ExplanationDraftWorkspace()
        documents.editDisplay("미저장 수동 대본")
        let manualID = documents.editorDocumentID
        precondition(documents.receiveDocument(first) == .accepted)
        documents.clearEditor(expectedDocumentID: manualID)
        precondition(documents.display == first.display && documents.speech == first.speech)
        documents.editDisplay("계속 편집할 화면 글")
        documents.editSpeech("계속 편집할 음성")
        documents.selectDocument(manualID)
        precondition(documents.display == "미저장 수동 대본")
        documents.clearEditor(expectedDocumentID: manualID)
        precondition(documents.display.isEmpty && documents.editorDocumentID != manualID)
        precondition(documents.activeDocumentID == nil && documents.hasInactiveDocuments)
        precondition(documents.documentTabs.map(\.id) == [first.id] && documents.documentTabs[0].dirty)
        documents.selectDocument(first.id)
        precondition(documents.display == "계속 편집할 화면 글" && documents.speech == "계속 편집할 음성")
        precondition(!documents.hasInactiveDocuments)
        documents.revertReceivedDocument()
        precondition(documents.display == first.display && documents.speech == first.speech)
        // Review follow-ups: a delayed confirmation or playback control is pinned to
        // the document it was shown for, and a lone received document can be left.
        documents.editDisplay("되돌리기 전 수정")
        documents.revertReceivedDocument(expectedDocumentID: "another-document")
        precondition(documents.display == "되돌리기 전 수정")
        precondition(documents.playback(displayOnly: true, expectedDocumentID: "another-document") == nil)
        precondition(documents.playback(displayOnly: true, expectedDocumentID: first.id)?.display == "되돌리기 전 수정")
        documents.revertReceivedDocument(expectedDocumentID: first.id)
        precondition(documents.display == first.display && documents.provenance == from)
        precondition(documents.newDocument() && documents.activeDocumentID == nil && documents.display.isEmpty)
        precondition(documents.provenance == nil && documents.documentTabs.map(\.id) == [first.id])
        documents.editDisplay("새 수동 대본")
        let fresh = documents.editorDocumentID
        precondition(documents.documentTabs.map(\.id) == [first.id, fresh])
        documents.closeActiveDocument(expectedDocumentID: "another-document")
        precondition(documents.display == "새 수동 대본")
        documents.closeActiveDocument(expectedDocumentID: fresh)
        precondition(documents.activeDocumentID == first.id && documents.display == first.display)
        documents.closeActiveDocument(expectedDocumentID: first.id)
        precondition(documents.activeDocumentID == nil && documents.documentTabs.isEmpty && !documents.hasEditorContent)

        let limits = ExplanationDraftWorkspace()
        precondition(limits.receiveBlock() == nil && limits.unseenArrivals == 0)
        limits.editDisplay(String(repeating: "가", count: 90 * 1024))
        precondition(limits.receiveBlock() == .bytes && limits.receiveDocument(first) == .busy && !limits.newDocument())
        limits.editDisplay("짧은 글")
        precondition(limits.receiveDocument(first) == .accepted && limits.unseenArrivals == 1 && limits.arrivalNotice != nil)
        limits.editDisplay(first.display + " 수정", pasted: true)
        precondition(limits.origin == .received && limits.arrivalNotice == nil)
        limits.markArrivalsSeen()
        precondition(limits.unseenArrivals == 0 && limits.arrivalCount == 1)
        for index in 0..<4 {
            precondition(limits.receiveDocument(ExplanationDraft(id: "fill\(index)", display: "채움 \(index)", speech: nil)!) == .accepted)
        }
        precondition(limits.receiveBlock() == .documents && limits.documentTabs.count == ExplanationDraftWorkspace.maxDocuments)
        print("Agent documents: revert, playback and close are pinned to their document; a lone received document can be closed or left for a new one")
        print("Agent documents: an oversized open text and a full tab bar are reported as different receive blocks")
        print("Agent documents: an untitled editor keeps its identity when parked; stale clear cannot affect a receipt")
        print("Agent documents: sole parked edited tab remains visible after clearing the active manual document and reopens with both edits intact")
        print("Agent catalog: atomic persistence/failure, stable identity, oversized preservation, exact generations, proof cap/epoch/TTL, rate, speech guard passed")
    }

    @MainActor static func crossProcess(at url: URL) throws {
        let a = AgentCatalog(url: url), b = AgentCatalog(url: url)
        let one = try a.save(label: "Café 뉴스", body: "body A")
        let two = try b.save(label: "Lecture", body: "body B")
        precondition(b.records.count == 2)
        let (child, signal) = try childProcess(url: url, mode: "save", selector: two.selector)
        let edited = try a.save(id: one.id, expected: one.editVersion, label: one.label, body: "body A newer")
        try finish(child, signal)
        precondition(a.refresh() && a.record(one.selector)?.generation == edited.generation &&
            a.record(two.selector)?.body == "other process")
        precondition(a.filteredRecords(label: "  CAFE ").map(\.selector) == [one.selector])
        precondition(a.filteredRecords(label: "NEWS").isEmpty && a.filteredRecords(label: "").count == 2)
        do {
            _ = try b.save(id: one.id, expected: one.editVersion, label: one.label, body: "stale edit")
            preconditionFailure("same-record stale save wasn't rejected")
        } catch AgentCatalog.Failure.conflict {}
        precondition(b.record(one.selector)?.generation == edited.generation)
        do {
            try b.delete(two.id, expected: two.editVersion)
            preconditionFailure("same-record stale delete wasn't rejected")
        } catch AgentCatalog.Failure.conflict {}
        let (locker, unlock) = try childProcess(url: url, mode: "hold-lock", selector: "-")
        do {
            _ = try a.save(label: "can't write while locked", body: "blocked")
            preconditionFailure("cross-process lock wasn't enforced")
        } catch AgentCatalog.Failure.busy {}
        try finish(locker, unlock)

        let snapshot = AgentInstructionSnapshot(selector: edited.selector, generation: edited.generation, text: edited.body)
        let gate = a.deliveryGate(for: snapshot)
        var sends = 0
        gate { sends += 1 }
        let titleOnly = try b.save(id: edited.id, expected: edited.editVersion, label: "Renamed", body: edited.body)
        gate { sends += 1 }
        precondition(sends == 2 && titleOnly.generation == edited.generation)
        let changed = try b.save(id: titleOnly.id, expected: titleOnly.editVersion, label: titleOnly.label, body: "external edit")
        let reverted = try b.save(id: changed.id, expected: changed.editVersion, label: changed.label, body: edited.body)
        gate { sends += 1 }
        precondition(sends == 2 && reverted.generation != snapshot.generation)
        let currentGate = b.deliveryGate(for: .init(selector: reverted.selector, generation: reverted.generation, text: reverted.body))
        try b.delete(reverted.id, expected: reverted.editVersion)
        currentGate { sends += 1 }
        precondition(sends == 2)

        let valid = try Data(contentsOf: url)
        let corrupt = Data("synthetic unrecognized file".utf8)
        try AgentCatalog.writeAtomically(corrupt, url)
        do {
            _ = try a.save(label: "recovery", body: "must not overwrite unknown data")
            preconditionFailure("unreadable store was overwritten")
        } catch AgentCatalog.Failure.unreadable {}
        precondition(a.readError)
        let unreadable = try Data(contentsOf: url)
        precondition(unreadable == corrupt)
        try AgentCatalog.writeAtomically(valid, url)
        precondition(a.refresh() && !a.readError)
        _ = try a.save(label: "recovered", body: "safe new entry")
        precondition(AgentCatalog(url: url).records.count == 2)
        print("Catalog: actual second process, separate edits, stale edit/delete, lock busy/retry, external revision delivery guard, corrupt file preservation, and label filter passed")
    }

    /// Approval record rules, with real P-256 signatures and a controllable clock.
    static func trustStore(_ directory: URL) throws {
        let url = directory.appendingPathComponent("agent-clients.json")
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        func open() -> AgentTrustStore { AgentTrustStore(url: url, now: { clock }) }
        let key = P256.Signing.PrivateKey(), other = P256.Signing.PrivateKey()
        let publicKey = key.publicKey.x963Representation
        let keyID = AgentPairingProof.keyID(publicKey)!
        let message = AgentPairing.message(appID: "app", nonce: "nonce", keyID: keyID)
        let signature = try key.signature(for: message).derRepresentation
        precondition(AgentPairingProof.verify(publicKey: publicKey, signature: signature, message: message))
        precondition(!AgentPairingProof.verify(publicKey: other.publicKey.x963Representation, signature: signature, message: message))
        precondition(!AgentPairingProof.verify(publicKey: publicKey, signature: signature,
                                               message: AgentPairing.message(appID: "app", nonce: "other", keyID: keyID)))
        precondition(AgentPairingProof.keyID(Data([1, 2, 3])) == nil)
        precondition(AgentPairing.clientName("Claude Code/1.0") == "claudecode1.0" && AgentPairing.clientName("한글") == "default")

        var store = open()
        precondition(store.clients.isEmpty && !store.autoReceive && store.lookup(keyID: keyID, host: "h") == .unknown)
        let client = try store.trust(publicKey: publicKey, label: "claude", host: "h")
        precondition(store.setAutoReceive(true))
        var attributes = stat()
        precondition(stat(url.path, &attributes) == 0 && attributes.st_mode & 0o777 == 0o600)
        store = open()   // a restarted app
        precondition(store.autoReceive && store.lookup(keyID: keyID, host: "h") == .trusted(client))
        precondition(store.lookup(keyID: keyID, host: "elsewhere") == .hostChanged)
        precondition(store.lookup(keyID: AgentPairingProof.keyID(other.publicKey.x963Representation)!, host: "h") == .unknown)
        clock += AgentTrustStore.idleLimit - 60
        store.touch(client.id)
        clock += AgentTrustStore.idleLimit - 60   // sliding: counted from the last reconnect
        precondition(open().lookup(keyID: keyID, host: "h") != .expired)
        clock += 120
        precondition(open().lookup(keyID: keyID, host: "h") == .expired)
        let renewed = try store.trust(publicKey: publicKey, label: "claude", host: "h")
        precondition(renewed.id != client.id && store.clients.count == 1)

        // A new key under the same name from the same launcher supersedes the old record only.
        _ = try store.trust(publicKey: P256.Signing.PrivateKey().publicKey.x963Representation, label: "codex", host: "h")
        let replaced = try store.trust(publicKey: P256.Signing.PrivateKey().publicKey.x963Representation, label: "codex", host: "h")
        precondition(store.clients.map(\.id) == [renewed.id, replaced.id])
        for index in 2..<AgentTrustStore.maxClients {
            _ = try store.trust(publicKey: P256.Signing.PrivateKey().publicKey.x963Representation, label: "x\(index)", host: "h")
        }
        do {
            _ = try store.trust(publicKey: other.publicKey.x963Representation, label: "x", host: "h")
            preconditionFailure("a ninth client must not evict an approved one")
        } catch AgentTrustStore.Failure.full {}

        precondition(store.forget(renewed.id))
        store = open()
        precondition(store.lookup(keyID: keyID, host: "h") == .revoked && store.clients.count == AgentTrustStore.maxClients - 1)
        do {
            _ = try store.trust(publicKey: publicKey, label: "claude", host: "h")
            preconditionFailure("a forgotten key must not be approved again")
        } catch AgentTrustStore.Failure.revoked {}

        // Anything but our own private, intact file is no trust at all.
        precondition(chmod(url.path, 0o644) == 0 && open().clients.isEmpty && !open().autoReceive)
        precondition(chmod(url.path, 0o600) == 0 && !open().clients.isEmpty)
        try Data("{".utf8).write(to: url)
        precondition(chmod(url.path, 0o600) == 0 && open().clients.isEmpty)
        print("Trust store: signature binding, restart, host change, sliding idle expiry, full, forget tombstone, and unreadable-file fail-closed passed")
    }

    static func childProcess(url: URL, mode: String, selector: String) throws -> (Process, FileHandle) {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = [url.path, mode, selector]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        let ready = try output.fileHandleForReading.read(upToCount: 6)
        precondition(ready == Data("ready\n".utf8))
        return (process, input.fileHandleForWriting)
    }

    static func finish(_ process: Process, _ signal: FileHandle) throws {
        try signal.write(contentsOf: Data("go\n".utf8))
        try signal.close()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
    }
}

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

        let documents = ExplanationDraftWorkspace()
        documents.editDisplay("미저장 수동 대본")
        let manualID = documents.editorDocumentID
        precondition(documents.receiveDocument(first) == .accepted)
        documents.clearEditor(expectedDocumentID: manualID)
        precondition(documents.display == first.display && documents.speech == first.speech)
        documents.selectDocument(manualID)
        precondition(documents.display == "미저장 수동 대본")
        documents.clearEditor(expectedDocumentID: manualID)
        precondition(documents.display.isEmpty && documents.editorDocumentID != manualID)
        print("Agent documents: an untitled editor keeps its identity when parked; stale clear cannot affect a receipt")
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

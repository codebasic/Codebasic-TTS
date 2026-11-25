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
        precondition(limits.unseenArrivals == 0)
        limits.editDisplay(String(repeating: "가", count: 90 * 1024))
        precondition(limits.newDocument())   // a large open text no longer blocks anything
        limits.editDisplay("짧은 글")
        precondition(limits.receiveDocument(first) == .accepted && limits.unseenArrivals == 1 && limits.arrivalNotice != nil)
        limits.editDisplay(first.display + " 수정", pasted: true)
        precondition(limits.origin == .received && limits.arrivalNotice == nil)
        limits.markArrivalsSeen()
        precondition(limits.unseenArrivals == 0 && limits.arrivalCount == 1)
        try draftHistory(directory)
        print("Agent documents: revert, playback and close are pinned to their document; a lone received document can be closed or left for a new one")
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

    /// Titles, the unlimited stored list, and what survives a restart.
    @MainActor static func draftHistory(_ directory: URL) throws {
        // Title rules: kept whole or refused whole.
        precondition(AgentBytes.title(nil) == .absent && AgentBytes.title("  \n ") == .absent)
        precondition(AgentBytes.title("  수업 정리 🎧  ") == .valid("수업 정리 🎧"))
        let family = "👨‍👩‍👧‍👦"   // one character, 25 bytes
        precondition(AgentBytes.title(String(repeating: "가", count: AgentLimits.titleCharacters)) != .invalid)
        precondition(AgentBytes.title(String(repeating: "가", count: AgentLimits.titleCharacters + 1)) == .invalid)
        precondition(AgentBytes.title(String(repeating: family, count: 20)) != .invalid)
        precondition(AgentBytes.title(String(repeating: family, count: 21)) == .invalid)   // 525 bytes
        precondition(AgentBytes.title("e\u{301}" + String(repeating: "\u{301}", count: 300)) == .invalid)   // one character, too many bytes
        precondition(AgentBytes.title("두 줄\n제목") == .invalid && AgentBytes.title("탭\t문자") == .invalid)
        precondition(ExplanationDraft(id: "t", display: "본문", speech: nil, title: "두 줄\n제목") == nil)

        let body = "본문 첫 줄입니다.\n둘째 줄", spoken = "읽을 글"
        let titled = ExplanationDraft(id: "k1", display: body, speech: spoken, title: " 제목만 다른 글 ")!
        let plain = ExplanationDraft(id: "k1", display: body, speech: spoken)!
        let blank = ExplanationDraft(id: "k1", display: body, speech: spoken, title: "   ")!
        precondition(titled.title == "제목만 다른 글" && plain.title == nil && blank.title == nil)
        precondition(titled.fingerprintHex != plain.fingerprintHex && blank.fingerprintHex == plain.fingerprintHex)

        let url = directory.appendingPathComponent("drafts.sqlite")
        func open() -> ExplanationDraftWorkspace { ExplanationDraftWorkspace(store: SQLiteDraftStore(url: url)!) }
        var work = open()
        precondition(work.documentTabs.isEmpty)
        precondition(work.receiveDocument(titled) == .accepted)
        var attributes = stat()
        precondition(stat(url.path, &attributes) == 0 && attributes.st_mode & 0o777 == 0o600)
        // The title names the document and appears nowhere in what is edited, copied or read.
        precondition(work.documentTabs.map(\.title) == ["제목만 다른 글"])
        precondition(work.display == body && work.speech == spoken && !work.display.contains("제목만"))
        work.confirmSpeech()
        precondition(work.playback()! == (body, spoken) && work.playback(displayOnly: true)! == (body, body))
        // Same key: identical is one document; another title or body is a conflict, never an edit.
        precondition(work.receiveDocument(titled) == .duplicate)
        precondition(work.receiveDocument(plain) == .conflict)
        precondition(work.receiveDocument(ExplanationDraft(id: "k1", display: "다른 본문", speech: spoken, title: "제목만 다른 글")!) == .conflict)
        precondition(work.documentTabs.count == 1 && work.display == body)
        // Same title under different keys stays two documents.
        precondition(work.receiveDocument(ExplanationDraft(id: "k2", display: "또 다른 본문", speech: nil, title: "제목만 다른 글")!) == .accepted)
        // No title: the first line that is not blank stands in, and old clients keep working.
        precondition(work.receiveDocument(ExplanationDraft(id: "k3", display: "\n   \n  대체 제목 줄  \n본문", speech: nil)!) == .accepted)
        precondition(work.documentTabs.map(\.title) == ["제목만 다른 글", "제목만 다른 글", "대체 제목 줄"])

        // Editing one document, browsing another, and coming back.
        work.selectDocument("k1")
        work.editDisplay(body + " 수정")
        work.selectDocument("k3")
        precondition(work.documentTabs.map(\.dirty) == [true, false, false])
        work.selectDocument("k1")
        precondition(work.display == body + " 수정" && work.canRevertReceived && work.activeOriginal?.display == body)

        // While the user is searching the list, an arrival is listed but does not take the editor.
        work.browsing = true
        precondition(work.receiveDocument(ExplanationDraft(id: "k4", display: "검색 중 도착", speech: nil, title: "늦게 온 글")!) == .accepted)
        precondition(work.activeDocumentID == "k1" && work.display == body + " 수정")
        precondition(work.documentTabs.last?.unseen == true && work.arrivalNotice != nil)
        work.browsing = false
        work.selectDocument("k4")
        precondition(work.display == "검색 중 도착" && work.documentTabs.last?.unseen == false)
        work.selectDocument("k1")

        // Far beyond the old six: nothing is refused, closed or overwritten.
        for number in 0..<150 {
            let next = ExplanationDraft(id: "bulk-\(number)", display: "연속 수신 \(number)", speech: nil, title: number % 2 == 0 ? "묶음 \(number)" : nil)!
            precondition(work.receiveDocument(next) == .accepted)
        }
        precondition(work.documentTabs.count == 154 && work.activeDocumentID == "bulk-149")
        work.selectDocument("k1")
        work.flush()

        // A restarted app: same list, same order, the edit, the original, and the open document.
        work = open()
        precondition(work.documentTabs.count == 154 && work.activeDocumentID == "k1")
        precondition(work.display == body + " 수정" && work.activeOriginal?.display == body && work.activeOriginal?.title == "제목만 다른 글")
        precondition(work.documentTabs.prefix(4).map(\.title) == ["제목만 다른 글", "제목만 다른 글", "대체 제목 줄", "늦게 온 글"])
        precondition(work.documentTabs[5].title == "연속 수신 1" && work.documentTabs.first?.dirty == true)
        // The stored original still answers for its key.
        precondition(work.receiveDocument(titled) == .duplicate && work.receiveDocument(plain) == .conflict)
        work.revertReceivedDocument()
        precondition(work.display == body && !work.canRevertReceived)
        work.closeInactiveDocument("k2")
        work = open()
        precondition(work.documentTabs.count == 153 && !work.documentTabs.contains { $0.id == "k2" } && work.display == body)

        // A draft that cannot be stored is refused and changes nothing.
        let memory = MemoryDraftStore()
        let failing = ExplanationDraftWorkspace(store: memory)
        failing.editDisplay("쓰던 글")
        memory.failWrites = true
        precondition(failing.receiveDocument(titled) == .busy && failing.display == "쓰던 글" && failing.unseenArrivals == 0)

        // Parking the editor fails: switching, a new document and an arrival keep the unsaved text.
        let parkStore = MemoryDraftStore()
        let parking = ExplanationDraftWorkspace(store: parkStore)
        precondition(parking.receiveDocument(ExplanationDraft(id: "p1", display: "받은 글", speech: nil)!) == .accepted)
        precondition(parking.newDocument())
        parking.editDisplay("저장 안 된 글")
        let unsavedID = parking.editorDocumentID
        parkStore.failWritesFor = [unsavedID]
        parking.selectDocument("p1")
        precondition(parking.display == "저장 안 된 글" && parking.editorDocumentID == unsavedID && parking.arrivalNotice != nil)
        precondition(!parking.newDocument() && parking.display == "저장 안 된 글")
        precondition(parking.receiveDocument(ExplanationDraft(id: "p2", display: "실패 중 도착", speech: nil)!) == .accepted)
        precondition(parking.display == "저장 안 된 글" && parking.editorDocumentID == unsavedID)
        precondition(parking.documentTabs.contains { $0.id == "p2" && $0.unseen } && parkStore.load("p2") != nil)
        // Once storage works again the same text is saved and the switch goes through.
        parkStore.failWritesFor = []
        parking.selectDocument("p1")
        precondition(parking.display == "받은 글" && parkStore.load(unsavedID)?.display == "저장 안 된 글")

        // A manual document being edited reopens after a restart.
        let manualStore = MemoryDraftStore()
        let manual = ExplanationDraftWorkspace(store: manualStore)
        manual.editDisplay("직접 쓴 글")
        let manualDocID = manual.editorDocumentID
        manual.flush()
        precondition(manualStore.activeID == manualDocID)
        let reopened = ExplanationDraftWorkspace(store: manualStore)
        precondition(reopened.display == "직접 쓴 글" && reopened.editorDocumentID == manualDocID)
        precondition(reopened.newDocument() && manualStore.activeID == nil)
        print("Draft history: title rules, title kept out of body and playback, key duplicate/conflict, fallback title, 154 documents, search-time arrival, restart restore, storage failure, failed park keeps editor, manual draft reopens passed")
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
        precondition(renewed.id == client.id && store.clients.count == 1)

        // Independent hosts do not replace one another even with identical labels.
        let duplicateLabel = try store.trust(publicKey: P256.Signing.PrivateKey().publicKey.x963Representation,
                                             label: "claude", host: "separate-host")
        precondition(store.clients.map(\.id) == [renewed.id, duplicateLabel.id])
        precondition(store.setReceiptEnabled(false, for: renewed.id))
        store = open()
        precondition(store.autoReceive && store.clients.map(\.receiptEnabled) == [false, true])
        do {
            _ = try store.trust(publicKey: publicKey, label: "claude", host: "another-host")
            preconditionFailure("a different host must not replace this key's approval")
        } catch AgentTrustStore.Failure.hostChanged {}
        for index in 2..<AgentTrustStore.maxClients {
            _ = try store.trust(publicKey: P256.Signing.PrivateKey().publicKey.x963Representation, label: "x\(index)", host: "host-\(index)")
        }
        do {
            _ = try store.trust(publicKey: other.publicKey.x963Representation, label: "x", host: "extra-host")
            preconditionFailure("a ninth client must not evict an approved one")
        } catch AgentTrustStore.Failure.full {}

        precondition(store.forget(renewed.id))
        store = open()
        precondition(store.lookup(keyID: keyID, host: "h") == .revoked && store.clients.count == AgentTrustStore.maxClients - 1)
        do {
            _ = try store.trust(publicKey: publicKey, label: "claude", host: "h")
            preconditionFailure("a forgotten key must not be approved again")
        } catch AgentTrustStore.Failure.revoked {}

        let retryURL = directory.appendingPathComponent("agent-denial.json")
        var writesFail = false
        let retry = AgentTrustStore(url: retryURL, write: { data, url in
            if writesFail { throw CocoaError(.fileWriteOutOfSpace) }
            try AgentTrustStore.writePrivately(data, url)
        })
        let registeredHost = AgentPairing.registeredHostPrefix + "test"
        let approved = try retry.trust(publicKey: publicKey, label: "same", host: registeredHost)
        let rotated = try retry.trust(publicKey: other.publicKey.x963Representation, label: "same", host: registeredHost)
        precondition(approved.id == rotated.id && retry.lookup(keyID: keyID, host: registeredHost) == .revoked)
        precondition(retry.setAutoReceive(true))
        writesFail = true
        precondition(!retry.setReceiptEnabled(false, for: rotated.id) && !retry.clients[0].receiptEnabled)
        precondition(!retry.setAutoReceive(false) && !retry.autoReceive)
        writesFail = false
        precondition(retry.setReceiptEnabled(false, for: rotated.id))
        let restarted = AgentTrustStore(url: retryURL)
        precondition(!restarted.autoReceive && restarted.clients.count == 1 && !restarted.clients[0].receiptEnabled)

        // Anything but our own private, intact file is no trust at all.
        precondition(chmod(url.path, 0o644) == 0 && open().clients.isEmpty && !open().autoReceive)
        precondition(chmod(url.path, 0o600) == 0 && !open().clients.isEmpty)
        try Data("{".utf8).write(to: url)
        precondition(chmod(url.path, 0o600) == 0 && open().clients.isEmpty)
        print("Trust store: signature binding, restart, host change, expiry, app key rotation, capacity, revocation and failed-write denial passed")
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

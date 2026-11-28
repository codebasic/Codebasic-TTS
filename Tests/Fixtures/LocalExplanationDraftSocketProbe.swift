import Darwin
import Foundation
import Security

enum CodeExplanation { static let noChange = "변경 없음" }

@MainActor final class AgentFixture {
    let access: AgentSessionController
    let drafts: ExplanationDraftWorkspace
    let catalog = AgentCatalog(url: URL(fileURLWithPath: "catalog-\(UUID()).json"))
    let selector = "66666666-6666-4666-8666-666666666666"
    let original = "합성 지시 e\u{301}\n"
    var current: AgentInstructionSnapshot?
    var edits = AgentInstructionEditBuffer()
    var clearDocumentID: String?
    let alternate = AgentInstructionSnapshot(selector: "continue", generation: UUID(), text: "두 번째 합성 지시")

    init(directory: String, expectedHelper: String, wait: Duration, trust: String, database: String?) {
        // With a database path this is the app's real stored list; without, memory only.
        drafts = ExplanationDraftWorkspace(store: database.flatMap { SQLiteDraftStore(url: URL(fileURLWithPath: $0)) } ?? MemoryDraftStore())
        access = AgentSessionController(directory: directory, bundledHelper: {
            AgentPeerSigning.signedHash(at: URL(fileURLWithPath: expectedHelper))
        }, selectionWaiting: wait, noSessionDelay: .milliseconds(500), trust: AgentTrustStore(url: URL(fileURLWithPath: trust)))
        current = AgentInstructionSnapshot(selector: selector, generation: UUID(), text: original)
        catalog.didChange = { [weak self] selector, deleted in self?.access.invalidate(selector, deleted: deleted) }
    }

    func resolve(_ value: String) -> AgentInstructionSnapshot? {
        if value == alternate.selector { return alternate }
        if current?.selector == value { return current }
        guard let record = catalog.record(value) else { return nil }
        return AgentInstructionSnapshot(selector: value, generation: record.generation, text: record.body)
    }

    func command(_ line: String) {
        func report(_ value: String) { print(value); fflush(stdout) }
        let pieces = line.split(separator: " ")
        switch pieces.first {
        case "pair": report(access.startPairing() ? "ok" : "no")
        case "clients":
            let rows: [[String: Any]] = access.connections.map { client in
                ["id": client.id.uuidString, "label": client.label, "state": client.state.rawValue,
                 "persistent": client.persistent, "host": client.host ?? "", "receiptEnabled": client.receiptEnabled]
            }
            report(String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
        case "requests":
            let rows = access.approvalRequests.map { request in
                ["id": request.id.uuidString, "label": request.label, "host": request.host ?? "",
                 "launcher": request.launcher ?? ""]
            }
            report(String(decoding: try! JSONSerialization.data(withJSONObject: rows), as: UTF8.self))
        case "approve", "disconnect", "resume", "forget":
            let explicit = pieces.dropFirst().first.flatMap { UUID(uuidString: String($0)) }
            let fallback = access.connections.count == 1 ? access.connections.first?.id : nil
            guard let id = explicit ?? (pieces.count == 1 && pieces.first != "approve" ? fallback : nil) else {
                report("no"); return
            }
            let success: Bool
            switch pieces[0] {
            case "approve": success = access.approve(id)
            case "disconnect": success = access.disconnect(id)
            case "resume": success = access.resume(id)
            default: success = access.forget(id)
            }
            report(success ? "ok" : "no")
        case "enable":
            report(access.enableReceive(current: { [weak self] in self?.resolve($0) }, workspace: drafts) ? "ok" : "no")
        case "disable": access.disableReceive(); report("ok")
        // What the app does at launch, with no click.
        case "configure": access.configure(current: { [weak self] in self?.resolve($0) }, workspace: drafts); report("ok")
        // What the app does when the Agent tab becomes visible or goes away.
        case "presence":
            access.setPresence(pieces.last == "on", detail: "fixture")
            report("ok")
        case "connect-state":
            let body: [String: Any] = ["choice": access.receiptChoice.rawValue, "legacy": access.legacyReceiptOff,
                                       "auto": access.autoReceive, "pairing": access.pairingActive,
                                       "open": access.presenceOpen, "noSession": access.noAgentSession,
                                       "attempts": Dictionary(uniqueKeysWithValues: access.lastAttempts.map { ($0.key.uuidString, $0.value.result) })]
            report(String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        case "lock": access.setLocked(true); report("ok")
        case "unlock": access.setLocked(false); report("ok")
        case "reset-documents":
            for _ in 0..<16 {
                guard let tab = drafts.documentTabs.first else { break }
                if tab.id == drafts.editorDocumentID { drafts.closeActiveDocument(expectedDocumentID: tab.id) }
                else { drafts.closeInactiveDocument(tab.id) }
            }
            report("ok")
        case "documents":
            let all = drafts.documentTabs.map { tab -> String in
                drafts.selectDocument(tab.id)
                return AgentBytes.hash(Data(drafts.display.utf8)) + ":" + String(drafts.display.utf8.count)
            }
            report(all.joined(separator: " "))
        case "select", "select-alternate":
            if pieces.count == 2 {
                guard let client = UUID(uuidString: String(pieces[1])) else { report("no"); return }
                access.chooseInstructionClient(client)
            }
            let selection = pieces.first == "select-alternate" ? alternate : current
            report(selection.map { chosen in
                access.select(chosen, current: { [weak self] in self?.resolve($0) })
            } == true ? "ok" : "no")
        case "edit-document": drafts.editDisplay("직접 수정: " + drafts.display); report("ok")
        case "edit-speech": drafts.editSpeech("음성 수정: " + drafts.speech); report("ok")
        case "begin-clear": clearDocumentID = drafts.editorDocumentID; report("ok")
        case "confirm-clear":
            guard let id = clearDocumentID else { report("no"); return }
            clearDocumentID = nil
            drafts.clearEditor(expectedDocumentID: id)
            report("ok")
        case "switch-tab", "close-tab":
            guard pieces.count == 2, let index = Int(pieces[1]), drafts.documentTabs.indices.contains(index) else {
                report("no"); return
            }
            let id = drafts.documentTabs[index].id
            if pieces.first == "close-tab" { drafts.closeInactiveDocument(id) }
            else { drafts.selectDocument(id) }
            report("ok")
        case "revert-document": drafts.revertReceivedDocument(); report("ok")
        case "save-new-instruction":
            let saved = try? catalog.save(label: "합성 새 지시 " + UUID().uuidString, body: "공유하지 않은 저장본")
            report(saved?.selector ?? "no")
        case "edit-buffer":
            guard let current else { report("no"); return }
            var entry = edits.entry(for: selector, expected: current.generation, label: "합성", text: current.text)
            entry.text = "저장하지 않은 합성 지시"
            edits.update(entry, for: selector)
            report("ok")
        case "save-buffer":
            guard let old = current, let entry = edits.drafts[selector], entry.expected == old.generation else {
                report("no"); return
            }
            let file = URL(fileURLWithPath: "inline-preset.json")
            guard let saved = try? AgentPresetInstructions.write(entry.text, for: "explain", expectedOverride: nil, at: file),
                  let text = saved["explain"] else { report("no"); return }
            current = AgentInstructionSnapshot(selector: selector, generation: UUID(), text: text)
            access.invalidate(selector, deleted: false)
            edits.revert(selector)
            report("ok")
        case "revert-buffer": edits.revert(selector); report("ok")
        case "revoke": access.revokeSelection(); report("ok")
        case "reject":
            access.rejectSelection(selector, reason: .catalogUnavailable)
            report("ok")
        case "invalidate-pending":
            access.invalidate(selector, deleted: false)
            report("ok")
        case "change", "revert", "delete":
            let verb = pieces[0]
            access.invalidate(selector, deleted: verb == "delete")
            current = verb == "delete" ? nil : AgentInstructionSnapshot(selector: selector, generation: UUID(),
                         text: verb == "revert" ? original : "합성 지시 다른 버전\n")
            report("ok")
        case "snapshot":
            let live = access.connections.filter { $0.helperPID != nil }
            let body: [String: Any] = [
                "selection": access.selectionStatus.rawValue, "diagnostics": access.selectionDiagnostics.map(\.rawValue),
                "paired": !live.isEmpty, "editor": drafts.display, "speech": drafts.speech,
                "editorID": drafts.editorDocumentID, "shared": access.shared != nil, "scope": access.instructionScope ?? "",
                "receiving": access.receiving, "waiting": access.autoReceive && !access.receiving && access.approvalRequests.isEmpty,
                "auto": access.autoReceive, "locked": access.locked, "trusted": access.trusted.map(\.label),
                "hosts": access.trusted.map(\.host), "persistent": live.contains(where: \.persistent),
                "awaiting": access.approvalRequests.first?.label ?? "", "status": access.status,
                "tabs": drafts.documentTabs.map(\.title), "dirty": drafts.documentTabs.map(\.dirty),
                "unseen": drafts.documentTabs.map(\.unseen), "activeTitle": drafts.activeOriginal?.title ?? "",
                "canRevert": drafts.canRevertReceived, "original": drafts.activeOriginal?.display ?? "",
                "associated": drafts.provenance?.selector ?? "",
            ]
            report(String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self))
        case "browse": drafts.browsing = pieces.last == "on"; report("ok")
        case "flush": drafts.flush(); report("ok")
        case "play":
            // What either play button would hand to synthesis. Nothing is synthesized here.
            drafts.confirmSpeech()
            let both = [drafts.playback(), drafts.playback(displayOnly: true)].map { $0.map { [$0.display, $0.speech] } ?? [] }
            report(String(decoding: try! JSONSerialization.data(withJSONObject: both), as: UTF8.self))
        case "end": drafts.flush(); access.stopPairing(); report("ok"); exit(0)
        default: exit(2)
        }
    }
}

@main struct LocalExplanationDraftSocketProbe {
    @MainActor static func main() {
        let fixture = AgentFixture(directory: CommandLine.arguments[1],
                                   expectedHelper: CommandLine.arguments.dropFirst(2).first ?? "helper",
                                   wait: .milliseconds(Int64(CommandLine.arguments.dropFirst(3).first ?? "90000") ?? 90000),
                                   trust: CommandLine.arguments.dropFirst(4).first ?? "agent-clients-\(UUID()).json",
                                   database: CommandLine.arguments.dropFirst(5).first)
        print("ready"); fflush(stdout)
        DispatchQueue.global().async {
            while let cmd = readLine() { DispatchQueue.main.async { fixture.command(cmd) } }
            DispatchQueue.main.async { fixture.command("end") }
        }
        dispatchMain()
    }
}

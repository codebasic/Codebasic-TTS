import AppKit
import Darwin
import Foundation
import ObjectiveC

@MainActor enum ApprovalUIProbe {
    static var responses: [(NSAlert) -> NSApplication.ModalResponse] = []
    static let instruction = String(repeating: "합성 지시: as_frame은 애즈 프레임으로 한 번 읽습니다.\n", count: 35)
        + "SYNTHETIC: caf\u{00E9}\n"
    static var canonicallyEquivalent: String {
        instruction.replacingOccurrences(of: "caf\u{00E9}", with: "cafe\u{0301}")
    }
    static let hint = "NONSHARED_SYNTHETIC_HINT"
    static let glossary = "NONSHARED_SYNTHETIC_GLOSSARY"

    static func interceptDialogs() {
        guard let system = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.runModal)),
              let fake = class_getInstanceMethod(NSAlert.self, #selector(NSAlert.cbttsFixtureModal)) else {
            preconditionFailure("NSAlert method unavailable")
        }
        method_exchangeImplementations(system, fake)
    }

    static func selectProfile(_ alert: NSAlert, index: Int = 2) -> NSApplication.ModalResponse {
        precondition(alert.messageText == "로컬 MCP 지시 공유 (이번 실행)")
        precondition(alert.buttons.map(\.title) == ["미리 보기", "취소"])
        let fields = alert.accessoryView?.subviews ?? []
        guard let pid = fields.first(where: { $0 is NSTextField }) as? NSTextField,
              let profile = fields.first(where: { $0 is NSPopUpButton }) as? NSPopUpButton else {
            preconditionFailure("Missing process and profile fields")
        }
        pid.stringValue = String(getpid())
        profile.selectItem(at: index)
        return .alertFirstButtonReturn
    }

    static func verifyPreview(_ alert: NSAlert, expected: String? = nil) {
        precondition(alert.messageText.contains(String(getpid())))
        precondition(alert.informativeText.contains("최대 10분") && alert.informativeText.contains("원격 모델"))
        precondition(alert.buttons.map(\.title) == ["이 프로필만 공유", "취소"])
        guard let scroll = alert.accessoryView as? NSScrollView,
              let view = scroll.documentView as? NSTextView else { preconditionFailure("Missing native preview") }
        precondition(scroll.hasVerticalScroller)
        precondition(!view.isEditable && !view.isRichText)
        precondition(view.string.utf8.elementsEqual((expected ?? instruction).utf8))
        precondition(!view.string.contains(hint) && !view.string.contains(glossary))
    }
}

extension NSAlert {
    @MainActor @objc func cbttsFixtureModal() -> Int {
        guard !ApprovalUIProbe.responses.isEmpty else { preconditionFailure("Unexpected alert; native window must never be shown") }
        return ApprovalUIProbe.responses.removeFirst()(self).rawValue
    }
}

@main struct TestInstructionApprovalUI {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        ApprovalUIProbe.interceptDialogs()
        let delegate = AppDelegate()
        delegate.appState.normalizePrompt = ApprovalUIProbe.instruction
        delegate.appState.scriptHint = ApprovalUIProbe.hint
        delegate.appState.glossary = [GlossaryEntry(term: "as_frame", pronunciation: ApprovalUIProbe.glossary)]
        delegate.syntheticInstructionFixtureSetUp()
        let directory = ProcessInfo.processInfo.environment["TTS_APPROVAL_FIXTURE_ROOT"]!
        let socket = directory + "/i.sock"
        guard let item = application.mainMenu?.items.first?.submenu?.item(withTitle: "로컬 MCP 지시 공유 (이번 실행)…"),
              let action = item.action else { preconditionFailure("Production menu action not installed") }

        func click(_ responses: [(NSAlert) -> NSApplication.ModalResponse]) {
            ApprovalUIProbe.responses = responses
            precondition(application.sendAction(action, to: item.target, from: item))
            precondition(ApprovalUIProbe.responses.isEmpty)
            precondition(application.windows.allSatisfy { !$0.isVisible })
        }
        func assertOff() {
            precondition(item.state == .off)
            precondition(!FileManager.default.fileExists(atPath: socket))
        }
        func assertOn() {
            precondition(item.state == .on)
            var meta = stat()
            precondition(lstat(socket, &meta) == 0 && meta.st_mode & S_IFMT == S_IFSOCK && meta.st_mode & 0o777 == 0o600)
        }
        let choice: (NSAlert) -> NSApplication.ModalResponse = { ApprovalUIProbe.selectProfile($0) }
        let confirm: (NSAlert) -> NSApplication.ModalResponse = { alert in
            ApprovalUIProbe.verifyPreview(alert)
            return .alertFirstButtonReturn
        }

        assertOff()
        click([{ alert in
            precondition(alert.buttons.map(\.title) == ["미리 보기", "취소"])
            return .alertSecondButtonReturn
        }]); assertOff()
        click([choice, { alert in
            ApprovalUIProbe.verifyPreview(alert)
            return .alertSecondButtonReturn
        }]); assertOff()
        print("selection-cancel and exact-preview-cancel kept sharing off; excluded hint/glossary")

        click([choice, { alert in
            ApprovalUIProbe.verifyPreview(alert)
            delegate.appState.normalizePrompt += "SYNTHETIC EDIT WHILE PREVIEWED"
            return .alertFirstButtonReturn
        }, { alert in
            precondition(alert.informativeText.contains("미리 보는 동안 지시가 바뀌었습니다"))
            return .alertFirstButtonReturn
        }]); assertOff()
        delegate.appState.normalizePrompt = ApprovalUIProbe.instruction
        click([choice, { alert in
            ApprovalUIProbe.verifyPreview(alert)
            delegate.appState.normalizePrompt += "edited then reverted"
            delegate.appState.normalizePrompt = ApprovalUIProbe.instruction
            return .alertFirstButtonReturn
        }, { alert in
            precondition(alert.informativeText.contains("미리 보는 동안 지시가 바뀌었습니다"))
            return .alertFirstButtonReturn
        }]); assertOff()
        click([choice, confirm]); assertOn()
        delegate.appState.normalizePrompt = ApprovalUIProbe.instruction
        assertOn() // a true byte-identical assignment is not a change
        let canonicalEdit = ApprovalUIProbe.canonicallyEquivalent
        precondition(canonicalEdit == ApprovalUIProbe.instruction)
        precondition(!canonicalEdit.utf8.elementsEqual(ApprovalUIProbe.instruction.utf8))
        delegate.appState.normalizePrompt = canonicalEdit
        assertOff()
        delegate.appState.normalizePrompt = ApprovalUIProbe.instruction
        assertOff() // undoing the edit never restores consent
        click([choice, confirm]); assertOn()
        click([]); assertOff()
        let custom = "합성 사용자 해설 e\u{301}\n"
        delegate.appState.explainPrompt = custom
        let effective = CodeExplanation.effectiveInstruction(custom)
        for (index, key, expected) in [(0, "explain", effective),
                                        (1, "continue", effective + "\n\n" + CodeExplanation.continueInstruction)] {
            let original = delegate.appState.agentSnapshot(key)!
            precondition(original.text.utf8.elementsEqual(expected.utf8))
            click([{ ApprovalUIProbe.selectProfile($0, index: index) }, { alert in
                ApprovalUIProbe.verifyPreview(alert, expected: expected)
                return .alertFirstButtonReturn
            }]); assertOn()
            delegate.appState.explainPrompt += "changed"
            assertOff()
            delegate.appState.explainPrompt = custom
            precondition(delegate.appState.agentSnapshot(key)?.generation != original.generation)
            assertOff()
        }
        click([choice, confirm]); assertOn()
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification, object: application))
        assertOff()
        print("stale preview denied; exact customized explain/continue/normalize presets and edit/revert revocation passed; menu revoke and termination removed socket")

        guard let receipt = application.mainMenu?.items.first?.submenu?.item(withTitle: "외부 대본 받기 허용 (이번 실행)…"),
              let receiptAction = receipt.action else { preconditionFailure("Missing separate receipt consent") }
        let dSocket = directory + "/d.sock"
        func receiptClick(_ responses: [(NSAlert) -> NSApplication.ModalResponse]) {
            ApprovalUIProbe.responses = responses
            precondition(application.sendAction(receiptAction, to: receipt.target, from: receipt))
            precondition(ApprovalUIProbe.responses.isEmpty)
            precondition(application.windows.allSatisfy { !$0.isVisible })
        }
        func assertDraftOff() {
            precondition(receipt.state == .off && delegate.appState.explanationDrafts.receiverPID == nil)
            precondition(!FileManager.default.fileExists(atPath: dSocket))
        }
        assertDraftOff()
        receiptClick([{ alert in
            precondition(alert.informativeText.contains("서명된 도우미를 먼저 연결"))
            return .alertFirstButtonReturn
        }])
        assertDraftOff(); assertOff()
        print("unpaired receipt explicitly rejected; signed grant behavior is covered by the round-trip fixture")
    }
}

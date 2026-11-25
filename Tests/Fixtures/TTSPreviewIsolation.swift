import AppKit
import Foundation

@main struct TTSPreviewIsolation {
    @MainActor static func main() async throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let home = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let production = home.appendingPathComponent("Library/Application Support/Codebasic TTS")
        let preview = TTSRuntime.applicationSupport(home: home)
        let installedKey = production.appendingPathComponent("eleven_key")
        let endpointID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
        let fm = FileManager.default

        precondition(TTSRuntime.isPreview && TTSRuntime.appID == TTSRuntime.productionAppID + ".preview")
        precondition(TTSRuntime.helperID == TTSRuntime.appID + ".agent-helper" && Log.subsystem == TTSRuntime.appID)
        precondition(TTSRuntime.socketDirectory(uid: 501) == "/private/tmp/codebasic-tts-preview-mcp-501")
        precondition(LocalApprovedSocket.defaultDirectory == TTSRuntime.socketDirectory)
        precondition(preview.path == Secrets.appSupportDir && preview.path == production.path + " Preview")
        precondition(!fm.fileExists(atPath: preview.path))

        let delegate = AppDelegate()
        let app = delegate.appState
        delegate.syntheticPreviewMenu()
        let menu = application.mainMenu?.items.first?.submenu
        precondition(menu?.title == TTSRuntime.displayName)
        precondition(menu?.item(withTitle: "외부 대본 받기 허용 (이번 실행)") != nil)
        precondition(menu?.item(withTitle: "로컬 MCP 음성 입력 허용 (이번 실행)") == nil)
        precondition(menu?.item(withTitle: "로컬 MCP 지시 공유 (이번 실행)…") == nil)
        precondition(menu?.item(withTitle: "설정…") == nil)
        precondition(application.servicesProvider == nil)
        precondition(application.windows.allSatisfy { !$0.isVisible })

        precondition(!app.keyPresent && app.voiceName != "SYNTHETIC PRODUCTION VOICE")
        precondition(Secrets.elevenLabsKey == nil && Secrets.endpointKey(endpointID) == nil)
        precondition(app.agentCatalog.records.isEmpty)
        Secrets.writeKey(named: "eleven_key", "synthetic-preview-key")
        Secrets.writeEndpointKey(endpointID, "synthetic-preview-endpoint")
        app.voiceName = "synthetic preview voice"
        app.saveSettings()
        try app.agentCatalog.save(label: "합성 프리뷰 지시", body: "프리뷰에만 보관")
        precondition(Secrets.elevenLabsKey == "synthetic-preview-key")
        precondition(Secrets.endpointKey(endpointID) == "synthetic-preview-endpoint")
        for relative in ["settings.json", "cache/history.sqlite", "agent-instructions-v1.json", endpointID.uuidString + ".key"] {
            precondition(fm.fileExists(atPath: preview.appendingPathComponent(relative).path), relative)
        }
        let untouchedKey = try String(contentsOf: installedKey, encoding: .utf8)
        precondition(untouchedKey == "synthetic-production-key")

        let blockedHome = preview.appendingPathComponent("must-not-create")
        let pretendCLI = URL(fileURLWithPath: "/usr/bin/true")
        do {
            _ = try CodexPlanRPC(executable: pretendCLI, home: blockedHome)
            preconditionFailure("Preview must not start Codex")
        } catch { precondition(error.localizedDescription.contains("프리뷰")) }
        do {
            try AntigravityPlan.login()
            preconditionFailure("Preview must not open Google login")
        } catch { precondition(error.localizedDescription.contains("프리뷰")) }
        do {
            _ = try await AntigravityPlan.run(arguments: [], executable: pretendCLI, home: blockedHome)
            preconditionFailure("Preview must not start Antigravity")
        } catch { precondition(error.localizedDescription.contains("프리뷰")) }
        precondition(!fm.fileExists(atPath: blockedHome.path))
        precondition(AntigravityPlan.home.deletingLastPathComponent().path == preview.path)

        let draft = ExplanationDraft(id: "preview-fixture", display: "합성 프리뷰 대본", speech: nil)!
        precondition(app.explanationDrafts.receiveDocument(draft) == .accepted)
        app.playExplanationDraft()
        precondition(app.phase == .idle && app.currentText.isEmpty)
        print("preview data, settings, keys, and SQLite stay in the preview profile; credentials and TTS remain inactive")
        print("preview menu has receipt, excludes legacy integrations, and opens no visible window")
    }
}

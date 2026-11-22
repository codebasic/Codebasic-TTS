import Foundation

@main struct AgentMCPConfigurationTests {
    static func main() throws {
        let productionID = "com.seongjoo.SelectedTextTTS"
        let path = "/Applications/예시 앱 \"따옴표\" O'Brian \\ 빌드.app/Contents/Helpers/CodebasicAgentMCP"
        let config = AgentMCPConfiguration(command: path, bundleID: productionID)!
        precondition(config.serverName == "codebasic_tts_agent")
        let review = AgentMCPConfiguration(command: path, bundleID: "test.preview")!
        precondition(review.serverName.hasPrefix("codebasic_tts_preview_") && review.serverName != config.serverName)
        precondition(review.serverName != AgentMCPConfiguration(command: path, bundleID: "test.preview2")!.serverName)
        precondition(AgentMCPConfiguration(command: "relative", bundleID: productionID) == nil)
        precondition(AgentMCPConfiguration(command: "/invalid\0path", bundleID: productionID) == nil)
        precondition(config.codexTOML.contains("O'Brian"))
        precondition(config.claudeCodeCommand!.contains("O'\\''Brian"))
        precondition(AgentMCPConfiguration.bundled(in: .main) == nil)

        let tested: AgentMCPConfiguration
        if CommandLine.arguments.count == 2 {
            guard let bundle = Bundle(path: CommandLine.arguments[1]),
                  let bundled = AgentMCPConfiguration.bundled(in: bundle) else {
                throw CocoaError(.fileNoSuchFile)
            }
            precondition(bundled.command == bundle.bundleURL.appendingPathComponent("Contents/Helpers/CodebasicAgentMCP").path)
            tested = bundled
        } else { tested = config }
        let result = ["toml": tested.codexTOML, "shell": tested.claudeCodeCommand!,
                      "name": tested.serverName, "path": tested.command]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self))
    }
}

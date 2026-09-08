import Foundation

@main struct ConnectionTests {
    @MainActor static func main() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tts-rpc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let client = try CodexPlanRPC(executable: fixture, home: home)
        defer { client.stop() }
        try await client.initialize()
        let result = try await client.request("echo", ["text": "한국어\nstream"])
        precondition(result["text"] as? String == "한국어\nstream")
        print("✓ RPC handles fragmented JSON and Unicode")
        do {
            _ = try await client.requirePlan()
            fatalError("API authentication must not count as a plan")
        } catch { print("✓ API authentication rejected for plan mode") }
        do {
            _ = try await client.request("unsupported")
            fatalError("RPC errors must surface")
        } catch { print("✓ RPC error propagated") }
        client.stop()
        do {
            _ = try await client.request("echo")
            fatalError("Closed connection must fail")
        } catch { print("✓ Closed connection fails immediately") }
        try AntigravityPlan.prepare(home: home)
        let env = AntigravityPlan.environment(home: home)
        precondition(env["GEMINI_API_KEY"] == nil && env["GOOGLE_API_KEY"] == nil && env["GEMINI_CLI_HOME"] == nil)
        let fixtureAGY = fixture.deletingLastPathComponent().appendingPathComponent("fake-agy.py")
        let models = try await AntigravityPlan.models(executable: fixtureAGY, home: home)
        precondition(models == ["gemini-test-high"])
        var generated = ""
        for try await chunk in AntigravityPlan.stream(prompt: "한국어 @/tmp/file", model: "auto", images: [], executable: fixtureAGY, home: home) {
            generated += chunk
            try Data().write(to: home.appendingPathComponent("first-delta-seen"))
        }
        precondition(generated == "한국어 @/tmp/file")
        for status in ["ERROR", "CANCELED", "INTERRUPTED", "WAITING", "RUNNING", "INVALID"] {
            let data = try JSONSerialization.data(withJSONObject: ["event": "result", "result": ["status": status, "response": "partial"]])
            do { _ = try AntigravityPlan.decodeResponse(data, exitCode: 0); fatalError("Failed result accepted") } catch { }
        }
        do { _ = try AntigravityPlan.decodeResponse(Data("{}".utf8), exitCode: 0); fatalError("Missing result accepted") } catch { }
        do {
            for try await _ in AntigravityPlan.stream(prompt: "image", model: "auto", images: [Data()], executable: fixtureAGY, home: home) { }
            fatalError("Unsupported image silently accepted")
        } catch { }
        print("✓ First delta delivered before CLI exit; final response not duplicated")
        print("✓ Antigravity model lookup and structured stdin subprocess round trip")
        print("✓ API/credit fallback disabled; non-success responses and images rejected")
        print("Connection tests passed.")
    }
}

import Foundation
final class GeminiMockProtocol: URLProtocol {
    static var captured: [String: Any] = [:]
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let body = request.httpBody { Self.captured = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:] }
        else if let stream = request.httpBodyStream {
            stream.open(); var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; stream.close()
            Self.captured = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let sse = "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"synthetic response\"}]}}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":2,\"totalTokenCount\":3}}\n\n"
        client?.urlProtocol(self, didLoad: Data(sse.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct GeminiMockTests {
    static func main() async throws {
        URLProtocol.registerClass(GeminiMockProtocol.self)
        let endpoint = CustomEndpoint(name: "synthetic", baseURL: "https://generativelanguage.googleapis.com/v1beta", apiStyle: .gemini)
        let generator = EndpointGenerator(endpoint: endpoint, apiKey: "synthetic-key-not-a-credential", model: "gemini-flash-lite-latest", instruction: "", temperature: 0.2, reasoningLevel: .medium)
        var output = ""
        for try await part in generator.generate("", conversation: ExplanationConversation(system: "synthetic system", messages: [ConversationMessage(role: .user, text: "synthetic input")])) { output += part }
        precondition(output == "synthetic response")
        precondition((GeminiMockProtocol.captured["generationConfig"] as? [String: Any])?["maxOutputTokens"] as? Int == 64)
        precondition((GeminiMockProtocol.captured["contents"] as? [[String: Any]])?.count == 1)
        print("PASS: Gemini production streaming transport uses 64-token validation cap and provider-neutral conversation; URLProtocol mock only")
    }
}

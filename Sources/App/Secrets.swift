import Foundation

/// API key access. MVP reads a plaintext key file from Application Support
/// (user-readable only); build.sh installs it there from Sidecar/.eleven_key.
/// Keychain hardening is a later milestone.
enum Secrets {
    static let appSupportDir = V2Runtime.dataRoot

    static var elevenLabsKey: String? { key(named: "eleven_key") }
    static var geminiKey: String? { key(named: "gemini_key") }
    static var zaiKey: String? { key(named: "zai_key") }

    static func key(named name: String) -> String? {
        guard !V2Runtime.offline else { return nil }
        let path = (appSupportDir as NSString).appendingPathComponent(name)
        let legacy = ("~/Library/Application Support/Codebasic TTS" as NSString).expandingTildeInPath
        let reuse = FileManager.default.fileExists(atPath: appSupportDir + "/reuse-v1-credentials")
        // Explicit opt-in, read-only fallback. Writes always remain in V2.
        guard let raw = (try? String(contentsOfFile: path, encoding: .utf8))
            ?? (reuse ? try? String(contentsOfFile: legacy + "/" + name, encoding: .utf8) : nil) else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func writeKey(named name: String, _ value: String) {
        try? FileManager.default.createDirectory(atPath: appSupportDir, withIntermediateDirectories: true)
        let path = (appSupportDir as NSString).appendingPathComponent(name)
        try? value.write(toFile: path, atomically: true, encoding: .utf8)
    }

    // Custom endpoints keep their key in its own file named after the endpoint
    // id (`<endpoint_id>.key`), never inside settings.json.
    static func endpointKey(_ id: UUID) -> String? { key(named: id.uuidString + ".key") }
    static func writeEndpointKey(_ id: UUID, _ value: String) { writeKey(named: id.uuidString + ".key", value) }
}

/// Explicit test-only runtime. Activation precedes AppState construction.
enum V2Runtime {
    static let offline = ProcessInfo.processInfo.environment["CODEBASIC_V2_OFFLINE"] == "1"
    static let dataRoot: String = {
        if offline {
            let path = ProcessInfo.processInfo.environment["CODEBASIC_V2_TEST_ROOT"] ?? "/tmp/codebasic-v2-offline"
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            precondition(resolved.hasPrefix("/private/tmp/") || resolved.hasPrefix("/tmp/"), "Offline test root must be inside /tmp")
            return resolved
        }
        return ("~/Library/Application Support/Codebasic TTS V2" as NSString).expandingTildeInPath
    }()
    static func installOfflineNetworkBlock() {
        if offline { URLProtocol.registerClass(V2OfflineURLProtocol.self) }
    }
    static func mockStream(_ conversation: ExplanationConversation) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let cancelling = conversation.messages.last?.text.contains("취소") == true
                let parts = cancelling ? Array(repeating: "취소 검증용 느린 mock 응답입니다. ", count: 150)
                    : ["MOCK 응답입니다. ", "Gemini 모델 선택과 ", "대화 문맥 전달을 유지합니다. ", "이미지 첨부 \(conversation.messages.last?.images.count ?? 0)개를 받았습니다. ", "실제 API와 음성 장치는 사용하지 않았습니다."]
                do {
                    for part in parts { try await Task.sleep(nanoseconds: 250_000_000); try Task.checkCancellation(); continuation.yield(part) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
private final class V2OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

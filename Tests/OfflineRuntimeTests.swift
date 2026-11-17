import Foundation
@main struct OfflineRuntimeTests {
    static func main() async throws {
        precondition(V2Runtime.offline)
        let root = URL(fileURLWithPath: V2Runtime.dataRoot)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("synthetic-only".utf8).write(to: root.appendingPathComponent("probe.key"))
        precondition(Secrets.key(named: "probe.key") == nil, "offline never reads credentials")
        V2Runtime.installOfflineNetworkBlock()
        do {
            _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:1/offline-block-probe")!)
            fatalError("offline request unexpectedly succeeded")
        } catch {
            precondition((error as NSError).code == URLError.notConnectedToInternet.rawValue, "URLProtocol must intercept before any connection")
        }
        print("PASS: offline isolated path, credential refusal and URLSession network interception")
    }
}

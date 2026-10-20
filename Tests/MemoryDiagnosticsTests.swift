import Foundation

@main
struct MemoryDiagnosticsTests {
    static func main() async {
        // Repeated concurrent scopes must not leave entries in the registry.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<500 {
                group.addTask {
                    let id = MemoryDiagnostics.begin("test.concurrent")
                    defer { MemoryDiagnostics.end(id) }
                    MemoryDiagnostics.update(id, values: ["testBytes": 32])
                }
            }
        }
        precondition(!MemoryDiagnostics.activitySummary.contains("test.concurrent"))
        precondition(!MemoryDiagnostics.activitySummary.contains("testBytes"))
        let task = Task {
            let id = MemoryDiagnostics.begin("test.cancel")
            defer { MemoryDiagnostics.end(id) }
            try? await Task.sleep(for: .seconds(30))
        }
        task.cancel()
        await task.value
        precondition(!MemoryDiagnostics.activitySummary.contains("test.cancel"))
        MemoryDiagnostics.sample("selftest", details: "payloadBytes=0")
        print("Memory diagnostics concurrency and cancellation tests passed.")
    }
}

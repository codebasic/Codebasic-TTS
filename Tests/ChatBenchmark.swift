import Foundation
import Darwin

struct FixtureArchive: Codable { var version = 1; var threads: [FixtureThread] }
struct FixtureThread: Codable { var id: UUID; var title: String; var createdAt: Date; var messages: [FixtureMessage] }
struct FixtureMessage: Codable { var message: ChatMessage; var attachments: [String] }

@main struct Benchmark {
    static func milliseconds(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }
    static func rss() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4, args[2].hasPrefix("/tmp/") else { fatalError("usage: benchmark prepare|run /tmp/directory threadCount [imageCount]") }
        let root = URL(fileURLWithPath: args[2]); let threads = Int(args[3])!
        if args[1] == "prepare" {
            let count = args.count > 4 ? Int(args[4])! : 80
            let attachments = root.appendingPathComponent("chat/attachments")
            try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
            let image = try Data(contentsOf: URL(fileURLWithPath: args.count > 5 ? args[5] : "/tmp/codebasic-v2-benchmark-image.png"))
            var records: [FixtureThread] = []
            for i in 0..<threads {
                var messages: [FixtureMessage] = []
                for j in 0..<20 {
                    let text = "Synthetic thread \(i) turn \(j). " + String(repeating: "synthetic text ", count: 34)
                    let message = ChatMessage(role: j % 2 == 0 ? .user : .assistant, text: text, createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i*20+j)), provider: "MOCK Google", model: "gemini-flash-lite-latest (synthetic)")
                    var names: [String] = []
                    if j == 0 && i < count {
                        let name = message.id.uuidString + "-0.png"; names = [name]
                        try image.write(to: attachments.appendingPathComponent(name), options: .atomic)
                    }
                    messages.append(FixtureMessage(message: message, attachments: names))
                }
                records.append(FixtureThread(id: UUID(), title: String(format: "Synthetic conversation %04d", i), createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), messages: messages))
            }
            let data = try JSONEncoder().encode(FixtureArchive(threads: records))
            try data.write(to: root.appendingPathComponent("chat/conversations.json"), options: .atomic)
            print("fixture threads=\(threads) messages=\(threads*20) json_bytes=\(data.count) images=\(min(threads,count)) image_bytes_each=\(image.count) total_image_bytes=\(min(threads,count)*image.count)")
            return
        }
        let initialRSS = rss()
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let session = ChatSession(root: root.appendingPathComponent("chat"))
        let loadMS = milliseconds(loadStart); let loadedRSS = rss()
        guard session.threads.count >= threads, session.error.isEmpty else { fatalError("fixture failed to restore: " + session.error) }
        let loadedThreadCount = session.threads.count
        let loadedMessageCount = session.threads.reduce(0) { $0 + $1.messages.count }
        let newStart = DispatchTime.now().uptimeNanoseconds
        session.newThread(); let newMS = milliseconds(newStart)
        var maxGap: Double = 0; var tickCount = 0
        let ticker = Task { @MainActor in
            var previous = DispatchTime.now().uptimeNanoseconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000)
                let now = DispatchTime.now().uptimeNanoseconds
                maxGap = max(maxGap, Double(now-previous)/1_000_000); previous = now; tickCount += 1
            }
        }
        await Task.yield()
        let sendStart = DispatchTime.now().uptimeNanoseconds
        _ = session.send(text: "synthetic benchmark input", images: [], provider: "mock", model: "mock", system: "offline", generate: { _ in
            AsyncThrowingStream { continuation in
                let producer = Task {
                    for _ in 0..<120 { continuation.yield("A short synthetic streamed chunk. "); try? await Task.sleep(nanoseconds: 10_000_000) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in producer.cancel() }
            }
        })
        let sendMS = milliseconds(sendStart)
        while session.generating { try? await Task.sleep(nanoseconds: 1_000_000) }
        try? await Task.sleep(nanoseconds: 5_000_000); ticker.cancel()
        let streamMS = milliseconds(sendStart)
        let flushStart = DispatchTime.now().uptimeNanoseconds
        session.shutdown(); let flushMS = milliseconds(flushStart)
        let finalRSS = rss()
        let output: [String: Any] = ["threads_before": loadedThreadCount, "messages_before": loadedMessageCount, "load_ms": loadMS, "new_thread_ms": newMS, "send_flush_ms": sendMS, "stream_wall_ms": streamMS, "shutdown_flush_ms": flushMS, "main_actor_max_tick_gap_ms": maxGap, "main_actor_ticks": tickCount, "rss_before_bytes": initialRSS, "rss_loaded_bytes": loadedRSS, "rss_final_bytes": finalRSS, "metadata_writes": session.storageWriteCount, "new_attachment_writes": session.attachmentWriteCount, "final_state": session.current?.messages.last?.state ?? "missing"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}

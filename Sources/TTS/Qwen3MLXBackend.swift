import Foundation

/// Local TTS backend: talks to the Python `mlx-audio` sidecar (see Sidecar/server.py)
/// over 127.0.0.1. The sidecar loads Qwen3-TTS once and clones from a reference
/// recording.
///
/// M5 will: (a) launch/supervise the sidecar process from the app, and (b) switch
/// the endpoint to chunked streaming for low latency. For now `stream()` performs
/// a single request and emits the whole WAV as one chunk — enough for A/B
/// listening against ElevenLabs behind the shared `TTSBackend` protocol.
struct Qwen3MLXBackend: TTSBackend {
    let identity: String
    let baseURL: URL

    init(identity: String = "qwen3-1.7b-6bit",
         baseURL: URL = URL(string: "http://127.0.0.1:8765")!) {
        self.identity = identity
        self.baseURL = baseURL
    }

    func stream(segment: String, voice: VoiceConfig) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("tts"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["text": segment])

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw URLError(.badServerResponse)
                    }
                    var buffer = Data()
                    for try await byte in bytes { buffer.append(byte) }
                    continuation.yield(buffer)      // whole WAV (single chunk for now)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

import Foundation

/// Cloud TTS backend: ElevenLabs HTTP API. The app calls this directly (no
/// sidecar — that's only for the local MLX engine). ElevenLabs renders the whole
/// text server-side, so it doesn't have the local model's end-clipping issues.
struct ElevenLabsBackend: TTSBackend {
    let identity = "elevenlabs"
    let apiKey: String

    /// Synthesize `segment` and emit the (mp3) audio. For now the full response
    /// is collected and yielded as one chunk; the caller plays it. `voice`
    /// carries the ElevenLabs voiceId + modelId.
    func stream(segment: String, voice: VoiceConfig) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let url = URL(string:
                        "https://api.elevenlabs.io/v1/text-to-speech/\(voice.voiceId)/stream"
                        + "?output_format=mp3_44100_128")!
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: [
                        "text": segment,
                        "model_id": voice.modelId,
                    ])

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }
                    var buffer = Data()
                    for try await byte in bytes { buffer.append(byte) }
                    guard http.statusCode == 200 else {
                        let msg = String(data: buffer, encoding: .utf8) ?? "<binary>"
                        throw NSError(domain: "ElevenLabs", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: msg])
                    }
                    continuation.yield(buffer)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

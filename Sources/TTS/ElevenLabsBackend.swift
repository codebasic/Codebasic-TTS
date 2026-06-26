import Foundation

/// ElevenLabs voice tuning (sent as `voice_settings`).
struct ElevenVoiceSettings: Equatable {
    var stability: Double = 0.5
    var similarityBoost: Double = 0.75
    var style: Double = 0.0
    var useSpeakerBoost: Bool = true

    var json: [String: Any] {
        ["stability": stability, "similarity_boost": similarityBoost,
         "style": style, "use_speaker_boost": useSpeakerBoost]
    }
    /// Stable hash for the cache key.
    var hash: String {
        String(format: "s%.2f-sim%.2f-st%.2f-sb%d",
               stability, similarityBoost, style, useSpeakerBoost ? 1 : 0)
    }
}

/// A voice from the user's ElevenLabs account.
struct ElevenVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let category: String   // "cloned" / "premade" / ...
}

/// Cloud TTS backend: ElevenLabs HTTP API. The app calls this directly (no
/// sidecar — that's only for the local MLX engine). ElevenLabs renders the whole
/// text server-side, so it doesn't have the local model's end-clipping issues.
struct ElevenLabsBackend: TTSBackend {
    let identity = "elevenlabs"
    let apiKey: String
    var settings: ElevenVoiceSettings? = nil

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
                    var body: [String: Any] = ["text": segment, "model_id": voice.modelId]
                    if let s = settings { body["voice_settings"] = s.json }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

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

/// Stateless ElevenLabs API helpers used by the UI.
enum ElevenLabs {
    static func voices(apiKey: String) async throws -> [ElevenVoice] {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "request failed"
            throw NSError(domain: "ElevenLabs", code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                          userInfo: [NSLocalizedDescriptionKey: msg])
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let arr = (obj?["voices"] as? [[String: Any]]) ?? []
        return arr.map {
            ElevenVoice(id: $0["voice_id"] as? String ?? "",
                        name: $0["name"] as? String ?? "(unnamed)",
                        category: $0["category"] as? String ?? "")
        }
    }

    /// Korean-capable models, newest/most useful first.
    static let koreanModels: [(id: String, label: String)] = [
        ("eleven_flash_v2_5", "Flash v2.5 (저지연)"),
        ("eleven_multilingual_v2", "Multilingual v2 (품질)"),
        ("eleven_turbo_v2_5", "Turbo v2.5"),
        ("eleven_v3", "v3 (표현력)"),
    ]
}

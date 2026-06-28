import Foundation

/// Voice/model parameters that participate in the cache key.
struct VoiceConfig {
    let voiceId: String
    let modelId: String
    /// Serialized hash of engine-specific settings (e.g. stability/similarity).
    let settingsHash: String
}

/// Pluggable TTS engine. Implementations are swapped at runtime so the same
/// segment can be A/B'd across ElevenLabs (cloud) and Qwen3-TTS (local).
///
/// `identity` is folded into the cache key namespace, so switching engines (or
/// model/voice) never mixes cached audio across backends.
protocol TTSBackend {
    /// Backend identifier baked into the cache key (e.g. "elevenlabs",
    /// "qwen3-1.7b-4bit").
    var identity: String { get }

    /// Synthesize a segment, emitting audio chunks as a stream. The caller
    /// starts playback on the first chunk and simultaneously persists the
    /// accumulating bytes to the cache file.
    func stream(segment: String, voice: VoiceConfig) -> AsyncThrowingStream<Data, Error>

    /// Synthesize a segment returning the audio plus per-character start times
    /// (seconds), for exact subtitle sync. Returns nil if the engine doesn't
    /// provide timing (caller falls back to `stream` + estimation).
    func synthesizeTimed(segment: String, voice: VoiceConfig) async throws -> (data: Data, charStarts: [Double])?
}

extension TTSBackend {
    func synthesizeTimed(segment: String, voice: VoiceConfig) async throws -> (data: Data, charStarts: [Double])? { nil }
}

/// M1 placeholder: produces no audio, just proves the protocol compiles and the
/// app can hold a backend behind the abstraction. Real backends land in M2
/// (ElevenLabsBackend) and M5 (Qwen3MLXBackend).
struct StubBackend: TTSBackend {
    let identity = "stub"

    func stream(segment: String, voice: VoiceConfig) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Log.tts.info("StubBackend.stream called for \(segment.count) chars (no audio in M1)")
            continuation.finish()
        }
    }
}

import Foundation

/// Public model metadata only; never stores account credentials.
struct ElevenModel: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let canDoTextToSpeech: Bool
    let languages: [Language]
    let canUseStyle: Bool?
    let canUseSpeakerBoost: Bool?
    struct Language: Codable, Equatable {
        let languageId: String
        enum CodingKeys: String, CodingKey { case languageId = "language_id" }
    }
    enum CodingKeys: String, CodingKey {
        case canUseStyle = "can_use_style", canUseSpeakerBoost = "can_use_speaker_boost"
        case id = "model_id", name, canDoTextToSpeech = "can_do_text_to_speech", languages
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? id
        canDoTextToSpeech = try values.decodeIfPresent(Bool.self, forKey: .canDoTextToSpeech) ?? false
        languages = try values.decodeIfPresent([Language].self, forKey: .languages) ?? []
        canUseStyle = try values.decodeIfPresent(Bool.self, forKey: .canUseStyle)
        canUseSpeakerBoost = try values.decodeIfPresent(Bool.self, forKey: .canUseSpeakerBoost)
    }

    func voiceSettingsJSON(stability: Double, similarityBoost: Double, style: Double,
                           useSpeakerBoost: Bool) -> [String: Any] {
        var json: [String: Any] = ["stability": stability, "similarity_boost": similarityBoost]
        if canUseStyle == true { json["style"] = style }
        if canUseSpeakerBoost == true { json["use_speaker_boost"] = useSpeakerBoost }
        return json
    }
}

enum ElevenModelCatalog {
    static func koreanTTS(from data: Data) throws -> [ElevenModel] {
        let models = try JSONDecoder().decode([ElevenModel].self, from: data)
        var seen = Set<String>()
        let result = models.filter {
            $0.canDoTextToSpeech && !$0.id.isEmpty &&
            $0.languages.contains { $0.languageId == "ko" } && seen.insert($0.id).inserted
        }
        guard !result.isEmpty else {
            throw NSError(domain: "ElevenLabsModels", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "한국어 음성 합성 모델이 반환되지 않았습니다."])
        }
        return result
    }

    static func fetch(apiKey: String) async throws -> [ElevenModel] {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/models")!)
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            // Do not expose arbitrary response bodies (or authentication details) in the UI.
            throw NSError(domain: "ElevenLabsModels", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "모델 조회 실패 (HTTP \(status))"])
        }
        return try koreanTTS(from: data)
    }

    static func load(from url: URL) -> [ElevenModel] {
        guard let data = try? Data(contentsOf: url), let models = try? koreanTTS(from: data) else { return [] }
        return models
    }

    static func save(_ models: [ElevenModel], to url: URL) throws {
        let data = try JSONEncoder().encode(models)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

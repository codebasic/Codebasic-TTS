import Foundation
@main
struct ElevenModelCatalogTests {
    static func main() throws {
        let fixture = Data("""
        [
          {"model_id":"eleven_v4","name":"Eleven v4","can_do_text_to_speech":true,"languages":[{"language_id":"ko"}],"can_use_style":false,"can_use_speaker_boost":false},
          {"model_id":"metadata_optional"},
          {"model_id":"en","name":"English","can_do_text_to_speech":true,"languages":[{"language_id":"en"}]},
          {"model_id":"sts","name":"STS","can_do_text_to_speech":false,"languages":[{"language_id":"ko"}]},
          {"model_id":"eleven_v4","name":"Duplicate","can_do_text_to_speech":true,"languages":[{"language_id":"ko"}]}
        ]
        """.utf8)
        let models = try ElevenModelCatalog.koreanTTS(from: fixture)
        precondition(models.map(\.id) == ["eleven_v4"])
        let settings = models[0].voiceSettingsJSON(stability: 0.5, similarityBoost: 0.75, style: 0.8, useSpeakerBoost: true)
        precondition(settings["style"] == nil && settings["use_speaker_boost"] == nil)
        precondition(settings["stability"] as? Double == 0.5)
        for invalid in [Data("[]".utf8), Data("{}".utf8), Data("bad".utf8)] {
            do { _ = try ElevenModelCatalog.koreanTTS(from: invalid); fatalError("invalid catalog accepted") }
            catch { }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("models.json")
        precondition(ElevenModelCatalog.load(from: url).isEmpty)
        try ElevenModelCatalog.save(models, to: url)
        precondition(ElevenModelCatalog.load(from: url) == models)
        if CommandLine.arguments.count > 1 {
            let live = try ElevenModelCatalog.koreanTTS(from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            precondition(live.contains { $0.id == "eleven_v4" })
            precondition(live.contains { $0.id == "eleven_v4_turbo" })
            print("Actual API Korean TTS catalog: " + live.map { $0.id }.joined(separator: ", "))
        }
        print("ElevenLabs model parsing, capability filtering and cache tests passed.")
    }
}

import Foundation

/// One user-registered LLM endpoint (OpenAI 호환 / Gemini / Ollama). Endpoints
/// live in AppState.settings.json as an array.
///
/// There is deliberately NO apiKey property: the key lives only in its own
/// `App Support/<endpoint_id>.key` file (Secrets.endpointKey) and is read at
/// call time. Keeping it off the struct makes "settings.json never holds a
/// plaintext key" a property of the type instead of a scrub step someone has
/// to remember in saveSettings.
struct CustomEndpoint: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String            // 표시명 (예: "Z.ai", "내 vLLM")
    var baseURL: String         // 예: https://api.z.ai/api/coding/paas/v4
    var apiStyle: APIStyle      // .openAICompatible / .gemini / .ollama
    var isEnabled: Bool = true
    /// 역할별 모델 미지정 시 쓰는 엔드포인트 기본 모델 (구 zaiModel의 일반화).
    var defaultModel: String = ""

    enum APIStyle: String, Codable, CaseIterable, Identifiable {
        case openAICompatible, gemini, ollama
        var id: String { rawValue }
        var label: String {
            switch self {
            case .openAICompatible: return "OpenAI 호환"
            case .gemini: return "Gemini"
            case .ollama: return "Ollama"
            }
        }
    }

    /// Fixed ids for the 3 seeded endpoints the legacy gemini/zai/ollama fields
    /// migrate into. Deterministic so saved role references ("gemini" 등 legacy
    /// rawValue) map to the same endpoint on every machine, without storing an
    /// extra rawValue↔id table.
    static let geminiSeedID = UUID(uuidString: "A1B2C3D4-0001-4A11-8001-ABCDEF000001")!
    static let zaiSeedID = UUID(uuidString: "A1B2C3D4-0002-4A11-8002-ABCDEF000002")!
    static let ollamaSeedID = UUID(uuidString: "A1B2C3D4-0003-4A11-8003-ABCDEF000003")!
}

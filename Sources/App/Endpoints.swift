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
    // Optional fields preserve decoding of existing settings files.
    var provider: Provider? = nil
    var connection: Connection? = nil
    var connectionMethod: Connection { connection ?? .apiKey }
    var resolvedProvider: Provider {
        if let provider { return provider }
        switch apiStyle {
        case .gemini: return .google
        case .ollama: return .ollama
        case .anthropic: return .anthropic
        case .openAICompatible:
            return URL(string: baseURL)?.host == "api.openai.com" ? .openAI : .compatible
        }
    }
    var usesPlan: Bool { connectionMethod == .plan }
    var cacheIdentity: String {
        id.uuidString + "|" + connectionMethod.rawValue + "|" + apiStyle.rawValue + "|" + baseURL + (usesPlan && resolvedProvider == .google ? "|antigravity-v1" : "")
    }
    var connectionLabel: String {
        usesPlan ? (resolvedProvider == .google ? "Google 플랜" : "ChatGPT 플랜") : (resolvedProvider == .ollama ? "로컬 서버" : "API 키")
    }

    enum Connection: String, Codable, CaseIterable, Identifiable {
        case apiKey, plan
        var id: String { rawValue }
        var label: String { self == .plan ? "기존 플랜" : "API 키" }
    }
    enum Provider: String, Codable, CaseIterable, Identifiable {
        case openAI, anthropic, google, ollama, compatible
        var id: String { rawValue }
        var label: String {
            switch self {
            case .openAI: return "OpenAI"
            case .anthropic: return "Anthropic"
            case .google: return "Google"
            case .ollama: return "Ollama"
            case .compatible: return "OpenAI 호환"
            }
        }
        var supportsPlan: Bool { self == .openAI || self == .google }
        var apiStyle: APIStyle {
            switch self {
            case .openAI, .compatible: return .openAICompatible
            case .anthropic: return .anthropic
            case .google: return .gemini
            case .ollama: return .ollama
            }
        }
        var baseURL: String {
            switch self {
            case .openAI: return "https://api.openai.com/v1"
            case .anthropic: return "https://api.anthropic.com/v1"
            case .google: return "https://generativelanguage.googleapis.com/v1beta"
            case .ollama: return "http://localhost:11434"
            case .compatible: return ""
            }
        }
    }

    enum APIStyle: String, Codable, CaseIterable, Identifiable {
        case openAICompatible, gemini, ollama, anthropic
        var id: String { rawValue }
        var label: String {
            switch self {
            case .openAICompatible: return "OpenAI 호환"
            case .anthropic: return "Anthropic"
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

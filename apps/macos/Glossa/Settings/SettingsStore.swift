import Foundation
import Observation

enum ASREngine: String, CaseIterable, Identifiable {
    case whisper
    case qwen3Asr = "qwen3-asr"
    case funAsr = "fun-asr-realtime"
    case qwenAudio = "qwen-audio-3.1-asr-flash-streaming"
    case qwen3Flash = "qwen3-asr-flash-realtime"
    case gemini = "gemini-3.5-transcribe-live"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .whisper: "Whisper (local)"
        case .qwen3Asr: "Qwen3-ASR MLX (local)"
        case .funAsr: "Fun-ASR Realtime"
        case .qwenAudio: "Qwen Audio 3.1 Streaming"
        case .qwen3Flash: "Qwen3-ASR Flash Realtime"
        case .gemini: "Gemini 3.5 Transcribe Live"
        }
    }
}

enum TranslateLang: String, CaseIterable, Identifiable {
    case auto
    case en
    case zh
    case zhTW = "zh-TW"
    case ja
    case ko
    case fr
    case de
    case es
    case it
    case pt
    case ru
    case ar
    case hi
    case th
    case vi
    case id
    case nl
    case pl
    case tr
    case uk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: "Auto detect"
        case .en: "English"
        case .zh: "中文（简体）"
        case .zhTW: "中文（繁體）"
        case .ja: "日本語"
        case .ko: "한국어"
        case .fr: "Français"
        case .de: "Deutsch"
        case .es: "Español"
        case .it: "Italiano"
        case .pt: "Português"
        case .ru: "Русский"
        case .ar: "العربية"
        case .hi: "हिन्दी"
        case .th: "ไทย"
        case .vi: "Tiếng Việt"
        case .id: "Bahasa Indonesia"
        case .nl: "Nederlands"
        case .pl: "Polski"
        case .tr: "Türkçe"
        case .uk: "Українська"
        }
    }

    static var sources: [TranslateLang] { allCases }
    static var targets: [TranslateLang] { allCases.filter { $0 != .auto } }
}

enum TranslatorEngine: String, CaseIterable, Identifiable {
    case google
    case deepl
    case libretranslate
    case openaiCompatible = "openai-compatible"
    case ollama
    case lmstudio
    case qwen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: "Google"
        case .deepl: "DeepL"
        case .libretranslate: "LibreTranslate"
        case .openaiCompatible: "OpenAI-compatible"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        case .qwen: "Qwen (DashScope)"
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    static let shared = SettingsStore()
    private let d = UserDefaults.standard

    var asrEngine: ASREngine {
        didSet { d.set(asrEngine.rawValue, forKey: "asrEngine") }
    }

    var whisperModelPath: String {
        didSet { d.set(whisperModelPath, forKey: "whisperModelPath") }
    }

    var whisperLanguage: String {
        didSet { d.set(whisperLanguage, forKey: "whisperLanguage") }
    }

    var translatorEngine: TranslatorEngine {
        didSet { d.set(translatorEngine.rawValue, forKey: "translatorEngine") }
    }

    var sourceLang: String {
        didSet { d.set(sourceLang, forKey: "sourceLang") }
    }

    var targetLang: String {
        didSet { d.set(targetLang, forKey: "targetLang") }
    }

    var translateFormality: String {
        didSet { d.set(translateFormality, forKey: "translateFormality") }
    }

    var deeplEndpoint: String {
        didSet { d.set(deeplEndpoint, forKey: "deeplEndpoint") }
    }

    var dashscopeModel: String {
        didSet { d.set(dashscopeModel, forKey: "dashscopeModel") }
    }

    var translateInstruction: String {
        didSet { d.set(translateInstruction, forKey: "translateInstruction") }
    }

    var openaiBaseURL: String {
        didSet { d.set(openaiBaseURL, forKey: "openaiBaseURL") }
    }

    var openaiModel: String {
        didSet { d.set(openaiModel, forKey: "openaiModel") }
    }

    var openaiKey: String {
        get { KeychainStore.migrateFromDefaults("openaiKey") }
        set { KeychainStore.set("openaiKey", newValue) }
    }

    var bailianKey: String {
        get { KeychainStore.migrateFromDefaults("bailianKey") }
        set { KeychainStore.set("bailianKey", newValue) }
    }

    var bailianWorkspace: String {
        didSet { d.set(bailianWorkspace, forKey: "bailianWorkspace") }
    }

    var bailianRegion: String {
        didSet { d.set(bailianRegion, forKey: "bailianRegion") }
    }

    var geminiKey: String {
        get { KeychainStore.migrateFromDefaults("geminiKey") }
        set { KeychainStore.set("geminiKey", newValue) }
    }

    var deeplKey: String {
        get { KeychainStore.migrateFromDefaults("deeplKey") }
        set { KeychainStore.set("deeplKey", newValue) }
    }

    var qwen3Model: String {
        didSet { d.set(qwen3Model, forKey: "qwen3Model") }
    }

    var libreBaseURL: String {
        didSet { d.set(libreBaseURL, forKey: "libreBaseURL") }
    }

    private init() {
        asrEngine = ASREngine(rawValue: d.string(forKey: "asrEngine") ?? "") ?? .whisper
        whisperModelPath = d.string(forKey: "whisperModelPath") ?? SettingsStore.defaultWhisperPath()
        whisperLanguage = d.string(forKey: "whisperLanguage") ?? "auto"
        translatorEngine = TranslatorEngine(rawValue: d.string(forKey: "translatorEngine") ?? "") ?? .google
        sourceLang = d.string(forKey: "sourceLang") ?? "auto"
        targetLang = d.string(forKey: "targetLang") ?? "zh"
        translateFormality = d.string(forKey: "translateFormality") ?? "default"
        deeplEndpoint = d.string(forKey: "deeplEndpoint") ?? "auto"
        dashscopeModel = d.string(forKey: "dashscopeModel") ?? "qwen-plus"
        translateInstruction = d.string(forKey: "translateInstruction") ?? ""
        openaiBaseURL = d.string(forKey: "openaiBaseURL") ?? "http://127.0.0.1:11434/v1"
        openaiModel = d.string(forKey: "openaiModel") ?? "llama3.1"
        bailianWorkspace = d.string(forKey: "bailianWorkspace") ?? ""
        bailianRegion = d.string(forKey: "bailianRegion") ?? "cn-beijing"
        qwen3Model = d.string(forKey: "qwen3Model") ?? "0.6b"
        libreBaseURL = d.string(forKey: "libreBaseURL") ?? "http://127.0.0.1:5000"
    }

    var libreKey: String {
        get { KeychainStore.migrateFromDefaults("libreKey") }
        set { KeychainStore.set("libreKey", newValue) }
    }

    func asrOptions() -> [String: Any] {
        switch asrEngine.rawValue {
        case "whisper":
            return ["model_path": whisperModelPath, "language": whisperLanguage]
        case "qwen3-asr":
            return ["model": qwen3Model, "language": whisperLanguage]
        case "fun-asr-realtime", "qwen-audio-3.1-asr-flash-streaming", "qwen3-asr-flash-realtime":
            return [
                "api_key": bailianKey,
                "workspace_id": bailianWorkspace,
                "region": bailianRegion,
            ]
        case "gemini-3.5-transcribe-live":
            return ["api_key": geminiKey]
        default:
            return [:]
        }
    }

    func translatorOptions() -> [String: Any] {
        var o: [String: Any] = [
            "source_lang": sourceLang,
            "target_lang": targetLang,
            "formality": translateFormality,
            "instruction": translateInstruction,
        ]
        switch translatorEngine.rawValue {
        case "openai-compatible", "openai", "ollama", "lmstudio":
            o["base_url"] = openaiBaseURL
            o["model"] = openaiModel
            o["api_key"] = openaiKey
        case "deepl":
            o["api_key"] = deeplKey
            o["endpoint"] = deeplEndpoint
        case "libretranslate", "libre":
            o["base_url"] = libreBaseURL
            o["api_key"] = libreKey
        case "qwen", "dashscope":
            o["api_key"] = bailianKey
            o["model"] = dashscopeModel
        default:
            break
        }
        return o
    }

    static func defaultWhisperPath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glossa/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tiny = dir.appendingPathComponent("ggml-tiny.en.bin")
        if FileManager.default.fileExists(atPath: tiny.path) {
            return tiny.path
        }
        return dir.appendingPathComponent("ggml-small.bin").path
    }
}

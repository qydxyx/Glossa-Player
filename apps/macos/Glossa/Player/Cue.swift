import Foundation

enum SubtitleDisplayMode: String, CaseIterable, Identifiable {
    case bilingual
    case original
    case translation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bilingual: "双语"
        case .original: "原文"
        case .translation: "译文"
        }
    }

    var showsOriginal: Bool { self != .translation }
    var showsTranslation: Bool { self != .original }

    func next() -> SubtitleDisplayMode {
        switch self {
        case .bilingual: .original
        case .original: .translation
        case .translation: .bilingual
        }
    }
}

struct Cue: Identifiable, Hashable, Codable {
    var id: String
    var startMs: UInt64
    var endMs: UInt64
    var text: String
    var translatedText: String?
    var language: String?
    var partial: Bool
    var engine: String?

    var start: TimeInterval { Double(startMs) / 1000 }
    var end: TimeInterval { Double(endMs) / 1000 }

    func contains(_ t: TimeInterval) -> Bool {
        t >= start && t < end
    }

    enum CodingKeys: String, CodingKey {
        case id
        case startMs = "start_ms"
        case endMs = "end_ms"
        case text
        case translatedText = "translated_text"
        case language
        case partial
        case engine
    }

    init(
        id: String,
        startMs: UInt64,
        endMs: UInt64,
        text: String,
        translatedText: String? = nil,
        language: String? = nil,
        partial: Bool = false,
        engine: String? = nil
    ) {
        self.id = id
        self.startMs = startMs
        self.endMs = endMs
        self.text = text
        self.translatedText = translatedText
        self.language = language
        self.partial = partial
        self.engine = engine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        startMs = try c.decode(UInt64.self, forKey: .startMs)
        endMs = try c.decode(UInt64.self, forKey: .endMs)
        text = try c.decode(String.self, forKey: .text)
        translatedText = try c.decodeIfPresent(String.self, forKey: .translatedText)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        partial = try c.decodeIfPresent(Bool.self, forKey: .partial) ?? false
        engine = try c.decodeIfPresent(String.self, forKey: .engine)
    }
}

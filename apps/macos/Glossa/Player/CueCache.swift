import CryptoKit
import Foundation

enum CueCache {
    static func load(url: URL, identity: String) -> [Cue]? {
        let path = file(for: url, identity: identity)
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let cues = try? JSONDecoder().decode([Cue].self, from: data)
        else { return nil }
        return cues
    }

    static func save(url: URL, identity: String, cues: [Cue]) {
        let path = file(for: url, identity: identity)
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let final = cues.filter { !$0.partial && !$0.text.isEmpty }
        guard let data = try? JSONEncoder().encode(final) else { return }
        try? data.write(to: path, options: .atomic)
    }

    @MainActor
    static func identity() -> String {
        let s = SettingsStore.shared
        return "\(s.asrEngine.rawValue)|\(s.translatorEngine.rawValue)|\(s.sourceLang)|\(s.targetLang)"
    }

    private static func file(for url: URL, identity: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glossa/cache", isDirectory: true)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let raw = "\(url.standardizedFileURL.path)|\(size)|\(mtime)|\(identity)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("\(hex).json")
    }
}

import Foundation

enum SRT {
    static func parse(_ text: String) -> [Cue] {
        var cues: [Cue] = []
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.count >= 2 else { continue }
            let timeLine = lines[0].contains("-->") ? lines[0] : (lines.count > 1 ? lines[1] : "")
            guard let range = parseTime(timeLine) else { continue }
            let textLines = Array(lines.drop { !$0.contains("-->") }.dropFirst())
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !textLines.isEmpty else { continue }
            let body: String
            let translated: String?
            if textLines.count >= 2 {
                body = textLines.dropLast().joined(separator: " ")
                translated = textLines.last
            } else {
                body = textLines[0]
                translated = nil
            }
            cues.append(Cue(
                id: UUID().uuidString,
                startMs: range.0,
                endMs: range.1,
                text: body,
                translatedText: translated,
                language: nil,
                partial: false,
                engine: "srt"
            ))
        }
        return cues
    }

    private static func parseTime(_ line: String) -> (UInt64, UInt64)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }
        func ms(_ s: String) -> UInt64? {
            let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            let bits = t.split(separator: ":")
            guard bits.count == 3, let h = Double(bits[0]), let m = Double(bits[1]), let sec = Double(bits[2]) else { return nil }
            return UInt64((h * 3600 + m * 60 + sec) * 1000)
        }
        guard let a = ms(parts[0]), let b = ms(parts[1]) else { return nil }
        return (a, b)
    }

    static func serialize(_ cues: [Cue]) -> String {
        cues.enumerated().map { i, c in
            var body = c.text
            if let t = c.translatedText, !t.isEmpty {
                body += "\n" + t
            }
            return """
            \(i + 1)
            \(stamp(c.startMs)) --> \(stamp(c.endMs))
            \(body)
            """
        }.joined(separator: "\n\n") + "\n"
    }

    private static func stamp(_ ms: UInt64) -> String {
        let t = Int(ms)
        let h = t / 3_600_000
        let m = (t % 3_600_000) / 60_000
        let s = (t % 60_000) / 1000
        let milli = t % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, milli)
    }
}

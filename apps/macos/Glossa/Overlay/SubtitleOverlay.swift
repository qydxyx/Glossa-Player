import AppKit
import SwiftUI

struct SubtitleOverlay: View {
    var cue: Cue?
    var model: PlayerModel

    var body: some View {
        VStack(spacing: 4) {
            if model.showPrimary, let text = cue?.text, !text.isEmpty {
                SelectableLine(text: text, size: model.showSecondary ? 28 : 32, color: .white)
            }
            if model.showSecondary, let text = cue?.translatedText, !text.isEmpty {
                SelectableLine(text: text, size: model.showPrimary ? 20 : 32, color: Color(white: 0.88))
            }
        }
        .frame(maxWidth: 880)
        .padding(.horizontal, 28)
    }
}

struct SelectableLine: View {
    var text: String
    var size: CGFloat
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .semibold, design: .default))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .shadow(color: .black.opacity(0.95), radius: 0, x: 1, y: 1)
            .shadow(color: .black.opacity(0.95), radius: 0, x: -1, y: 1)
            .shadow(color: .black.opacity(0.7), radius: 4, y: 1)
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Look Up") { showDefine(text) }
            }
    }

    private func showDefine(_ word: String) {
        let first = word.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? word
        NSPerformService("Look Up in Dictionary", NSPasteboard.general.with {
            $0.clearContents()
            $0.setString(first, forType: .string)
        })
    }
}

private extension NSPasteboard {
    func with(_ body: (NSPasteboard) -> Void) -> NSPasteboard {
        body(self)
        return self
    }
}

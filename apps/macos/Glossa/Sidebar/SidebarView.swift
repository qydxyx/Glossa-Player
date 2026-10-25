import SwiftUI

struct SidebarView: View {
    @Environment(PlayerModel.self) private var model
    @State private var query = ""

    var filtered: [Cue] {
        if query.isEmpty { return model.cues }
        return model.cues.filter {
            $0.text.localizedCaseInsensitiveContains(query)
                || ($0.translatedText ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
                TextField("Filter", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
            if filtered.isEmpty {
                Text(model.cues.isEmpty ? "No subtitles yet" : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.32))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(filtered) { cue in
                                cueRow(cue)
                                    .id(cue.id)
                            }
                        }
                    }
                    .onChange(of: model.currentCue?.id) { _, id in
                        if let id {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.09))
    }

    private func cueRow(_ cue: Cue) -> some View {
        let active = model.currentCue?.id == cue.id
        return Button {
            model.jump(to: cue)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(time(cue.startMs))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .frame(width: 54, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cue.text)
                        .font(.system(size: 12, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Color.white : Color.white.opacity(0.82))
                        .multilineTextAlignment(.leading)
                    if let t = cue.translatedText, !t.isEmpty {
                        Text(t)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.42))
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(active ? Color.white.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func time(_ ms: UInt64) -> String {
        let s = Int(ms / 1000)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", (s % 3600) / 60, s % 60)
    }
}

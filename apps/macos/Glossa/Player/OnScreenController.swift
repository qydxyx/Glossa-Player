import SwiftUI

/// Floating OSC modeled on IINA's default controller: thin slider, transport, tools.
struct OnScreenController: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ThinSlider(
                value: Binding(
                    get: { model.duration == 0 ? 0 : model.timePos / model.duration },
                    set: { model.seek(absolute: $0 * model.duration) }
                )
            )
            HStack(spacing: 2) {
                Text(format(model.timePos))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer(minLength: 8)
                OSCButton(system: "gobackward.5", size: 14) { model.seek(relative: -5) }
                OSCButton(
                    system: model.paused ? "play.fill" : "pause.fill",
                    size: 18
                ) { model.togglePause() }
                .frame(width: 36, height: 32)
                OSCButton(system: "goforward.5", size: 14) { model.seek(relative: 5) }
                Spacer(minLength: 8)
                Image(systemName: model.volume < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 18)
                ThinSlider(
                    value: Binding(
                        get: { model.volume / 100 },
                        set: { model.setVolume($0 * 100) }
                    )
                )
                .frame(width: 72)
                Text(format(model.duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(.leading, 8)
            }
            HStack(spacing: 4) {
                OSCButton(
                    system: model.sentenceLoop ? "repeat.1" : "repeat",
                    active: model.sentenceLoop
                ) { model.loopCurrentSentence() }
                .help("Loop sentence (L)")
                OSCButton(system: "chevron.left", size: 12) { model.jumpSentence(delta: -1) }
                OSCButton(system: "chevron.right", size: 12) { model.jumpSentence(delta: 1) }
                Spacer()
                if model.asrStatus != "idle" {
                    Text(model.asrStatus)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                OSCButton(system: "character.bubble") { model.retranslate() }
                    .help("Retranslate current subtitles")
                OSCButton(
                    system: "waveform",
                    active: model.asrEnabled
                ) {
                    if model.asrEnabled { model.stopAsr() } else { model.startAsr() }
                }
                .help(model.asrEnabled ? "Stop ASR" : "Start ASR (R)")
                Picker("字幕", selection: Bindable(model).subtitleMode) {
                    ForEach(SubtitleDisplayMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 158)
                .help("字幕显示：双语 / 原文 / 译文（C 循环）")
                OSCButton(system: "sidebar.right", active: model.showSidebar) {
                    model.showSidebar.toggle()
                }
                .help("Subtitle list (S)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: 520)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.black.opacity(0.42))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        }
    }

    private func format(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let s = Int(t)
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

struct OSCButton: View {
    var system: String
    var active = false
    var size: CGFloat = 13
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.88))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ThinSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let x = min(max(value, 0), 1) * w
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(height: 3)
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: max(x, 3), height: 3)
                Circle()
                    .fill(Color.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
                    .offset(x: min(max(x - 5.5, 0), w - 11))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        value = min(max(g.location.x / w, 0), 1)
                    }
            )
        }
        .frame(height: 16)
    }
}

import AppKit
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
@Observable
final class PlayerModel {
    var currentURL: URL?
    var paused = true
    var timePos: TimeInterval = 0
    var duration: TimeInterval = 0
    var volume: Double = 100
    var cues: [Cue] = []
    var asrStatus = "idle"
    var lastError: String?
    var showSidebar = true
    var subtitleMode: SubtitleDisplayMode = .bilingual
    var asrEnabled = false
    var sentenceLoop = false

    var showPrimary: Bool { subtitleMode.showsOriginal }
    var showSecondary: Bool { subtitleMode.showsTranslation }

    var engine = EngineClient()
    weak var mpv: MPVGLView?

    var currentCue: Cue? {
        cues.last { $0.contains(timePos) } ?? cues.last { $0.start <= timePos }
    }

    func attach(_ view: MPVGLView) {
        mpv = view
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie]
        if #available(macOS 15, *) {
            // keep default
        }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.open(url)
            }
        }
    }

    func open(_ url: URL) {
        currentURL = url
        lastError = nil
        clearSentenceLoop()
        if let cached = CueCache.load(url: url, identity: CueCache.identity()), !cached.isEmpty {
            cues = cached
            asrStatus = "cached"
        } else {
            cues = []
        }
        mpv?.loadFile(url)
        paused = false
        if asrEnabled {
            startAsr()
        }
    }

    func togglePause() {
        paused.toggle()
        mpv?.setFlag("pause", paused)
        engine.send(.pause(paused: paused))
    }

    func setVolume(_ value: Double) {
        volume = min(100, max(0, value))
        mpv?.setDouble("volume", volume)
    }

    func seek(relative seconds: Double) {
        let target = max(0, timePos + seconds)
        seek(absolute: target, restartAsr: asrEnabled)
    }

    func seek(absolute seconds: Double, restartAsr: Bool = true) {
        mpv?.command("seek", args: [String(seconds), "absolute"])
        timePos = seconds
        if restartAsr && asrEnabled {
            startAsr()
        }
    }

    func jump(to cue: Cue) {
        seek(absolute: cue.start, restartAsr: false)
        if sentenceLoop {
            applySentenceLoop(cue)
        }
    }

    func jumpSentence(delta: Int) {
        guard !cues.isEmpty else { return }
        let ordered = cues.sorted { $0.startMs < $1.startMs }
        let idx = ordered.lastIndex { $0.start <= timePos + 0.05 } ?? 0
        let next = min(max(idx + delta, 0), ordered.count - 1)
        jump(to: ordered[next])
    }

    func loopCurrentSentence() {
        if sentenceLoop {
            clearSentenceLoop()
            return
        }
        guard let cue = currentCue else { return }
        applySentenceLoop(cue)
        seek(absolute: cue.start, restartAsr: false)
    }

    func lookUpCurrent() {
        guard let text = currentCue?.text else { return }
        let first = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? text
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(first, forType: .string)
        NSPerformService("Look Up in Dictionary", pb)
    }

    private func applySentenceLoop(_ cue: Cue) {
        mpv?.setString("ab-loop-a", String(cue.start))
        mpv?.setString("ab-loop-b", String(cue.end))
        sentenceLoop = true
    }

    private func clearSentenceLoop() {
        mpv?.setString("ab-loop-a", "no")
        mpv?.setString("ab-loop-b", "no")
        sentenceLoop = false
    }

    func startAsr() {
        guard let url = currentURL else { return }
        asrEnabled = true
        let startMs = UInt64(max(0, timePos) * 1000)
        cues.removeAll { $0.startMs >= startMs }
        engine.ensureStarted()
        engine.send(.setAsr(engine: SettingsStore.shared.asrEngine.rawValue, options: SettingsStore.shared.asrOptions()))
        engine.send(.setTranslator(engine: SettingsStore.shared.translatorEngine.rawValue, options: SettingsStore.shared.translatorOptions()))
        engine.send(.open(url: url.path, startMs: startMs, audioStream: nil))
        asrStatus = "starting"
    }

    func stopAsr() {
        asrEnabled = false
        engine.send(.stopAsr)
        asrStatus = "idle"
    }

    func retranslate() {
        let items = cues
            .filter { !$0.partial && !$0.text.isEmpty }
            .map { (id: $0.id, text: $0.text, language: $0.language) }
        guard !items.isEmpty else { return }
        engine.ensureStarted()
        engine.send(.setTranslator(engine: SettingsStore.shared.translatorEngine.rawValue, options: SettingsStore.shared.translatorOptions()))
        engine.send(.retranslate(items: items))
        asrStatus = "retranslate"
    }

    func importSRT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.text, UTType(filenameExtension: "srt")].compactMap { $0 }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.cues = SRT.parse(text)
            }
        }
    }

    func exportSRT() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt")].compactMap { $0 }
        panel.nameFieldStringValue = (currentURL?.deletingPathExtension().lastPathComponent ?? "subtitles") + ".srt"
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                try? SRT.serialize(self.cues).write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    func handle(server: EngineEvent) {
        switch server {
        case .ready:
            asrStatus = "ready"
        case .status(let asr, let message):
            asrStatus = message.map { "\(asr) · \($0)" } ?? asr
            if (asr == "done" || (asr == "retranslate" && message == "done")), let url = currentURL {
                CueCache.save(url: url, identity: CueCache.identity(), cues: cues)
            }
        case .error(let message):
            lastError = message
            asrStatus = "error"
        case .cueUpsert(let cue):
            if let i = cues.firstIndex(where: { $0.id == cue.id }) {
                cues[i] = cue
            } else if cue.partial, let i = cues.lastIndex(where: { $0.partial && $0.engine == cue.engine }) {
                cues[i] = cue
            } else {
                cues.append(cue)
                cues.sort { $0.startMs < $1.startMs }
            }
        case .translation(let id, let text):
            if let i = cues.firstIndex(where: { $0.id == id }) {
                cues[i].translatedText = text
            }
        }
    }

    func tick() {
        guard let mpv else { return }
        timePos = mpv.getDouble("time-pos")
        duration = mpv.getDouble("duration")
        let vol = mpv.getDouble("volume")
        if vol.isFinite { volume = vol }
        let p = mpv.getFlag("pause")
        if p != paused { paused = p }
    }
}

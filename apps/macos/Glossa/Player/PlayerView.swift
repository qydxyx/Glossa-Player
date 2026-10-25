import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @Environment(PlayerModel.self) private var model
    @State private var showOSC = true
    @State private var hoveringOSC = false
    @State private var hideTask: Task<Void, Never>?
    @State private var ticker: Timer?

    var body: some View {
        HSplitView {
            videoPane
                .frame(minWidth: 640)
            if model.showSidebar {
                SidebarView()
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            }
        }
        .background(Color.black)
        .background(WindowChrome())
        .preferredColorScheme(.dark)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                EmptyView()
            }
        }
        .alert("Engine", isPresented: Binding(
            get: { model.lastError != nil && model.asrStatus == "error" },
            set: { if !$0 { model.lastError = nil } }
        )) {
            Button("OK", role: .cancel) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .onAppear(perform: setup)
        .onDisappear { ticker?.invalidate(); hideTask?.cancel() }
        .onOpenURL { model.open($0) }
        .focusable()
        .onKeyPress { handleKey($0) }
        .onChange(of: model.paused) { _, paused in
            if paused { showOSC = true } else { scheduleHide() }
        }
    }

    private var videoPane: some View {
        ZStack {
            MPVHost(model: model)
            if model.currentURL != nil {
                Color.clear
                    .padding(.top, 44)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { toggleFullScreen() }
                    .onTapGesture(count: 1) { model.togglePause() }
            }
            if model.currentURL == nil {
                emptyState
            }
            VStack {
                if showOSC {
                    topBar
                        .transition(.opacity)
                }
                Spacer()
                if model.showPrimary || model.showSecondary {
                    SubtitleOverlay(cue: model.currentCue, model: model)
                        .padding(.bottom, showOSC ? 88 : 28)
                }
                if showOSC {
                    OnScreenController()
                        .padding(.bottom, 18)
                        .onHover { over in
                            hoveringOSC = over
                            if over { showOSC = true; hideTask?.cancel() }
                            else { scheduleHide() }
                        }
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.18), value: showOSC)
        }
        .onDrop(of: [.fileURL], isTargeted: nil, perform: drop)
        .onHover { inside in
            if inside { bumpOSC() } else if !model.paused && !hoveringOSC { showOSC = false }
        }
        .onContinuousHover { _ in bumpOSC() }
    }

    private var topBar: some View {
        HStack {
            Text(model.currentURL?.lastPathComponent ?? "Glossa Player")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 86)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .background {
            LinearGradient(
                colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.28))
            Text("Drop a video here")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.4))
            Button("Open…") { model.openPanel() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .overlay {
                    Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
                }
        }
    }

    private func setup() {
        model.engine.onEvent = { model.handle(server: $0) }
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            Task { @MainActor in model.tick() }
        }
        if CommandLine.arguments.count > 1 {
            let path = CommandLine.arguments[1]
            if FileManager.default.fileExists(atPath: path) {
                model.open(URL(fileURLWithPath: path))
            }
        }
        bumpOSC()
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                Task { @MainActor in model.open(url) }
            }
        }
        return true
    }

    private func bumpOSC() {
        showOSC = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard !model.paused, !hoveringOSC else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            if !Task.isCancelled, !model.paused, !hoveringOSC {
                showOSC = false
            }
        }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        bumpOSC()
        switch press.key {
        case .space:
            model.togglePause(); return .handled
        case .leftArrow:
            model.seek(relative: press.modifiers.contains(.shift) ? -15 : -5); return .handled
        case .rightArrow:
            model.seek(relative: press.modifiers.contains(.shift) ? 15 : 5); return .handled
        case .escape:
            if NSApp.keyWindow?.styleMask.contains(.fullScreen) == true {
                toggleFullScreen(); return .handled
            }
            return .ignored
        default:
            if press.characters == "[" { model.jumpSentence(delta: -1); return .handled }
            if press.characters == "]" { model.jumpSentence(delta: 1); return .handled }
            if press.characters == "c" { model.subtitleMode = model.subtitleMode.next(); return .handled }
            if press.characters == "t" { model.subtitleMode = .translation; return .handled }
            if press.characters == "s" { model.showSidebar.toggle(); return .handled }
            if press.characters == "r" { model.startAsr(); return .handled }
            if press.characters == "l" { model.loopCurrentSentence(); return .handled }
            if press.characters == "d" { model.lookUpCurrent(); return .handled }
            if press.characters == "f" { toggleFullScreen(); return .handled }
            if press.characters == "o" && press.modifiers.contains(.command) {
                model.openPanel(); return .handled
            }
            return .ignored
        }
    }
}

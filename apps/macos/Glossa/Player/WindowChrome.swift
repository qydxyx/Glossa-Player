import AppKit
import SwiftUI

/// Transparent titlebar, but keep macOS traffic lights clickable.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ChromeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ChromeView)?.apply()
    }

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            apply()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        func apply() {
            guard let w = window else { return }
            w.styleMask.formUnion([.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView])
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .visible
            w.isMovableByWindowBackground = true
            w.backgroundColor = .black
            w.appearance = NSAppearance(named: .darkAqua)
            w.titlebarSeparatorStyle = .none
            revealTrafficLights(in: w)
            DispatchQueue.main.async { [weak self] in
                self?.revealTrafficLights(in: w)
            }
        }

        private func revealTrafficLights(in w: NSWindow) {
            for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                guard let btn = w.standardWindowButton(type) else { continue }
                btn.isHidden = false
                btn.alphaValue = 1
                btn.isEnabled = true
                btn.superview?.isHidden = false
            }
        }
    }
}

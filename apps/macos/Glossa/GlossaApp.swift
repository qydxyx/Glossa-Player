import SwiftUI

@main
struct GlossaApp: App {
    @State private var model = PlayerModel()

    var body: some Scene {
        WindowGroup("Glossa Player") {
            PlayerView()
                .environment(model)
                .frame(minWidth: 960, minHeight: 540)
                .background(Color.black)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 720)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    model.openPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
                Button("Import SRT…") { model.importSRT() }
                Button("Export SRT…") { model.exportSRT() }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 560, minHeight: 400)
        }
    }
}

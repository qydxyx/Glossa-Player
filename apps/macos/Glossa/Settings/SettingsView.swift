import SwiftUI

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, asr, translate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .asr: "ASR"
        case .translate: "Translate"
        }
    }
    var icon: String {
        switch self {
        case .general: "gearshape"
        case .asr: "waveform"
        case .translate: "globe"
        }
    }
}

struct SettingsView: View {
    @Bindable private var store = SettingsStore.shared
    @State private var pane: SettingsPane = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { item in
                Label(item.title, systemImage: item.icon).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(ideal: 176)
        } detail: {
            Form {
                switch pane {
                case .general: general
                case .asr: asr
                case .translate: translate
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 680, minHeight: 440)
    }

    @ViewBuilder private var general: some View {
        Section {
            Text("Space pause · arrows seek · [ ] sentence · L loop · C/T tracks · S list · F fullscreen")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var asr: some View {
        Section("Engine") {
            Picker("Engine", selection: $store.asrEngine) {
                ForEach(ASREngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.menu)
            Picker("Audio language", selection: $store.whisperLanguage) {
                Text("Auto").tag("auto")
                Text("en").tag("en")
                Text("zh").tag("zh")
                Text("ja").tag("ja")
                Text("ko").tag("ko")
            }
            .pickerStyle(.menu)
        }
        if store.asrEngine == .qwen3Asr {
            Section("Qwen3-ASR MLX") {
                Picker("Model", selection: $store.qwen3Model) {
                    Text("0.6B (faster)").tag("0.6b")
                    Text("1.7B (more accurate)").tag("1.7b")
                }
                .pickerStyle(.menu)
            }
        }
        if store.asrEngine == .whisper {
            Section("Whisper") {
                TextField("Model path", text: $store.whisperModelPath)
            }
        }
        if store.asrEngine == .funAsr || store.asrEngine == .qwenAudio || store.asrEngine == .qwen3Flash {
            Section("Bailian") {
                SecureField("API key", text: $store.bailianKey)
                TextField("Workspace id", text: $store.bailianWorkspace)
                TextField("Region", text: $store.bailianRegion)
            }
        }
        if store.asrEngine == .gemini {
            Section("Gemini") {
                SecureField("API key", text: $store.geminiKey)
            }
        }
    }

    @ViewBuilder private var translate: some View {
        Section("Languages") {
            Picker("Source", selection: $store.sourceLang) {
                ForEach(TranslateLang.sources) { lang in
                    Text(lang.title).tag(lang.rawValue)
                }
            }
            .pickerStyle(.menu)
            Picker("Target", selection: $store.targetLang) {
                ForEach(TranslateLang.targets) { lang in
                    Text(lang.title).tag(lang.rawValue)
                }
            }
            .pickerStyle(.menu)
            Picker("Tone", selection: $store.translateFormality) {
                Text("Default").tag("default")
                Text("More formal").tag("more")
                Text("More casual").tag("less")
            }
            .pickerStyle(.menu)
        }
        Section("Engine") {
            Picker("Engine", selection: $store.translatorEngine) {
                ForEach(TranslatorEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.menu)
        }
        if store.translatorEngine == .deepl {
            Section("DeepL") {
                SecureField("API key", text: $store.deeplKey)
                Picker("API endpoint", selection: $store.deeplEndpoint) {
                    Text("Auto (from key)").tag("auto")
                    Text("Free (api-free.deepl.com)").tag("free")
                    Text("Pro (api.deepl.com)").tag("pro")
                }
                .pickerStyle(.menu)
                Text("Free keys usually end with :fx.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        if store.translatorEngine == .libretranslate {
            Section("LibreTranslate") {
                TextField("URL", text: $store.libreBaseURL)
                SecureField("API key", text: $store.libreKey)
            }
        }
        if store.translatorEngine == .openaiCompatible
            || store.translatorEngine == .ollama
            || store.translatorEngine == .lmstudio {
            Section("OpenAI-compatible") {
                TextField("Base URL", text: $store.openaiBaseURL)
                TextField("Model", text: $store.openaiModel)
                SecureField("API key", text: $store.openaiKey)
                TextField("Extra instruction", text: $store.translateInstruction, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
        if store.translatorEngine == .qwen {
            Section("DashScope") {
                TextField("Model", text: $store.dashscopeModel)
                SecureField("API key", text: $store.bailianKey)
                TextField("Extra instruction", text: $store.translateInstruction, axis: .vertical)
                    .lineLimit(2...5)
            }
        }
        if store.translatorEngine == .google {
            Section {
                Text("Google uses the unofficial web endpoint. Source Auto detect is supported.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

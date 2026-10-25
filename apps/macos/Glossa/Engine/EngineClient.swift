import Foundation

enum ClientCommand {
    case open(url: String, startMs: UInt64, audioStream: Int?)
    case seek(timeMs: UInt64)
    case pause(paused: Bool)
    case setAsr(engine: String, options: [String: Any])
    case setTranslator(engine: String, options: [String: Any])
    case stopAsr
    case shutdown

    func json() -> String {
        var obj: [String: Any] = [:]
        switch self {
        case .open(let url, let startMs, let audioStream):
            obj["type"] = "open"
            obj["url"] = url
            obj["start_ms"] = startMs
            if let audioStream { obj["audio_stream"] = audioStream }
        case .seek(let timeMs):
            obj["type"] = "seek"
            obj["time_ms"] = timeMs
        case .pause(let paused):
            obj["type"] = "pause"
            obj["paused"] = paused
        case .setAsr(let engine, let options):
            obj["type"] = "set_asr"
            obj["engine"] = engine
            obj["options"] = options
        case .setTranslator(let engine, let options):
            obj["type"] = "set_translator"
            obj["engine"] = engine
            obj["options"] = options
        case .stopAsr:
            obj["type"] = "stop_asr"
        case .shutdown:
            obj["type"] = "shutdown"
        }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)! + "\n"
    }
}

enum EngineEvent {
    case ready
    case cueUpsert(Cue)
    case translation(id: String, text: String)
    case status(asr: String, message: String?)
    case error(String)

    static func parse(_ line: String) -> EngineEvent? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return nil }
        switch type {
        case "ready":
            return .ready
        case "cue_upsert":
            guard let cueObj = obj["cue"] as? [String: Any],
                  let json = try? JSONSerialization.data(withJSONObject: cueObj),
                  let cue = try? JSONDecoder().decode(Cue.self, from: json)
            else { return nil }
            return .cueUpsert(cue)
        case "translation":
            guard let id = obj["cue_id"] as? String, let text = obj["text"] as? String else { return nil }
            return .translation(id: id, text: text)
        case "status":
            return .status(asr: obj["asr"] as? String ?? "", message: obj["message"] as? String)
        case "error":
            return .error(obj["message"] as? String ?? "engine error")
        default:
            return nil
        }
    }
}

@MainActor
final class EngineClient {
    private var process: Process?
    private var stdin: FileHandle?
    private var reader: FileHandle?
    private var lineBuf = ""
    var onEvent: ((EngineEvent) -> Void)?

    func ensureStarted() {
        if process?.isRunning == true { return }
        guard let url = Self.engineURL() else {
            onEvent?(.error("glossa-engine binary not found. Run `cargo build -p glossa-engine`."))
            return
        }
        let proc = Process()
        proc.executableURL = url
        proc.arguments = ["--stdio"]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                NSLog("engine: %@", s)
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self.lineBuf += text
                while let range = self.lineBuf.range(of: "\n") {
                    let line = String(self.lineBuf[..<range.lowerBound])
                    self.lineBuf.removeSubrange(..<range.upperBound)
                    if let ev = EngineEvent.parse(line) {
                        self.onEvent?(ev)
                    }
                }
            }
        }
        do {
            try proc.run()
            process = proc
            stdin = inPipe.fileHandleForWriting
            reader = outPipe.fileHandleForReading
        } catch {
            onEvent?(.error(error.localizedDescription))
        }
    }

    func send(_ cmd: ClientCommand) {
        ensureStarted()
        guard let stdin else { return }
        if let data = cmd.json().data(using: .utf8) {
            try? stdin.write(contentsOf: data)
        }
    }

    private static func engineURL() -> URL? {
        if let env = ProcessInfo.processInfo.environment["GLOSSA_ENGINE"] {
            return URL(fileURLWithPath: env)
        }
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/glossa-engine")
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("target/debug/glossa-engine")
        if FileManager.default.isExecutableFile(atPath: dev.path) {
            return dev
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("projects/LLPlayer-for-Mac/target/debug/glossa-engine")
        if FileManager.default.isExecutableFile(atPath: home.path) {
            return home
        }
        return nil
    }
}

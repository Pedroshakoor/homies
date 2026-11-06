import Foundation

final class ProcessControl: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false
    func start(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { throw CancellationError() }
        self.process = process
        try process.run()
    }
    func cancel() {
        lock.lock(); stopped = true
        if let process, process.isRunning { process.interrupt() }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
            lock.lock(); defer { lock.unlock() }
            if let process, process.isRunning { process.terminate() }
        }
    }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
private final class ErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        if data.count > 16384 { data.removeFirst(data.count - 16384) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

struct CLIEnvironment {
    var path: String
    static func discover() async -> Self {
        await Task.detached {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            // No config values are interpolated into shell code.
            process.arguments = ["-lc", "printf '%s\\n' \"$PATH\"; command -v claude; command -v codex; command -v hermes"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                let path = lines.first(where: { $0.contains(":") && $0.contains("/usr/bin") })
                    ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
                return Self(path: path)
            } catch { return Self(path: "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin") }
        }.value
    }
    func resolve(_ name: String) -> String? {
        path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent(name).path }
            .first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
    }
}

final class CLIAdapter: AgentAdapter {
    let config: AgentConfiguration
    let environment: CLIEnvironment
    var sessionID: String?
    private var active: ProcessControl?
    var id: String { config.id }
    var displayName: String { config.displayName }
    init(config: AgentConfiguration, environment: CLIEnvironment, sessionID: String?) {
        self.config = config; self.environment = environment; self.sessionID = sessionID
    }
    static func arguments(kind: AdapterKind, sessionID: String?, model: String? = nil, allowProjectEdits: Bool = false) -> [String] {
        switch kind {
        case .claudeCode:
            var args = ["--print", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-mode", "dontAsk"]
            if let sessionID { args += ["--resume", sessionID] }
            if let model, !model.isEmpty { args += ["--model", model] }
            return args
        case .codex:
            // Exec uses a bounded sandbox; interactive approvals continue in Terminal.
            var args = ["-a", "never", "-s", allowProjectEdits ? "workspace-write" : "read-only", "exec"]
            if sessionID != nil { args.append("resume") }
            args += ["--json", "--skip-git-repo-check"]
            if let model, !model.isEmpty { args += ["--model", model] }
            if let sessionID { args.append(sessionID) }
            args.append("-")
            return args
        case .hermes:
            var args = ["chat", "--oneshot", "--query-file", "-", "--format", "stream-json"]
            if let sessionID { args += ["--resume", sessionID] }
            if let model, !model.isEmpty { args += ["--model", model] }
            return args
        }
    }
    func send(_ message: OutgoingMessage) -> AsyncThrowingStream<AgentEvent, Error> {
        let control = ProcessControl()
        active = control
        let config = config, env = environment, session = sessionID
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { reason in if case .cancelled = reason { control.cancel() } }
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(), stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
                let errors = ErrorBuffer(), stderrDone = DispatchGroup()
                do {
                    guard config.binaryPath.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: config.binaryPath) else {
                        throw AppError.message("Choose the \(config.displayName) executable in Settings.")
                    }
                    var isDirectory: ObjCBool = false
                    guard config.workingDirectory.hasPrefix("/"),
                          FileManager.default.fileExists(atPath: config.workingDirectory, isDirectory: &isDirectory), isDirectory.boolValue else {
                        throw AppError.message("Choose an existing working folder in Settings first.")
                    }
                    process.executableURL = URL(fileURLWithPath: config.binaryPath)
                    process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)
                    var args = Self.arguments(kind: config.adapterType, sessionID: session, model: config.model, allowProjectEdits: config.allowProjectEdits ?? false)
                    if config.adapterType == .hermes { args += ["--in", config.workingDirectory] }
                    if config.adapterType == .codex {
                        let images = message.attachments.filter { ["png", "jpg", "jpeg", "webp"].contains($0.pathExtension.lowercased()) }
                        let index = args.count - 1
                        args.insert(contentsOf: images.flatMap { ["--image", $0.path] }, at: index)
                    }
                    if config.adapterType == .claudeCode {
                        for parent in Set(message.attachments.map { $0.deletingLastPathComponent().path }) { args += ["--add-dir", parent] }
                    }
                    process.arguments = args
                    let prompt = message.text + (message.attachments.isEmpty ? "" : "\n\nAttached local files (read them as context):\n" + message.attachments.map(\.path).joined(separator: "\n"))
                    var variables = ProcessInfo.processInfo.environment
                    variables["PATH"] = env.path
                    variables.removeValue(forKey: "CLAUDECODE")
                    process.environment = variables
                    process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
                    try control.start(process)
                    stderrDone.enter()
                    DispatchQueue.global().async {
                        defer { stderrDone.leave() }
                        while true {
                            let data = stderr.fileHandleForReading.availableData
                            if data.isEmpty { break }; errors.append(data)
                        }
                    }
                    // A separate writer avoids blocking stdout when a long prompt fills stdin.
                    DispatchQueue.global().async {
                        defer { try? stdin.fileHandleForWriting.close() }
                        do { try stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8)) }
                        catch { errors.append(Data("Could not send prompt: \(error.localizedDescription)".utf8)) }
                    }
                    continuation.yield(.status(.thinking))
                    var parser = EventParser(kind: config.adapterType)
                    while true {
                        let data = stdout.fileHandleForReading.availableData
                        if data.isEmpty { break }
                        for event in try parser.feed(data) { continuation.yield(event) }
                    }
                    for event in try parser.feed(Data(), eof: true) { continuation.yield(event) }
                    process.waitUntilExit(); stderrDone.wait()
                    if control.cancelled { throw CancellationError() }
                    if process.terminationStatus != 0 && !parser.sawFailure && !parser.sawDenial {
                        throw AppError.message(errors.text.isEmpty ? "\(config.displayName) exited with code \(process.terminationStatus)." : errors.text)
                    }
                    guard parser.sawResult || parser.sawFailure else {
                        throw AppError.message("Agent exited without a result. \(errors.text)")
                    }
                    continuation.finish()
                } catch {
                    control.cancel()
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    func cancel() async { active?.cancel() }
    func isAvailable() async -> Bool { FileManager.default.isExecutableFile(atPath: config.binaryPath) }
}

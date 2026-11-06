import Foundation
import AppKit

struct ModelOption: Identifiable { var id: String; var name: String }

struct CommandResult { var output: Data; var status: Int32 }
enum LocalCommand {
    static func run(binary: String, arguments: [String], environment: CLIEnvironment, input: Data? = nil) async throws -> CommandResult {
        try await Task.detached {
            let process = Process(), pipe = Pipe(), stdin = Pipe(), control = ProcessControl()
            process.executableURL = URL(fileURLWithPath: binary); process.arguments = arguments
            var variables = ProcessInfo.processInfo.environment
            variables["PATH"] = environment.path; variables.removeValue(forKey: "CLAUDECODE")
            process.environment = variables
            process.standardOutput = pipe; process.standardError = pipe
            process.standardInput = input == nil ? FileHandle.nullDevice : stdin
            let timeout = DispatchWorkItem { control.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: timeout)
            defer { timeout.cancel() }
            try control.start(process)
            if let input { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
            var data = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                if data.count > 1024 * 1024 { control.cancel(); throw AppError.message("Command returned too much data.") }
            }
            process.waitUntilExit()
            if control.cancelled { throw AppError.message("Command timed out. Check the executable in Settings.") }
            return CommandResult(output: data, status: process.terminationStatus)
        }.value
    }
    static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func loginScript(config: AgentConfiguration, environment: CLIEnvironment) -> String {
        let arguments = config.adapterType == .codex ? "login" : config.adapterType == .hermes ? "setup model" : "auth login"
        return "#!/bin/zsh\nexport PATH=\(shellQuote(environment.path))\n\(shellQuote(config.binaryPath)) \(arguments)\nprint '\nReturn to AgentDrop and click Refresh login.'\n"
    }
}

struct CodexChat: Identifiable {
    var id: String
    var name: String
    var preview: String
    var cwd: String
    var date: Date
    var active: Bool
    init?(_ object: [String: Any]) {
        guard let id = object["id"] as? String, UUID(uuidString: id) != nil,
              let cwd = object["cwd"] as? String else { return nil }
        self.id = id; self.cwd = cwd
        preview = object["preview"] as? String ?? ""
        name = object["name"] as? String ?? String(preview.prefix(100))
        if name.isEmpty { name = "Untitled conversation" }
        date = Date(timeIntervalSince1970: object["updatedAt"] as? Double ?? 0)
        active = (object["status"] as? [String: Any])?["type"] as? String == "active"
    }
}

enum CodexHistory {
    // Read-only app-server methods, verified from this installed binary's generated schema.
    static func request(config: AgentConfiguration, environment: CLIEnvironment, method: String, params: [String: Any]) async throws -> [String: Any] {
        try await Task.detached {
            let process = Process(), stdout = Pipe(), stdin = Pipe(), control = ProcessControl()
            process.executableURL = URL(fileURLWithPath: config.binaryPath)
            process.arguments = ["app-server"]
            var variables = ProcessInfo.processInfo.environment; variables["PATH"] = environment.path
            process.environment = variables
            process.standardOutput = stdout; process.standardError = FileHandle.nullDevice; process.standardInput = stdin
            let timeout = DispatchWorkItem { control.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
            defer { timeout.cancel(); control.cancel(); try? stdin.fileHandleForWriting.close() }
            try control.start(process)
            func write(_ object: [String: Any]) throws {
                var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
                try stdin.fileHandleForWriting.write(contentsOf: data)
            }
            try write(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "agentdrop", "version": "0.1.0"]]])
            var buffer = Data()
            while true {
                let data = stdout.fileHandleForReading.availableData
                if data.isEmpty { break }; buffer.append(data)
                guard buffer.count <= 32 * 1024 * 1024 else { throw AppError.message("This chat is too large to preview in AgentDrop.") }
                while let index = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<index]); buffer.removeSubrange(...index)
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any], let id = object["id"] as? Int else { continue }
                    if let error = object["error"] as? [String: Any] {
                        throw AppError.message(error["message"] as? String ?? "Codex history request failed.")
                    }
                    if id == 1 {
                        try write(["method": "initialized"])
                        try write(["id": 2, "method": method, "params": params])
                    } else if id == 2, let result = object["result"] as? [String: Any] { return result }
                }
            }
            throw AppError.message(control.cancelled ? "Codex history timed out." : "Codex history is unavailable. Check your executable and login.")
        }.value
    }
    static func messages(thread: [String: Any]) -> [ChatMessage] {
        let turns = thread["turns"] as? [[String: Any]] ?? []
        var messages: [ChatMessage] = []
        for turn in turns {
            let date = Date(timeIntervalSince1970: turn["startedAt"] as? Double ?? thread["createdAt"] as? Double ?? 0)
            for item in turn["items"] as? [[String: Any]] ?? [] {
                if item["type"] as? String == "agentMessage", let text = item["text"] as? String, !text.isEmpty {
                    messages.append(.init(role: .assistant, text: text, date: date))
                } else if item["type"] as? String == "userMessage" {
                    let content = item["content"] as? [[String: Any]] ?? []
                    let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !text.isEmpty { messages.append(.init(role: .user, text: text, date: date)) }
                }
            }
        }
        return messages
    }
}

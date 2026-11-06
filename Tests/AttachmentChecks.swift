import Foundation
@main struct AttachmentChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDrop-attachment-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("context file.txt")
        try Data("The verification word in this file is SUNFLOWER.\n".utf8).write(to: file)
        let environment = await CLIEnvironment.discover()
        var config = AgentConfiguration.defaults[1]
        config.binaryPath = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
        config.workingDirectory = root.path
        let adapter = CLIAdapter(config: config, environment: environment, sessionID: nil)
        let watchdog = Task { try await Task.sleep(nanoseconds: 90_000_000_000); await adapter.cancel() }
        defer { watchdog.cancel() }
        var answer = ""
        for try await event in adapter.send(.init(text: "Read the attached context file. Reply with only its verification word.", attachments: [file])) {
            if case let .text(text) = event { answer += text }
            if case let .failed(error) = event { throw AppError.message(error) }
        }
        guard answer.contains("SUNFLOWER") else { throw AppError.message("Attachment was not read: \(answer)") }
        let store = try LocalStore(root: root.appendingPathComponent("store"))
        let message = ChatMessage(role: .user, text: "context", attachments: [Attachment(url: file)], voiceNote: .init(duration: 2, audioURL: file, transcript: "hello"))
        try store.save(Conversation(messages: [message]), name: "test.json")
        let restored = try store.load(Conversation.self, name: "test.json")
        guard restored?.messages.first?.attachments?.first?.url == file, restored?.messages.first?.voiceNote?.transcript == "hello" else { throw AppError.message("Attachment/voice persistence failed") }
        print("PASS: live Codex attachment read and attachment/voice persistence")
    }
}

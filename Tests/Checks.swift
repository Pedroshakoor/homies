import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppError.message("CHECK FAILED: \(message)") }
}
func texts(_ events: [AgentEvent]) -> String {
    events.compactMap { if case let .text(text) = $0 { return text }; return nil }.joined()
}
func line(_ object: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: object); data.append(10); return data
}
@main struct Checks {
    static func main() async {
        do {
            try parserChecks()
            try persistenceChecks()
            try historyChecks()
            try await processChecks()
            if let index = CommandLine.arguments.firstIndex(of: "--live"), CommandLine.arguments.count > index + 2 {
                let kind = CommandLine.arguments[index + 1] == "codex" ? AdapterKind.codex : CommandLine.arguments[index + 1] == "hermes" ? .hermes : .claudeCode
                try await live(kind: kind, binary: CommandLine.arguments[index + 2])
            }
            print("PASS: all requested checks")
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func parserChecks() throws {
        let id = UUID().uuidString
        let packets: [[String: Any]] = [
            ["type": "system", "subtype": "init", "session_id": id],
            ["type": "stream_event", "event": ["type": "message_start"]],
            ["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Hello 🌸"]]],
            ["type": "assistant", "message": ["content": [["type": "text", "text": "Hello 🌸"]]]],
            ["type": "stream_event", "event": ["type": "content_block_start", "content_block": ["type": "tool_use", "id": "tool1", "name": "Read"]]],
            ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "tool1", "name": "Read"]]]],
            ["type": "result", "is_error": false, "permission_denials": [["tool_name": "Bash"]]]
        ]
        var parser = EventParser(kind: .claudeCode), output: [AgentEvent] = []
        let bytes = try packets.reduce(into: Data()) { $0.append(try line($1)) }
        for byte in bytes { output += try parser.feed(Data([byte])) }
        output += try parser.feed(Data(), eof: true)
        try require(texts(output) == "Hello 🌸", "fragmented UTF-8 and deduplicated assistant text")
        try require(parser.sessionID == id && parser.sawResult && parser.sawDenial, "session and denial")
        try require(output.filter { if case .toolCall = $0 { return true }; return false }.count == 1, "tool deduplication")
        var codex = EventParser(kind: .codex)
        var codexOutput = try codex.feed(line(["type": "thread.started", "thread_id": id]))
        codexOutput += try codex.feed(line(["type": "item.updated", "item": ["type": "agent_message", "id": "1", "text": "Hi"]]))
        codexOutput += try codex.feed(line(["type": "item.completed", "item": ["type": "agent_message", "id": "1", "text": "Hi there"]]))
        codexOutput += try codex.feed(Data("{\"type\":\"turn.completed\"}".utf8), eof: true)
        try require(texts(codexOutput) == "Hi there" && codex.sawResult && codex.sessionID == id, "Codex items and no trailing newline")
        var bad = EventParser(kind: .codex)
        do { _ = try bad.feed(Data("not json\n".utf8)); throw AppError.message("CHECK FAILED: invalid JSON accepted") }
        catch is DecodingError {} catch let error as NSError where error.domain == NSCocoaErrorDomain {}
        var failure = EventParser(kind: .codex)
        _ = try failure.feed(line(["type": "turn.failed", "error": ["message": "No login"]]))
        try require(failure.sawFailure, "structured failure")
        var hermes = EventParser(kind: .hermes)
        var stream = try hermes.feed(line(["type": "system", "subtype": "init", "session_id": "20261106_hermes-test"]))
        stream += try hermes.feed(line(["type": "text", "text": "Hello "]))
        stream += try hermes.feed(line(["type": "result", "exit_code": 0, "text": "Hello Hermes", "session_id": "20261106_hermes-test"]))
        try require(texts(stream) == "Hello Hermes" && hermes.sawResult && hermes.sessionID == "20261106_hermes-test", "Hermes deltas and non-UUID session")
        var detached = EventParser(kind: .hermes)
        _ = try detached.feed(line(["type": "result", "exit_code": 3, "text": "", "error": "Input required"]))
        try require(detached.sawDenial, "Hermes interactive handoff")
        let hermesResume = CLIAdapter.arguments(kind: .hermes, sessionID: "20261106_hermes-test")
        try require(hermesResume.contains("--resume") && !hermesResume.contains("--no-restore-cwd"), "gateway-compatible Hermes resume")
        let writeArgs = CLIAdapter.arguments(kind: .codex, sessionID: nil, allowProjectEdits: true)
        try require(writeArgs.contains("workspace-write") && !writeArgs.contains("danger-full-access"), "bounded Codex project edits")
        print("PASS: stream parsing, sessions, denials, malformed output")
    }
    static func persistenceChecks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdrop-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalStore(root: root)
        var conversation = Conversation(messages: [.init(role: .user, text: "old", date: Date().addingTimeInterval(-86400 * 4)), .init(role: .assistant, text: "new")], sessionID: UUID().uuidString)
        try store.save(conversation, name: "test.json")
        let restored = try store.load(Conversation.self, name: "test.json")
        try require(restored?.messages.count == 2, "history roundtrip")
        conversation.prune(.never)
        try require(conversation.messages.count == 2, "never retention")
        conversation.prune(.threeDays)
        try require(conversation.messages.count == 1 && conversation.sessionID == nil, "expiry and session reset")
        try store.save(restored, name: "codex-archive-test.json")
        try store.pruneArchives(agentID: "codex", retention: .threeDays)
        let archived = try store.load(Conversation.self, name: "codex-archive-test.json")
        try require(archived?.messages.count == 1 && archived?.sessionID == nil, "archived history also expires")
        try Data("broken".utf8).write(to: root.appendingPathComponent("test.json"))
        do { _ = try store.load(Conversation.self, name: "test.json"); throw AppError.message("CHECK FAILED: corrupt history accepted") }
        catch is DecodingError {}
        print("PASS: persistence, retention, corrupt-history protection")
    }
    static func processChecks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdrop-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fake-agent")
        let script = """
        #!/bin/zsh
        input=$(cat)
        if [[ "$input" == "fail" ]]; then print -u2 'Expected process failure'; exit 7; fi
        if [[ "$input" == "wait" ]]; then sleep 30; fi
        print '{"type":"thread.started","thread_id":"00000000-0000-0000-0000-000000000001"}'
        print '{"type":"item.completed","item":{"id":"1","type":"agent_message","text":"process ok"}}'
        print '{"type":"turn.completed"}'
        """
        try Data(script.utf8).write(to: fixture)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.path)
        var config = AgentConfiguration.defaults[1]; config.binaryPath = fixture.path; config.workingDirectory = root.path
        let adapter = CLIAdapter(config: config, environment: .init(path: "/usr/bin:/bin"), sessionID: nil)
        var events: [AgentEvent] = []
        for try await event in adapter.send(.init(text: "test")) { events.append(event) }
        try require(texts(events) == "process ok", "real subprocess piping")
        do {
            for try await _ in adapter.send(.init(text: "fail")) {}
            throw AppError.message("CHECK FAILED: process failure swallowed")
        } catch AppError.message(let message) { try require(message.contains("Expected process failure"), "stderr surfaced") }
        let cancellation = Task {
            for try await _ in adapter.send(.init(text: "wait")) {}
        }
        try await Task.sleep(nanoseconds: 200_000_000)
        cancellation.cancel(); await adapter.cancel()
        do { try await cancellation.value } catch is CancellationError {}
        print("PASS: subprocess stdin/stdout, stderr, exit errors, cancellation")
    }
    static func live(kind: AdapterKind, binary: String) async throws {
        var config = AgentConfiguration.defaults[kind == .codex ? 1 : kind == .hermes ? 2 : 0]
        config.binaryPath = binary
        if let index = CommandLine.arguments.firstIndex(of: "--model"), CommandLine.arguments.count > index + 1 {
            config.model = CommandLine.arguments[index + 1]
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agentdrop-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        config.workingDirectory = root.path
        let env = await CLIEnvironment.discover()
        let adapter = CLIAdapter(config: config, environment: env, sessionID: nil)
        let watchdog = Task { try await Task.sleep(nanoseconds: 90_000_000_000); await adapter.cancel() }
        defer { watchdog.cancel() }
        var session: String?, first = "", failure: String?
        for try await event in adapter.send(.init(text: "Remember the word MARIGOLD for this conversation. Reply only MARIGOLD. Do not use tools.")) {
            switch event {
            case .sessionID(let id): session = id
            case .text(let text): first += text
            case .failed(let text): failure = text
            default: break
            }
        }
        if let failure { throw AppError.message(failure) }
        try require(first.contains("MARIGOLD") && session != nil, "live first reply + session id")
        adapter.sessionID = session
        var followup = ""
        for try await event in adapter.send(.init(text: "What word did I ask you to remember? Reply only with that word. Do not use tools.")) {
            if case let .text(text) = event { followup += text }
            if case let .failed(text) = event { throw AppError.message(text) }
        }
        try require(followup.contains("MARIGOLD"), "live resumed conversation")
        print("PASS: LIVE \(config.displayName) first reply + resumed follow-up")
        let login = try await LocalCommand.run(binary: binary, arguments: kind == .codex ? ["login", "status"] : kind == .hermes ? ["auth", "status", "openai-codex"] : ["auth", "status", "--json"], environment: env)
        try require(login.status == 0, "live login status")
        if kind == .codex {
            let result = try await CodexHistory.request(config: config, environment: env, method: "thread/list", params: ["limit": 5, "sourceKinds": ["exec"], "searchTerm": "MARIGOLD"])
            let chats = (result["data"] as? [[String: Any]] ?? []).compactMap(CodexChat.init)
            try require(!chats.isEmpty, "live existing-chat list")
            guard let session else { throw AppError.message("No session to preview") }
            let read = try await CodexHistory.request(config: config, environment: env, method: "thread/read", params: ["threadId": session, "includeTurns": true])
            let thread = read["thread"] as? [String: Any] ?? [:]
            let messages = CodexHistory.messages(thread: thread)
            try require(messages.contains { $0.text.contains("MARIGOLD") }, "live chat preview")
            print("PASS: LIVE Codex login status, chat search, and transcript read")
        }
    }
    static func historyChecks() throws {
        let thread: [String: Any] = ["createdAt": 1700000000.0, "turns": [["startedAt": 1700000001.0, "items": [
            ["type": "userMessage", "content": [["type": "text", "text": "hello"], ["type": "localImage", "path": "/tmp/image.png"]]],
            ["type": "agentMessage", "text": "world"], ["type": "reasoning", "summary": ["private"]]
        ]]]]
        let messages = CodexHistory.messages(thread: thread)
        try require(messages.count == 2 && messages[0].text == "hello" && messages[1].text == "world", "history imports text without tool internals")
        let quoted = LocalCommand.shellQuote("/tmp/a'file $(touch nope)")
        try require(quoted == "'/tmp/a'\\''file $(touch nope)'", "login path is shell-quoted")
        let args = CLIAdapter.arguments(kind: .codex, sessionID: nil)
        try require(!args.contains("--ignore-user-config"), "Codex reuses global settings")
        print("PASS: chat preview conversion, login quoting, shared Codex settings")
    }
}

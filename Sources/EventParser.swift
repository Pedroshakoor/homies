import Foundation

// These envelopes are verified against the installed CLI help/source and the official docs.
struct EventParser {
    let kind: AdapterKind
    private var buffer = Data()
    private var streamedMessage = false
    private var toolIDs = Set<String>()
    private var itemText: [String: String] = [:]
    private var hermesText = ""
    private(set) var sawResult = false
    private(set) var sawFailure = false
    private(set) var sawDenial = false
    private(set) var sessionID: String?

    init(kind: AdapterKind) { self.kind = kind }
    mutating func feed(_ data: Data, eof: Bool = false) throws -> [AgentEvent] {
        buffer.append(data)
        guard buffer.count <= 8 * 1024 * 1024 else { throw AppError.message("Agent sent an oversized JSON event.") }
        var events: [AgentEvent] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            events += try parse(line)
        }
        if eof && !buffer.isEmpty {
            events += try parse(buffer)
            buffer.removeAll()
        }
        return events
    }
    private mutating func parse(_ data: Data) throws -> [AgentEvent] {
        guard !data.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) else { return [] }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppError.message("Agent emitted a JSON event that is not an object.")
        }
        switch kind {
        case .claudeCode: return claude(object)
        case .codex: return codex(object)
        case .hermes: return hermes(object)
        }
    }
    private mutating func hermes(_ object: [String: Any]) -> [AgentEvent] {
        var output: [AgentEvent] = []
        if let id = object["session_id"] as? String, !id.isEmpty, id.count <= 128,
           id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }), id != sessionID {
            sessionID = id; output.append(.sessionID(id))
        }
        switch object["type"] as? String {
        case "text":
            if let text = object["text"] as? String { hermesText += text; output += [.status(.thinking), .text(text)] }
        case "tool_use": output.append(.toolCall(name: object["name"] as? String ?? "tool"))
        case "tool_result": output.append(.status(.thinking))
        case "result":
            sawResult = true
            if let text = object["text"] as? String, !text.isEmpty {
                if text.hasPrefix(hermesText) {
                    let tail = String(text.dropFirst(hermesText.count)); if !tail.isEmpty { output.append(.text(tail)) }
                } else { output.append(.replaceText(text)) }
            }
            let exitCode = object["exit_code"] as? Int ?? 1
            if exitCode == 3 {
                sawDenial = true
                output.append(.needsApproval("Hermes needs input in Terminal. \(object["error"] as? String ?? "Resume this session in Hermes to continue.")"))
            } else if exitCode != 0 {
                sawFailure = true; output.append(.failed(object["error"] as? String ?? "Hermes stopped with code \(exitCode)."))
            } else { output.append(.finished) }
        default: break
        }
        return output
    }
    private mutating func claude(_ o: [String: Any]) -> [AgentEvent] {
        var output: [AgentEvent] = []
        if let id = o["session_id"] as? String, UUID(uuidString: id) != nil, id != sessionID {
            sessionID = id; output.append(.sessionID(id))
        }
        // Do not merge a nested agent's transcript into the main reply.
        if let parent = o["parent_tool_use_id"] as? String, !parent.isEmpty { return output }
        switch o["type"] as? String {
        case "stream_event":
            guard let event = o["event"] as? [String: Any] else { break }
            switch event["type"] as? String {
            case "message_start": streamedMessage = false
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any] { output += tool(block) }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let text = delta["text"] as? String {
                    streamedMessage = true
                    output += [.status(.thinking), .text(text)]
                }
            default: break
            }
        case "assistant":
            if let message = o["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] {
                for block in blocks {
                    output += tool(block)
                    if !streamedMessage, block["type"] as? String == "text", let text = block["text"] as? String {
                        output.append(.text(text))
                    }
                }
            }
        case "user": output.append(.status(.thinking))
        case "result":
            sawResult = true
            if let denials = o["permission_denials"] as? [[String: Any]], !denials.isEmpty {
                sawDenial = true
                let names = denials.compactMap { $0["tool_name"] as? String }.joined(separator: ", ")
                output.append(.needsApproval("Claude denied permission for \(names.isEmpty ? "a tool" : names). Headless mode cannot show an approval dialog. Approve the action in Claude Code in Terminal, then retry here."))
            }
            if o["is_error"] as? Bool == true {
                sawFailure = true
                let errors = (o["errors"] as? [String])?.joined(separator: "\n")
                output.append(.failed(errors ?? (o["result"] as? String) ?? "Claude Code failed."))
            } else { output.append(.finished) }
        default: break
        }
        return output
    }
    private mutating func tool(_ block: [String: Any]) -> [AgentEvent] {
        guard block["type"] as? String == "tool_use", let name = block["name"] as? String,
              let id = block["id"] as? String, toolIDs.insert(id).inserted else { return [] }
        return [.toolCall(name: name)]
    }
    private mutating func codex(_ o: [String: Any]) -> [AgentEvent] {
        switch o["type"] as? String {
        case "thread.started":
            guard let id = o["thread_id"] as? String, UUID(uuidString: id) != nil else { return [] }
            sessionID = id; return [.sessionID(id)]
        case "turn.started": return [.status(.thinking)]
        case "item.started", "item.updated", "item.completed":
            guard let item = o["item"] as? [String: Any], let type = item["type"] as? String else { return [] }
            if type == "agent_message", let text = item["text"] as? String, let id = item["id"] as? String {
                let previous = itemText[id] ?? ""
                itemText[id] = text
                guard text.hasPrefix(previous) else {
                    sawFailure = true
                    return [.failed("Codex revised an already emitted message; start a new conversation.")]
                }
                let delta = String(text.dropFirst(previous.count))
                return delta.isEmpty ? [] : [.text(delta)]
            }
            if ["command_execution", "mcp_tool_call", "file_change", "web_search"].contains(type) {
                return o["type"] as? String == "item.completed" ? [.status(.thinking)] : [.toolCall(name: type.replacingOccurrences(of: "_", with: " "))]
            }
            if type == "error" {
                sawFailure = true; return [.failed(item["message"] as? String ?? "Codex reported an error.")]
            }
            return []
        case "turn.completed": sawResult = true; return [.finished]
        case "turn.failed":
            sawResult = true; sawFailure = true
            let error = o["error"] as? [String: Any]
            return [.failed(error?["message"] as? String ?? "Codex turn failed.")]
        case "error":
            sawFailure = true; return [.failed(o["message"] as? String ?? "Codex failed.")]
        default: return []
        }
    }
}

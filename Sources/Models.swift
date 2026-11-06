import Foundation

enum AgentStatus: String { case idle, thinking, toolCalling, needsApproval, error
    var label: String {
        switch self {
        case .idle: return "idle"
        case .thinking: return "thinking"
        case .toolCalling: return "using a tool"
        case .needsApproval: return "needs attention"
        case .error: return "error"
        }
    }
}

struct OutgoingMessage { var text: String; var attachments: [URL] = [] }
enum AgentEvent {
    case text(String), replaceText(String), toolCall(name: String), needsApproval(String), status(AgentStatus)
    case sessionID(String), finished, failed(String)
}
protocol AgentAdapter: AnyObject {
    var id: String { get }
    var displayName: String { get }
    func send(_ message: OutgoingMessage) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel() async
    func isAvailable() async -> Bool
}

enum AdapterKind: String, Codable { case claudeCode, codex, hermes }
enum Retention: Int, Codable, CaseIterable, Identifiable {
    case never = 0, day = 1, threeDays = 3, week = 7, month = 30
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .never: return "Never"
        case .day: return "1 day"
        case .threeDays: return "3 days"
        case .week: return "1 week"
        case .month: return "1 month"
        }
    }
}
struct AgentConfiguration: Codable, Identifiable {
    var id: String
    var displayName: String
    var adapterType: AdapterKind
    var binaryPath: String
    var workingDirectory: String
    var avatarColor: String
    var avatarEmoji: String
    var retention: Retention
    var model: String?
    var allowProjectEdits: Bool?
    static let defaults: [Self] = [
        .init(id: "claude", displayName: "Claude Code", adapterType: .claudeCode,
              binaryPath: "", workingDirectory: "", avatarColor: "peach", avatarEmoji: "C", retention: .never),
        .init(id: "codex", displayName: "Codex", adapterType: .codex,
              binaryPath: "", workingDirectory: "", avatarColor: "mint", avatarEmoji: "X", retention: .never),
        .init(id: "hermes", displayName: "Hermes", adapterType: .hermes,
              binaryPath: "", workingDirectory: "", avatarColor: "peach", avatarEmoji: "H", retention: .never)
    ]
}
struct Attachment: Codable, Identifiable {
    var id = UUID()
    var name: String
    var url: URL
    var kind: String
    init(url: URL) {
        self.url = url; name = url.lastPathComponent
        kind = ["png", "jpg", "jpeg", "gif", "webp", "heic"].contains(url.pathExtension.lowercased()) ? "image" : "file"
    }
}
struct VoiceNote: Codable { var duration: Double; var audioURL: URL; var transcript: String? }
struct ChatMessage: Codable, Identifiable {
    enum Role: String, Codable { case user, assistant, notice }
    var id = UUID()
    var role: Role
    var text: String
    var date = Date()
    var attachments: [Attachment]?
    var voiceNote: VoiceNote?
}
struct Conversation: Codable {
    var messages: [ChatMessage] = []
    var sessionID: String?
    var draft: String?
    var draftAttachments: [Attachment]?
    var draftVoiceNote: VoiceNote?
    mutating func prune(_ retention: Retention, now: Date = Date()) {
        guard retention != .never else { return }
        let cutoff = now.addingTimeInterval(-Double(retention.rawValue) * 86400)
        let count = messages.count
        messages.removeAll { $0.date < cutoff }
        if messages.count != count { sessionID = nil }
    }
}

struct LocalStore {
    let root: URL
    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Homies", isDirectory: true)
        if root == nil, !FileManager.default.fileExists(atPath: self.root.path) {
            let previous = self.root.deletingLastPathComponent().appendingPathComponent("AgentDrop", isDirectory: true)
            if FileManager.default.fileExists(atPath: previous.path) {
                try FileManager.default.copyItem(at: previous, to: self.root)
            }
        }
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }
    func load<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let file = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }
    func save<T: Encodable>(_ value: T, name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = root.appendingPathComponent(name)
        try encoder.encode(value).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func configurations() throws -> [AgentConfiguration] {
        var configs = try load([AgentConfiguration].self, name: "agents.json") ?? AgentConfiguration.defaults
        if !configs.contains(where: { $0.adapterType == .hermes || $0.id == "hermes" }), let hermes = AgentConfiguration.defaults.last {
            configs.append(hermes)
        }
        guard !configs.isEmpty, Set(configs.map(\.id)).count == configs.count,
              configs.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.allSatisfy {
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              } }) else { throw AppError.message("Agent IDs must be unique and contain only letters, numbers, - or _.") }
        return configs
    }
    func pruneArchives(agentID: String, retention: Retention) throws {
        guard retention != .never else { return }
        for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where file.lastPathComponent.hasPrefix(agentID + "-archive-") && file.pathExtension == "json" {
            guard var archived = try load(Conversation.self, name: file.lastPathComponent) else { continue }
            let count = archived.messages.count
            archived.prune(retention)
            if archived.messages.count != count { try save(archived, name: file.lastPathComponent) }
        }
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

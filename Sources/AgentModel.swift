import AppKit
import Combine

@MainActor final class AgentModel: ObservableObject, Identifiable {
    @Published var config: AgentConfiguration
    @Published var conversation: Conversation
    @Published var status: AgentStatus = .idle
    @Published var draft = "" { didSet { draftVersion += 1 } }
    var draftVersion = 0
    var draftOrigin = ""
    @Published var isRunning = false
    @Published var error: String?
    @Published var retryable = false
    @Published var attachments: [Attachment] = [] { didSet { persist() } }
    @Published var pendingVoice: VoiceNote? { didSet { persist() } }
    @Published var captureTargets: [CaptureTarget] = []
    @Published var activity = ""
    @Published var loginStatus = "Checking login…"
    @Published var signedIn = false
    @Published var checkingLogin = false
    @Published var availableModels: [ModelOption] = []
    @Published var modelError: String?
    var onConfigurationChanged: (() throws -> Void)?
    var onStatusChanged: (() -> Void)?
    let store: LocalStore
    private var adapter: CLIAdapter?
    private var task: Task<Void, Never>?
    var environment = CLIEnvironment(path: "/usr/bin:/bin")
    nonisolated let id: String
    var canSend: Bool { !isRunning && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty) }

    init(config: AgentConfiguration, store: LocalStore) throws {
        self.id = config.id; self.config = config; self.store = store
        conversation = try store.load(Conversation.self, name: "\(config.id).json") ?? Conversation()
        conversation.prune(config.retention)
        draft = conversation.draft ?? ""
        attachments = conversation.draftAttachments ?? []
        pendingVoice = conversation.draftVoiceNote
        try store.save(conversation, name: "\(config.id).json")
    }
    func persist() {
        conversation.draft = draft
        conversation.draftAttachments = attachments
        conversation.draftVoiceNote = pendingVoice
        do { try store.save(conversation, name: "\(id).json") }
        catch { self.error = "Could not save history: \(error.localizedDescription)" }
    }
    func prune() {
        guard !isRunning else { return }
        let count = conversation.messages.count
        conversation.prune(config.retention)
        if count != conversation.messages.count { persist() }
        do { try store.pruneArchives(agentID: id, retention: config.retention) }
        catch { self.error = "Could not update archived history: \(error.localizedDescription)" }
    }
    func configure(_ edit: (inout AgentConfiguration) -> Void) {
        let previous = config
        edit(&config)
        do { try onConfigurationChanged?() }
        catch { config = previous; self.error = "Could not save settings: \(error.localizedDescription)"; return }
        if config.adapterType == .hermes, previous.model != config.model, conversation.sessionID != nil { newConversation() }
        prune()
        onStatusChanged?()
    }
    func chooseDirectory() {
        guard !isRunning else { return }
        let picker = NSOpenPanel()
        picker.canChooseDirectories = true; picker.canChooseFiles = false
        picker.prompt = "Use folder"
        picker.message = "Choose a trusted working folder for \(config.displayName)."
        let previous = config.workingDirectory
        if !config.workingDirectory.isEmpty { picker.directoryURL = URL(fileURLWithPath: config.workingDirectory) }
        guard picker.runModal() == .OK, let url = picker.url else { return }
        configure { $0.workingDirectory = url.path }
        // A session belongs to its original working directory.
        if config.workingDirectory != previous, conversation.sessionID != nil {
            newConversation()
        }
    }
    func chooseBinary() {
        let picker = NSOpenPanel()
        picker.prompt = "Use executable"
        picker.message = "Choose the installed \(config.displayName) command-line executable."
        picker.showsHiddenFiles = true
        guard picker.runModal() == .OK, let url = picker.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else { error = "That file is not executable."; return }
        configure { $0.binaryPath = url.path }
    }
    func newConversation() {
        guard !isRunning else { return }
        if !conversation.messages.isEmpty {
            do { try store.save(conversation, name: "\(id)-archive-\(UUID().uuidString).json") }
            catch { self.error = "Could not start a new session: \(error.localizedDescription)"; return }
        }
        conversation = Conversation()
        draftOrigin = ""; draft = ""; attachments = []; pendingVoice = nil
        status = .idle; error = nil; activity = ""; retryable = false
        persist(); onStatusChanged?()
    }
    func send() {
        guard canSend else { return }
        guard !config.workingDirectory.isEmpty else { chooseDirectory(); return }
        guard !config.binaryPath.isEmpty else { error = "\(config.displayName) was not found. Choose its executable in Settings."; return }
        prune()
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""; error = nil; activity = ""; retryable = false
        let files = attachments
        conversation.messages.append(.init(role: .user, text: text, attachments: files, voiceNote: pendingVoice))
        attachments = []; pendingVoice = nil
        let reply = ChatMessage(role: .assistant, text: "")
        conversation.messages.append(reply)
        persist()
        isRunning = true; status = .thinking; onStatusChanged?()
        let adapter = CLIAdapter(config: config, environment: environment, sessionID: conversation.sessionID)
        self.adapter = adapter
        task = Task { [weak self] in
            guard let self else { return }
            var failed = false, denied = false
            do {
                for try await event in adapter.send(.init(text: text, attachments: files.map(\.url))) {
                    switch event {
                    case .text(let fragment):
                        if let index = conversation.messages.firstIndex(where: { $0.id == reply.id }) {
                            conversation.messages[index].text += fragment
                        }
                    case .replaceText(let text):
                        if let index = conversation.messages.firstIndex(where: { $0.id == reply.id }) { conversation.messages[index].text = text }
                    case .sessionID(let id): conversation.sessionID = id; persist()
                    case .status(let value): status = denied ? .needsApproval : value
                    case .toolCall(let name): status = .toolCalling; activity = name
                    case .needsApproval(let reason):
                        denied = true; status = .needsApproval
                        conversation.messages.append(.init(role: .notice, text: reason))
                    case .failed(let reason): failed = true; error = reason; status = .error
                    case .finished: break
                    }
                    onStatusChanged?()
                }
            } catch is CancellationError {
                conversation.messages.append(.init(role: .notice, text: "Stopped"))
            } catch { failed = true; self.error = error.localizedDescription }
            conversation.messages.removeAll { $0.id == reply.id && $0.text.isEmpty }
            isRunning = false; activity = ""
            retryable = failed
            status = failed ? .error : denied ? .needsApproval : .idle
            self.adapter = nil; task = nil
            persist(); onStatusChanged?()
        }
    }
    func stop() {
        let current = adapter, runTask = task
        Task {
            if config.adapterType == .hermes, config.binaryPath.hasSuffix("/.runtime/hermes"), let session = conversation.sessionID {
                do {
                    let result = try await LocalCommand.run(binary: config.binaryPath, arguments: ["--agentdrop-interrupt", session], environment: environment)
                    if result.status != 0 { self.error = "Could not confirm that Hermes stopped. Continue in Terminal to check the run." }
                } catch { self.error = error.localizedDescription }
            }
            runTask?.cancel(); await current?.cancel()
        }
    }
    func refreshLogin() async {
        guard !checkingLogin else { return }
        guard !config.binaryPath.isEmpty else { loginStatus = "CLI not found"; return }
        checkingLogin = true
        defer { checkingLogin = false }
        do {
            if config.adapterType == .hermes {
                let settings = try await hermesModel()
                let provider = settings.provider
                guard !provider.isEmpty else { signedIn = false; loginStatus = "Set up Hermes in Terminal"; return }
                let result = try await LocalCommand.run(binary: config.binaryPath, arguments: ["auth", "status", provider], environment: environment)
                let text = String(decoding: result.output, as: UTF8.self)
                signedIn = text.components(separatedBy: .newlines).contains("\(provider): logged in")
                loginStatus = signedIn ? "Connected to Hermes · \(provider)" : "Hermes · \(provider) · sign-in required"
                return
            }
            let arguments = config.adapterType == .codex ? ["login", "status"] : ["auth", "status", "--json"]
            let result = try await LocalCommand.run(binary: config.binaryPath, arguments: arguments, environment: environment)
            if config.adapterType == .claudeCode {
                let object = try JSONSerialization.jsonObject(with: result.output) as? [String: Any]
                signedIn = object?["loggedIn"] as? Bool ?? false
                loginStatus = signedIn ? "Connected to Claude Code" : "Not signed in"
            } else {
                signedIn = result.status == 0
                loginStatus = signedIn ? "Connected to your Codex account" : "Not signed in"
            }
        } catch { signedIn = false; loginStatus = error.localizedDescription }
    }
    func refreshModels() async {
        if config.adapterType == .hermes {
            do {
                let settings = try await hermesModel()
                availableModels = settings.model.isEmpty ? [] : [.init(id: settings.model, name: settings.model)]
                modelError = nil
            } catch { modelError = error.localizedDescription }
            return
        }
        if config.adapterType == .claudeCode {
            availableModels = [.init(id: "sonnet", name: "Sonnet"), .init(id: "opus", name: "Opus")]
            return
        }
        guard !config.binaryPath.isEmpty else { return }
        do {
            let result = try await CodexHistory.request(config: config, environment: environment, method: "model/list", params: [:])
            availableModels = (result["data"] as? [[String: Any]] ?? []).compactMap {
                guard let id = $0["model"] as? String else { return nil }
                return ModelOption(id: id, name: $0["displayName"] as? String ?? id)
            }
            modelError = nil
        } catch { modelError = error.localizedDescription }
    }
    func logIn() {
        guard !signedIn else { return }
        guard !config.binaryPath.isEmpty else { error = "Choose the agent executable first."; return }
        do {
            let file = store.root.appendingPathComponent("login-\(id).command")
            try Data(LocalCommand.loginScript(config: config, environment: environment).utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
            loginStatus = "Complete sign-in in Terminal, then refresh"
        } catch { self.error = "Could not open login: \(error.localizedDescription)" }
    }
    private func hermesModel() async throws -> (model: String, provider: String) {
        let result = try await LocalCommand.run(binary: config.binaryPath, arguments: ["config", "get", "model", "--json"], environment: environment)
        guard result.status == 0 else { throw AppError.message("Could not read Hermes model settings.") }
        let value = try JSONSerialization.jsonObject(with: result.output, options: .fragmentsAllowed)
        let object = value as? [String: Any] ?? [:]
        return (object["default"] as? String ?? (value as? String ?? ""), object["provider"] as? String ?? "")
    }
    func configureModel() {
        guard !isRunning else { return }
        newConversation(); configure { $0.model = nil }
        openTerminal(arguments: ["model"], name: "model")
    }
    func openSession() {
        var args: [String] = []
        switch config.adapterType {
        case .codex: args = ["resume"]
        case .claudeCode: args = ["--resume"]
        case .hermes: args = ["chat", "--resume"]
        }
        guard let session = conversation.sessionID else { error = "Send a message first to create a session."; return }
        openTerminal(arguments: args + [session], name: "session")
    }
    private func openTerminal(arguments: [String], name: String) {
        guard !config.binaryPath.isEmpty else { error = "Choose the agent executable first."; return }
        do {
            let file = store.root.appendingPathComponent("\(name)-\(id).command")
            let script = "#!/bin/zsh\nexport PATH=\(LocalCommand.shellQuote(environment.path))\ncd \(LocalCommand.shellQuote(config.workingDirectory.isEmpty ? NSHomeDirectory() : config.workingDirectory))\nexec \(LocalCommand.shellQuote(config.binaryPath)) \(arguments.map(LocalCommand.shellQuote).joined(separator: " "))\n"
            try Data(script.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch { self.error = error.localizedDescription }
    }
    func retry() {
        guard retryable, !isRunning, let message = conversation.messages.last(where: { $0.role == .user }) else { return }
        draftOrigin = ""; draft = message.text; attachments = message.attachments ?? []; pendingVoice = message.voiceNote; send()
    }
    func resume(_ chat: CodexChat) async throws {
        guard !isRunning, !chat.active else { throw AppError.message("Wait for the current run to finish before resuming this chat.") }
        let result = try await CodexHistory.request(config: config, environment: environment, method: "thread/read", params: ["threadId": chat.id, "includeTurns": true])
        guard let thread = result["thread"] as? [String: Any], thread["id"] as? String == chat.id else { throw AppError.message("Codex returned an unexpected conversation.") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: chat.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AppError.message("This chat's project folder no longer exists: \(chat.cwd)")
        }
        if !conversation.messages.isEmpty { try store.save(conversation, name: "\(id)-archive-\(UUID().uuidString).json") }
        let oldConfig = config
        configure { $0.workingDirectory = chat.cwd }
        guard config.workingDirectory == chat.cwd else { config = oldConfig; throw AppError.message("Could not save the chat working folder.") }
        let messages = CodexHistory.messages(thread: thread)
        conversation = Conversation(messages: Array(messages.suffix(100)), sessionID: chat.id)
        conversation.messages.insert(.init(role: .notice, text: "Resumed from Codex · showing the latest \(min(messages.count, 100)) text messages. The agent keeps its full session context."), at: 0)
        status = .idle; error = nil; persist(); onStatusChanged?()
    }
}

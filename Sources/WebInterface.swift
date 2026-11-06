import AppKit
import SwiftUI
import WebKit
import Combine

fileprivate final class BundledAssets: NSObject, WKURLSchemeHandler {
    var attachments: [String: URL] = [:]
    let root: URL
    init(root: URL) { self.root = root.standardizedFileURL; super.init() }
    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let request = urlSchemeTask.request.url else { return }
        let relative = request.path == "/" ? "index.html" : String(request.path.dropFirst())
        let file: URL
        if request.host == "attachment" {
            guard let owned = attachments[relative] else { urlSchemeTask.didFailWithError(AppError.message("Attachment unavailable")); return }
            file = owned
        } else { file = root.appendingPathComponent(relative).standardizedFileURL }
        guard request.host == "attachment" || file.path.hasPrefix(root.path + "/") else {
            urlSchemeTask.didFailWithError(AppError.message("Invalid asset path")); return
        }
        do {
            let data = try Data(contentsOf: file)
            let mime: String
            switch file.pathExtension {
            case "html": mime = "text/html"
            case "js": mime = "application/javascript"
            case "css": mime = "text/css"
            case "svg": mime = "image/svg+xml"
            case "png": mime = "image/png"
            case "gif": mime = "image/gif"
            case "jpg", "jpeg": mime = "image/jpeg"
            case "webp": mime = "image/webp"
            case "caf": mime = "audio/x-caf"
            case "m4a": mime = "audio/mp4"
            case "wav": mime = "audio/wav"
            case "pdf": mime = "application/pdf"
            default: mime = "application/octet-stream"
            }
            urlSchemeTask.didReceive(URLResponse(url: request, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
            urlSchemeTask.didReceive(data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

private final class TransparentWebView: WKWebView {
    override var isOpaque: Bool { false }
    var appearanceChanged: (() -> Void)?
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }
}

struct WebConversationView: NSViewRepresentable {
    @ObservedObject var selection: AgentSelection
    var expanded: Bool
    var expand: () -> Void
    func makeCoordinator() -> WebCoordinator { WebCoordinator(selection: selection, expanded: expanded, expand: expand) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let root = Bundle.main.resourceURL!.appendingPathComponent("Frontend", isDirectory: true)
        let assets = BundledAssets(root: root)
        config.setURLSchemeHandler(assets, forURLScheme: "homies")
        context.coordinator.assets = assets
        config.userContentController.add(context.coordinator, name: "homies")
        let webView = TransparentWebView(frame: .zero, configuration: config)
        // macOS WebKit's page painter is separate from isOpaque and the overscroll color.
        // Keep it transparent so the native behind-window material can sample the desktop.
        // KVC resolves WebKit's _setDrawsBackground: selector on current macOS.
        // Checking for the unprefixed selector incorrectly skipped this setting.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = context.coordinator
        webView.appearanceChanged = { [weak coordinator = context.coordinator] in coordinator?.pushState() }
        context.coordinator.webView = webView
        context.coordinator.monitorDrag()
        webView.load(URLRequest(url: URL(string: "homies://app/index.html")!, cachePolicy: .reloadIgnoringLocalCacheData))
        return webView
    }
    func updateNSView(_ nsView: WKWebView, context: Context) { context.coordinator.pushState() }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: WebCoordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "homies")
        coordinator.stopMonitoring()
    }
}

@MainActor final class WebCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let selection: AgentSelection
    let expanded: Bool
    let expand: () -> Void
    weak var webView: WKWebView?
    private var subscriptions = Set<AnyCancellable>()
    fileprivate var assets: BundledAssets?
    private var mouseMonitor: Any?
    private var mouseEvent: NSEvent?
    private let runtime = AppRuntime.shared
    private var ready = false
    func monitorDrag() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] event in
            if event.window == self?.webView?.window { self?.mouseEvent = event }
            return event
        }
    }
    func stopMonitoring() { if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil }
    private func mediaURL(_ url: URL, id: String) -> String {
        assets?.attachments[id] = url
        return "homies://attachment/" + id
    }
    private func attachmentState(_ file: Attachment) -> [String: Any] {
        var result: [String: Any] = ["id": file.id.uuidString, "name": file.name, "path": file.url.path, "kind": file.kind]
        if file.kind == "image" { result["previewURL"] = mediaURL(file.url, id: file.id.uuidString) }
        return result
    }
    private func messageState(_ message: ChatMessage) -> [String: Any] {
        var value: [String: Any] = ["id": message.id.uuidString, "role": message.role.rawValue, "text": message.text, "date": message.date.timeIntervalSince1970,
            "attachments": (message.attachments ?? []).map(attachmentState)]
        if let note = message.voiceNote { value["voiceNote"] = ["duration": note.duration, "audioURL": mediaURL(note.audioURL, id: message.id.uuidString + "-audio"), "transcript": note.transcript ?? ""] }
        return value
    }
    init(selection: AgentSelection, expanded: Bool, expand: @escaping () -> Void) {
        self.selection = selection; self.expanded = expanded; self.expand = expand
        super.init()
        let publishers = selection.models.map { $0.objectWillChange.eraseToAnyPublisher() } + [selection.objectWillChange.eraseToAnyPublisher(), runtime.objectWillChange.eraseToAnyPublisher(), runtime.voice.objectWillChange.eraseToAnyPublisher()]
        Publishers.MergeMany(publishers).sink { [weak self] _ in
            DispatchQueue.main.async { self?.pushState() }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in self?.pushState() }.store(in: &subscriptions)
    }
    func pushState(focusComposer: Bool = false) {
        guard ready, let webView else { return }
        let agents: [[String: Any]] = selection.models.map { model in
            ["id": model.id, "name": model.config.displayName, "kind": model.config.adapterType.rawValue,
             "draft": model.draft, "draftVersion": model.draftVersion, "draftOrigin": model.draftOrigin,
             "status": model.status.rawValue, "statusLabel": model.status.label,
             "running": model.isRunning, "retryable": model.retryable, "error": model.error as Any? ?? NSNull(), "activity": model.activity,
             "loginStatus": model.loginStatus, "signedIn": model.signedIn, "checkingLogin": model.checkingLogin,
             "workingDirectory": model.config.workingDirectory, "binaryPath": model.config.binaryPath,
             "retention": model.config.retention.rawValue, "model": model.config.model ?? "",
             "models": model.availableModels.map { ["id": $0.id, "name": $0.name] },
             "modelError": model.modelError as Any? ?? NSNull(),
             "allowProjectEdits": model.config.allowProjectEdits ?? false,
             "attachments": model.attachments.map(attachmentState),
             "captureTargets": model.captureTargets.map { ["id": $0.id, "label": $0.label, "kind": $0.kind] },
             "messages": model.conversation.messages.map(messageState)]
        }
        let color = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) ?? .systemBlue
        let accent = String(format: "#%02x%02x%02x", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
        let voiceState: String
        switch runtime.voice.state { case .idle: voiceState = "idle"; case .recording: voiceState = "recording"; case .transcribing: voiceState = "transcribing"; case .error: voiceState = "error" }
        let state: [String: Any] = ["selectedId": selection.selectedID, "agents": agents, "expanded": expanded,
                                   "dark": NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                                   "accent": accent,
                                   "voice": ["state": voiceState, "levels": runtime.voice.levels, "error": runtime.voice.error ?? runtime.error ?? ""],
                                   "hotkey": ["keyCode": runtime.keyCode, "modifiers": runtime.modifiers, "label": runtime.label]]
        webView.callAsyncJavaScript("window.homies?.receive(state); if (focusComposer) requestAnimationFrame(() => document.querySelector('textarea')?.focus())", arguments: ["state": state, "focusComposer": focusComposer], in: nil, in: .page) { _ in }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.webView?.url?.scheme == "homies",
              let payload = message.body as? [String: Any], let action = payload["action"] as? String else { return }
        let id = payload["id"] as? String ?? selection.selectedID
        guard let model = selection.models.first(where: { $0.id == id }) else { return }
        if ["attach", "importAttachment", "capture", "captureTargets", "pasteAttachments", "captureSelection", "voiceStart", "setHotkey"].contains(action) { model.retryable = false }
        switch action {
        case "ready":
            ready = true
            if let webView { webView.window?.makeFirstResponder(webView) }
            pushState(focusComposer: true)
            Task { await model.refreshModels(); pushState() }
        case "select":
            selection.selectedID = id
            Task { await model.refreshModels(); pushState() }
        case "draft":
            if let text = payload["text"] as? String, text.utf8.count <= 1024 * 1024 {
                model.draftOrigin = String((payload["client"] as? String ?? "").prefix(128)); model.draft = text
            }
        case "send":
            if let text = payload["text"] as? String, text.utf8.count <= 1024 * 1024 {
                model.draftOrigin = String((payload["client"] as? String ?? "").prefix(128)); model.draft = text; model.send()
            }
        case "stop": model.stop()
        case "expand": expand()
        case "close": webView?.window?.orderOut(nil)
        case "folder": model.chooseDirectory()
        case "binary": model.chooseBinary(); Task { await model.refreshLogin(); await model.refreshModels() }
        case "login": model.logIn()
        case "refreshLogin": Task { await model.refreshLogin() }
        case "models": Task { await model.refreshModels() }
        case "model":
            if let value = payload["value"] as? String, value.isEmpty || model.availableModels.contains(where: { $0.id == value }) {
                model.configure { $0.model = value }
            }
        case "retention":
            if let value = payload["value"] as? Int, let retention = Retention(rawValue: value) { model.configure { $0.retention = retention } }
        case "new": model.newConversation()
        case "dismissError": model.error = nil
        case "reveal": NSWorkspace.shared.open(model.store.root)
        case "copy":
            if let text = payload["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
        case "history":
            guard model.config.adapterType == .codex else { return }
            var params: [String: Any] = ["limit": 30, "sortKey": "updated_at", "sourceKinds": ["cli", "vscode", "exec", "appServer"]]
            if let search = payload["search"] as? String, !search.isEmpty { params["searchTerm"] = search }
            if let cursor = payload["cursor"] as? String { params["cursor"] = cursor }
            Task {
                do {
                    let result = try await CodexHistory.request(config: model.config, environment: model.environment, method: "thread/list", params: params)
                    let chats = (result["data"] as? [[String: Any]] ?? []).compactMap(CodexChat.init)
                    historyResponse(["chats": chats.map { ["id": $0.id, "name": $0.name, "preview": $0.preview, "cwd": $0.cwd, "date": $0.date.timeIntervalSince1970, "active": $0.active] }, "cursor": result["nextCursor"] ?? NSNull(), "append": payload["cursor"] != nil])
                } catch { historyResponse(["error": error.localizedDescription]) }
            }
        case "resume":
            guard model.config.adapterType == .codex, let chatID = payload["chatId"] as? String, UUID(uuidString: chatID) != nil else { return }
            Task {
                do {
                    let result = try await CodexHistory.request(config: model.config, environment: model.environment, method: "thread/read", params: ["threadId": chatID, "includeTurns": false])
                    guard let thread = result["thread"] as? [String: Any], let chat = CodexChat(thread) else { throw AppError.message("Could not load this chat") }
                    try await model.resume(chat)
                    historyResponse(["resumed": true])
                } catch { historyResponse(["error": error.localizedDescription]) }
            }
        case "attachmentError": model.error = String((payload["error"] as? String ?? "Could not import file.").prefix(200))
        case "pasteAttachments":
            do { model.attachments += try runtime.context.clipboardAttachments(agentID: id).map { Attachment(url: $0) } }
            catch { model.error = error.localizedDescription }
        case "attach":
            do { model.attachments += try runtime.context.importFiles(runtime.context.chooseFiles(agentID: id), agentID: id).map { Attachment(url: $0) } }
            catch { model.error = error.localizedDescription }
        case "importAttachment":
            guard let name = payload["name"] as? String, let encoded = payload["data"] as? String, encoded.utf8.count <= 36 * 1024 * 1024, let data = Data(base64Encoded: encoded) else { model.error = "Invalid or oversized attachment."; break }
            do { model.attachments.append(Attachment(url: try runtime.context.importData(data, filename: name, agentID: id))) }
            catch { model.error = error.localizedDescription }
        case "removeAttachment": model.attachments.removeAll { $0.id.uuidString == payload["attachmentId"] as? String }
        case "captureTargets":
            Task { do { model.captureTargets = try await runtime.context.listCaptureTargets() } catch { model.error = error.localizedDescription }; pushState() }
        case "capture":
            guard let target = payload["targetId"] as? String else { break }
            Task {
                do { model.attachments.append(Attachment(url: try await runtime.context.capture(targetID: target, agentID: id))) }
                catch { model.error = error.localizedDescription }
                pushState()
            }
        case "captureSelection": runtime.captureSelection(agent: model)
        case "voiceStart": runtime.startVoice(agent: model)
        case "voiceStop": runtime.stopVoice()
        case "setHotkey":
            if let key = payload["keyCode"] as? UInt32, let flags = payload["modifiers"] as? UInt32 { runtime.setHotkey(keyCode: key, modifiers: flags); if let error = runtime.error { model.error = error } }
        case "revealAttachment", "dragAttachment":
            let files = model.attachments + model.conversation.messages.flatMap { $0.attachments ?? [] }
            guard let path = payload["path"] as? String, let file = files.first(where: { $0.url.path == path }) else { break }
            if action == "revealAttachment" { runtime.context.revealInFinder([file.url]) }
            else if let webView, let event = mouseEvent, abs(event.timestamp - ProcessInfo.processInfo.systemUptime) < 2 { runtime.context.beginDragging(urls: [file.url], from: webView, event: event) }
        case "configureModel": model.configureModel()
        case "openSession": model.openSession()
        case "retry": model.retry()
        case "allowProjectEdits":
            if model.config.adapterType == .codex, let value = payload["value"] as? Bool { model.configure { $0.allowProjectEdits = value } }
        case "quit": NSApp.terminate(nil)
        default: break
        }
        pushState()
    }
    private func historyResponse(_ result: [String: Any]) {
        webView?.callAsyncJavaScript("window.homies?.history(result)", arguments: ["result": result], in: nil, in: .page) { _ in }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "homies" ? .allow : .cancel)
    }
}

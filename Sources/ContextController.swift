import AppKit
import ApplicationServices
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CaptureTarget {
    let id: String
    let label: String
    let kind: String
}

@MainActor
final class ContextController: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    private let maximumAttachmentSize = 25 * 1024 * 1024
    private let root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AgentDrop", isDirectory: true)) {
        self.root = root
        super.init()
    }

    enum ContextError: LocalizedError {
        case invalidAgent, invalidFile, tooLarge, noCaptureTarget, screenPermission, imageEncoding
        var errorDescription: String? {
            switch self {
            case .invalidAgent: return "Invalid agent identifier."
            case .invalidFile: return "The attachment must be a regular file."
            case .tooLarge: return "Attachments must be 25 MB or smaller."
            case .noCaptureTarget: return "The selected screen or window is no longer available."
            case .screenPermission: return "Allow AgentDrop in System Settings > Privacy & Security > Screen & System Audio Recording, then try again. You may need to restart AgentDrop."
            case .imageEncoding: return "Could not encode the image as PNG."
            }
        }
    }

    func chooseFiles(agentID: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        return panel.runModal() == .OK ? panel.urls : []
    }

    private func directory(agentID: String) throws -> URL {
        guard !agentID.isEmpty, agentID != ".", agentID != "..", !agentID.contains("/"), !agentID.contains("\0") else { throw ContextError.invalidAgent }
        let folder = root.appendingPathComponent(agentID, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard folder.resolvingSymlinksInPath().deletingLastPathComponent() == root.resolvingSymlinksInPath() else { throw ContextError.invalidAgent }
        return folder
    }

    func importData(_ data: Data, filename: String, agentID: String) throws -> URL {
        guard data.count <= maximumAttachmentSize else { throw ContextError.tooLarge }
        let folder = try directory(agentID: agentID)
        let rawName = (filename as NSString).lastPathComponent
        let name = rawName.isEmpty || rawName == "." || rawName == ".." ? "attachment" : rawName.replacingOccurrences(of: "\0", with: "")
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        for index in 0..<10_000 {
            let suffix = index == 0 ? "" : "-\(index)"
            let destination = folder.appendingPathComponent(stem + suffix + (ext.isEmpty ? "" : "." + ext))
            do {
                try data.write(to: destination, options: .withoutOverwriting)
                return destination
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    func importFiles(_ urls: [URL], agentID: String) throws -> [URL] {
        try urls.map { url in
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard url.isFileURL, values.isRegularFile == true else { throw ContextError.invalidFile }
            guard let size = values.fileSize, size <= maximumAttachmentSize else { throw ContextError.tooLarge }
            return try importData(Data(contentsOf: url), filename: url.lastPathComponent, agentID: agentID)
        }
    }

    func clipboardAttachments(agentID: String) throws -> [URL] {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return try importFiles(urls, agentID: agentID)
        }
        if let data = pasteboard.data(forType: .png) {
            return [try importData(data, filename: "Clipboard.png", agentID: agentID)]
        }
        if let data = pasteboard.data(forType: .tiff), let image = NSBitmapImageRep(data: data), let png = image.representation(using: .png, properties: [:]) {
            return [try importData(png, filename: "Clipboard.png", agentID: agentID)]
        }
        return []
    }

    func revealInFinder(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }

    func currentSelection() -> String? {
        if AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                var selected: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selected) == .success,
                   let text = selected as? String, !text.isEmpty { return text }
            }
        }
        return NSPasteboard.general.string(forType: .string)
    }

    private func shareableContent() async throws -> SCShareableContent {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw ContextError.screenPermission }
        do { return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch {
            if !CGPreflightScreenCaptureAccess() { throw ContextError.screenPermission }
            throw error
        }
    }

    func listCaptureTargets() async throws -> [CaptureTarget] {
        let content = try await shareableContent()
        let displays = content.displays.map { CaptureTarget(id: "display:\($0.displayID)", label: $0.displayID == CGMainDisplayID() ? "Entire Screen" : "Screen \($0.displayID)", kind: "display") }
            .sorted { ($0.label == "Entire Screen" ? "" : $0.label) < ($1.label == "Entire Screen" ? "" : $1.label) }
        let windows = content.windows.compactMap { window -> CaptureTarget? in
            guard window.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier,
                  let title = window.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, window.frame.width > 0, window.frame.height > 0 else { return nil }
            let app = window.owningApplication?.applicationName ?? "Window"
            return CaptureTarget(id: "window:\(window.windowID)", label: "\(app) — \(title)", kind: "window")
        }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return displays + windows
    }

    func capture(targetID: String, agentID: String) async throws -> URL {
        let content = try await shareableContent()
        let filter: SCContentFilter
        let width: Int
        let height: Int
        if let display = content.displays.first(where: { "display:\($0.displayID)" == targetID }) {
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            width = display.width
            height = display.height
        } else if let window = content.windows.first(where: { "window:\($0.windowID)" == targetID }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
            let scale = NSScreen.screens.first?.backingScaleFactor ?? 1
            width = max(1, Int(window.frame.width * scale))
            height = max(1, Int(window.frame.height * scale))
        } else { throw ContextError.noCaptureTarget }
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw ContextError.imageEncoding }
        return try importData(png, filename: "Screenshot.png", agentID: agentID)
    }

    private nonisolated func isOwnedAttachment(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let file = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard file.hasPrefix(base + "/") else { return false }
        let relative = String(file.dropFirst(base.count + 1))
        guard relative.split(separator: "/").count >= 2 else { return false }
        return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    func beginDragging(urls: [URL], from view: NSView, event: NSEvent) {
        let point = view.convert(event.locationInWindow, from: nil)
        let items = urls.filter { isOwnedAttachment($0) }.map { url in
            let type = UTType(filenameExtension: url.pathExtension) ?? .data
            let provider = NSFilePromiseProvider(fileType: type.conforms(to: .data) ? type.identifier : UTType.data.identifier, delegate: self)
            provider.userInfo = url
            let item = NSDraggingItem(pasteboardWriter: provider)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            item.setDraggingFrame(NSRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48), contents: icon)
            return item
        }
        guard !items.isEmpty else { return }
        view.beginDraggingSession(with: items, event: event, source: self)
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? URL)?.lastPathComponent ?? "attachment"
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let source = filePromiseProvider.userInfo as? URL, isOwnedAttachment(source) else {
            completionHandler(ContextError.invalidFile)
            return
        }
        do {
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

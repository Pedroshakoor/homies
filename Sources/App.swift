import AppKit
import SwiftUI
import QuartzCore
import Combine

final class ConversationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

@MainActor final class AgentSelection: ObservableObject {
    let models: [AgentModel]
    @Published var selectedID: String { didSet { UserDefaults.standard.set(selectedID, forKey: "selectedAgent") } }
    var selected: AgentModel { models.first { $0.id == selectedID } ?? models[0] }
    init(models: [AgentModel]) { self.models = models; self.selectedID = models.first(where: { $0.id == UserDefaults.standard.string(forKey: "selectedAgent") })?.id ?? models.first(where: { $0.config.adapterType == .codex })?.id ?? models[0].id }
}

struct AgentPanelView: View {
    @ObservedObject var selection: AgentSelection
    var expanded = false
    var expand: () -> Void
    var body: some View {
        WebConversationView(selection: selection, expanded: expanded, expand: expand)

    }
}

@MainActor final class StatusController: NSObject {
    let selection: AgentSelection
    var model: AgentModel { selection.selected }
    let item: NSStatusItem
    private let panel: ConversationPanel
    private var window: NSWindow?
    private var outsideMonitor: Any?
    private var localMonitor: Any?
    private var tracking: NSTrackingArea?
    private var labelPanel: NSPanel?
    private var hover = false
    private var statusDot: NSView?
    private var selectionObserver: AnyCancellable?

    init(models: [AgentModel]) {
        self.selection = AgentSelection(models: models)
        item = NSStatusBar.system.statusItem(withLength: 52)
        panel = ConversationPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 520),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = glassContent(AgentPanelView(selection: selection) { [weak self] in self?.expand() })
        if let button = item.button {
            button.imageScaling = .scaleProportionallyDown
            let dot = NSView()
            dot.wantsLayer = true; dot.layer?.cornerRadius = 2
            dot.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 4), dot.heightAnchor.constraint(equalToConstant: 4),
                dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -1),
                dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3)
            ])
            statusDot = dot
            button.target = self; button.action = #selector(toggle)
            button.setAccessibilityLabel("Homies · \(model.config.displayName), \(model.status.label)")
            let area = NSTrackingArea(rect: button.bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            button.addTrackingArea(area); tracking = area
        }
        for model in models { model.onStatusChanged = { [weak self] in self?.redraw() } }
        selectionObserver = selection.$selectedID.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window?.title = self.model.config.displayName + " · Homies"
                self.redraw()
            }
        }
        redraw()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.panel.isVisible, !self.panel.frame.contains(NSEvent.mouseLocation),
                      self.anchorRect()?.contains(NSEvent.mouseLocation) != true else { return }
                self.close()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .keyDown, panel.isVisible, NSApp.modalWindow == nil {
                let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
                if !panel.frame.contains(point), anchorRect()?.contains(point) != true { close() }
            }
            return event
        }
    }
    func redraw() {
        item.button?.image = AppIcon.shared.image
        item.button?.toolTip = "Homies · \(model.config.displayName) · \(model.status.label)"
        statusDot?.layer?.backgroundColor = NSColor(model.status.color).cgColor
        item.button?.setAccessibilityLabel("Homies · \(model.config.displayName), \(model.status.label)")
    }
    @objc func mouseEntered(with event: NSEvent) {
        hover = true; redraw()
        guard !panel.isVisible, let anchor = anchorRect() else { return }
        let label = NSPanel(contentRect: NSRect(x: anchor.midX - 58, y: anchor.minY - 34, width: 116, height: 26), styleMask: .borderless, backing: .buffered, defer: false)
        label.isOpaque = false; label.backgroundColor = .clear; label.level = .popUpMenu; label.hasShadow = true
        label.ignoresMouseEvents = true
        label.contentView = NSHostingView(rootView: Text(model.config.displayName).font(.system(size: 11, weight: .medium)).frame(width: 116, height: 26).background(.regularMaterial, in: Capsule()))
        label.orderFrontRegardless(); labelPanel = label
    }
    @objc func mouseExited(with event: NSEvent) { hover = false; redraw(); labelPanel?.orderOut(nil); labelPanel = nil }
    private func anchorRect() -> NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }
    @objc func toggle() { panel.isVisible ? close() : show() }
    func show() {
        NotificationCenter.default.post(name: .init("HomiesClosePanels"), object: self)
        labelPanel?.orderOut(nil)
        let fallback = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchor = anchorRect() ?? NSRect(x: fallback.maxX - 180, y: fallback.maxY, width: 24, height: 24)
        let screen = item.button?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 340, height = min(CGFloat(520), visible.height - 16)
        let x = min(max(anchor.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        let target = NSRect(x: x, y: max(visible.minY + 8, anchor.minY - height - 8), width: width, height: height)
        panel.setFrame(target, display: true)
        NSApp.activate(ignoringOtherApps: true)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduce ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        if !reduce {
            panel.setFrameOrigin(NSPoint(x: target.minX, y: target.minY + 5))
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
    }
    func close() { panel.orderOut(nil); labelPanel?.orderOut(nil) }
    func expand() {
        close()
        if window == nil {
            let result = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            result.title = model.config.displayName + " · Homies"
            result.titlebarAppearsTransparent = true; result.titleVisibility = .hidden
            result.isOpaque = false; result.backgroundColor = .clear; result.isReleasedWhenClosed = false
            result.minSize = NSSize(width: 340, height: 460)
            result.contentView = glassContent(AgentPanelView(selection: selection, expanded: true, expand: { [weak self] in
                self?.window?.orderOut(nil); self?.show()
            }).padding(.top, 24))
            result.center(); window = result
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [StatusController] = []
    private var timer: Timer?
    private var closeObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--preview-light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--preview-dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        createMenus()
        do {
            let store = try LocalStore()
            let models = try store.configurations().map { try AgentModel(config: $0, store: store) }
            try store.save(models.map(\.config), name: "agents.json")
            for model in models {
                model.onConfigurationChanged = { try store.save(models.map(\.config), name: "agents.json") }
            }
            controllers = [StatusController(models: models)]
            AppRuntime.shared.selectedAgent = { [weak self] in self?.controllers.first?.model }
            AppRuntime.shared.showPanel = { [weak self] in self?.controllers.first?.show() }
            AppRuntime.shared.configure()
            closeObserver = NotificationCenter.default.addObserver(forName: .init("HomiesClosePanels"), object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    for controller in self?.controllers ?? [] where controller !== notification.object as? StatusController { controller.close() }
                }
            }
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                Task { @MainActor in models.forEach { $0.prune() } }
            }
            Task {
                let environment = await CLIEnvironment.discover()
                for model in models {
                    model.environment = environment
                    if model.config.binaryPath.isEmpty {
                        let name: String
                        switch model.config.adapterType { case .codex: name = "codex"; case .claudeCode: name = "claude"; case .hermes: name = "hermes" }
                        let bundled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?
                            .appendingPathComponent("Contents/Resources/codex-cli/bin/codex").path
                        let localHermes = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".runtime/hermes").path
                        let path = name == "codex" ? bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? environment.resolve(name)
                            : name == "hermes" && FileManager.default.isExecutableFile(atPath: localHermes) ? localHermes : environment.resolve(name)
                        if let path { model.configure { $0.binaryPath = path } }
                    }
                    Task { await model.refreshLogin() }
                }
                if CommandLine.arguments.contains("--show") { controllers.last?.show() }
                if CommandLine.arguments.contains("--show-window") { controllers.last?.expand() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Homies could not load its local data"
            alert.informativeText = "\(error.localizedDescription)\nExisting files have not been replaced. Check ~/Library/Application Support/Homies/."
            alert.runModal(); NSApp.terminate(nil)
        }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        for model in controllers.flatMap({ $0.selection.models }) {
            Task { await model.refreshLogin(); await model.refreshModels() }
        }
    }
    func applicationWillTerminate(_ notification: Notification) { controllers.flatMap { $0.selection.models }.forEach { $0.stop(); $0.persist() } }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { controllers.first?.show() }
        return true
    }
    private func createMenus() {
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Homies", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); editItem.title = "Edit"; let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
    }
}

@main struct Homies {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

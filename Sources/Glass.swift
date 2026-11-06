import AppKit
import SwiftUI

extension AgentStatus {
    var color: Color {
        switch self {
        case .idle: return .green
        case .thinking: return .accentColor
        case .toolCalling: return .purple
        case .needsApproval: return .orange
        case .error: return .red
        }
    }
}
@MainActor private final class ClearHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

@MainActor func glassContent<Content: View>(_ content: Content) -> NSView {
    // Keep the desktop-sampling view in the AppKit hierarchy, outside SwiftUI's
    // offscreen clipping/compositing of the WebKit surface.
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor.clear.cgColor
    container.layer?.cornerRadius = 28
    container.layer?.masksToBounds = true
    let material = NSVisualEffectView()
    material.material = .hudWindow
    material.blendingMode = .behindWindow
    material.state = .active
    material.appearance = NSAppearance(named: .vibrantDark)
    material.alphaValue = 0.60
    let hosting = ClearHostingView(rootView: content)
    hosting.sizingOptions = []
    for view in [material, hosting] as [NSView] {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
    return container
}

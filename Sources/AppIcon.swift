import AppKit

@MainActor final class AppIcon {
    static let shared = AppIcon()
    let image: NSImage?
    private init() {
        image = Bundle.main.url(forResource: "AppAvatar", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        image?.size = NSSize(width: 22, height: 22)
    }
}

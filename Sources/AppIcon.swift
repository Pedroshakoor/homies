import AppKit

@MainActor final class AppIcon {
    static let shared = AppIcon()
    let image: NSImage?
    private init() {
        image = Bundle.main.url(forResource: "HomiesMenu", withExtension: "png").flatMap(NSImage.init(contentsOf:))
        if let image {
            image.size = NSSize(width: 40, height: 40 * image.size.height / image.size.width)
            image.isTemplate = true
        }
    }
}

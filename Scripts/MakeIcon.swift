import AppKit
import ImageIO
import UniformTypeIdentifiers

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let avatarURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("App artwork could not be decoded") }
// Crop the supplied Piko mascot tightly enough to read at menu-bar sizes.
// Keep the yellow field and original artwork; only the empty outer canvas is trimmed.
let side = Int(Double(original.height) * 0.40)
let centerX = Int(Double(original.width) * 0.517)
let centerY = Int(Double(original.height) * 0.49)
let image = original.cropping(to: CGRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side))!
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
func render(pixels: Int, circle: Bool) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let canvas = CGRect(x: 0, y: 0, width: pixels, height: pixels)
    context.clear(canvas)
    context.interpolationQuality = .high
    let rect = circle ? canvas.insetBy(dx: 1, dy: 1) : canvas.insetBy(dx: Double(pixels) * 0.055, dy: Double(pixels) * 0.055)
    if circle { context.addEllipse(in: rect) }
    else { context.addPath(CGPath(roundedRect: rect, cornerWidth: Double(pixels) * 0.19, cornerHeight: Double(pixels) * 0.19, transform: nil)) }
    context.clip(); context.draw(image, in: rect)
    return context.makeImage()!
}
func write(_ image: CGImage, to url: URL) {
    let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Could not write app icon") }
}
write(render(pixels: 128, circle: true), to: avatarURL)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        write(render(pixels: size * scale, circle: false), to: destination.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
    }
}
print("Prepared static app icon and menu avatar from the supplied artwork")

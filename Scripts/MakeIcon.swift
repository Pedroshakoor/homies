import AppKit
import ImageIO
import UniformTypeIdentifiers

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let avatarURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("App artwork could not be decoded") }
// Preserve the full supplied wordmark and trim its empty outer canvas.
let side = Int(Double(min(original.width, original.height)) * 0.90)
let centerX = Int(Double(original.width) * 0.495)
let centerY = Int(Double(original.height) * 0.52)
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

// A luminance mask preserves the supplied lettering as a native menu-bar template.
let width = original.width, height = original.height
let maskContext = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
maskContext.draw(original, in: CGRect(x: 0, y: 0, width: width, height: height))
let bytes = maskContext.data!.assumingMemoryBound(to: UInt8.self)
var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 4
        let luminance = UInt8((Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])) / 3)
        let alpha: UInt8 = luminance > 12 ? luminance : 0
        bytes[offset] = alpha; bytes[offset + 1] = alpha; bytes[offset + 2] = alpha; bytes[offset + 3] = alpha
        if alpha > 150 { minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y) }
    }
}
precondition(minX < maxX && minY < maxY, "Wordmark has no visible lettering")
let bounds = CGRect(x: max(0, minX - 6), y: max(0, minY - 6), width: min(width - minX + 6, maxX - minX + 13), height: min(height - minY + 6, maxY - minY + 13))
write(maskContext.makeImage()!.cropping(to: bounds)!, to: avatarURL.deletingLastPathComponent().appendingPathComponent("HomiesMenu.png"))

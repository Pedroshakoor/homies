import Foundation
import ImageIO
import CoreGraphics

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Missing menu avatar") }
precondition(image.width == 128 && image.height == 128)
let info = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info)!
context.clear(CGRect(x: 0, y: 0, width: 128, height: 128)); context.setBlendMode(.copy)
context.draw(image, in: CGRect(x: 0, y: 0, width: 128, height: 128))
let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
for (x, y) in [(0, 0), (127, 0), (0, 127), (127, 127)] { precondition(pixels[(y * 128 + x) * 4 + 3] == 0) }
precondition(pixels[(64 * 128 + 64) * 4 + 3] == 255)
print("PASS: app avatar is square, has transparent corners, and retains opaque artwork")

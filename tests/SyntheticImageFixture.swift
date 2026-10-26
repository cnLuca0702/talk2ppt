import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A small, synthetic raster for offline tests. No user images or AI calls are used.
enum SyntheticImageFixture {
    static func write(to url: URL) throws -> URL {
        guard let context = CGContext(data: nil, width: 160, height: 90, bitsPerComponent: 8,
                                      bytesPerRow: 160 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw FixtureError.cannotCreate
        }
        context.setFillColor(CGColor(red: 0.15, green: 0.45, blue: 0.85, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 160, height: 90))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 16, y: 25, width: 128, height: 40))
        guard let image = context.makeImage() else { throw FixtureError.cannotCreate }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw FixtureError.cannotCreate }
        return url
    }

    private enum FixtureError: Error { case cannotCreate }
}

//
//  SpriteRecolor.swift — applies a CatPalette to a decoded sheet.
//
//  The colour table and the pixel loop live in DockPetCore.CatPalette, which is pure and
//  unit-tested. This file is only the CGImage bridge around them: decode to bytes, hand
//  them to the palette, encode back.
//
//  Everything here degrades to "not recoloured" rather than to an error. A cat in the
//  wrong colour is a cosmetic disappointment; a cat that fails to load is an invisible app.
//

import CoreGraphics
import Foundation
import DockPetCore

enum SpriteRecolor {

    /// Decode a sheet into 8-bit RGBA, preserving the art's exact colour values.
    ///
    /// Device RGB on both sides on purpose: the sheet is written by an `NSBitmapImageRep`
    /// in device RGB, so drawing it into a device RGB context is a straight copy. Going
    /// through sRGB instead would convert the values — 0xE8954A arrives as 0xE0823A — and
    /// the exact-match swap would then match nothing at all.
    ///
    /// Premultiplied alpha costs nothing here: every pixel in the art is either fully
    /// opaque or fully transparent, and only the opaque ones are ever recoloured.
    static func rgbaBytes(of image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.setShouldAntialias(false)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// The sheet in a different coat. Returns the original image untouched when the coat is
    /// the one the art is already drawn in, or when the sheet cannot be decoded.
    static func apply(_ palette: CatPalette, to image: CGImage) -> CGImage {
        guard !palette.isIdentity, var bytes = rgbaBytes(of: image) else { return image }

        palette.recolor(rgba: &bytes)

        let width = image.width, height = image.height
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let recoloured = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return image }

        return recoloured
    }
}

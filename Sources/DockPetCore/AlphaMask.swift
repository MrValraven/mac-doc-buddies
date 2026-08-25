//
//  AlphaMask.swift — which pixels of a sprite frame are solid enough to click. Pure.
//
//  The pet's window floats over the Dock (SPEC §3). Once it stops ignoring mouse events
//  so the cat can be clicked, its rectangle would swallow every click that lands inside
//  it — including the ones meant for the Dock icon the cat happens to be standing on. A
//  32x32 sprite is mostly empty space, so that is most of the rectangle.
//
//  This is the fix: the view hit-tests against the sprite's own opacity and lets clicks
//  through everywhere the art is transparent. The mapping from a view point back to an
//  art pixel has to agree with how PetView draws — including the horizontal flip — which
//  is why it lives here where it can be checked rather than inline in the view.
//
//  SPEC §8 trap 4: `Px` means art pixels throughout. View points are `pt`.
//

import CoreGraphics
import Foundation

public struct AlphaMask {

    public let widthPx: Int
    public let heightPx: Int

    /// Row-major, first row is the TOP row — the order a CGImage stores its rows.
    private let opaque: [Bool]

    /// Cached rather than recomputed: `isEmpty` is checked once per frame change, and a
    /// linear scan of the sprite for every check would be waste.
    private let hasAnyOpaquePixel: Bool

    public init(widthPx: Int, heightPx: Int, opaque: [Bool]) {
        self.widthPx = max(0, widthPx)
        self.heightPx = max(0, heightPx)
        self.opaque = opaque
        self.hasAnyOpaquePixel = opaque.contains(true)
    }

    /// Read the alpha channel of a decoded frame.
    ///
    /// `threshold` exists because an antialiased or near-transparent edge pixel is not
    /// something anyone can aim at; treating it as a click target would hand the pet
    /// clicks the user meant for the Dock.
    public init?(image: CGImage, threshold: UInt8 = 8) {
        let widthPx = image.width
        let heightPx = image.height
        guard widthPx > 0, heightPx > 0 else { return nil }

        // Redrawn into a context of known layout rather than trusting the image's own
        // `dataProvider`: a PNG can arrive in any channel order, bit depth or row padding,
        // and reading those bytes directly would be reading a different image on some
        // machines than on others.
        let bytesPerRow = widthPx * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * heightPx)

        let drew: Bool = bytes.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: widthPx, height: heightPx,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // SPEC §5: no resampling. Same size in, same size out, nearest neighbour.
            ctx.interpolationQuality = .none
            ctx.setShouldAntialias(false)
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: widthPx, height: heightPx))
            return true
        }
        guard drew else { return nil }

        var flags = [Bool](repeating: false, count: widthPx * heightPx)
        for index in 0..<flags.count {
            flags[index] = bytes[index * 4 + 3] > threshold
        }

        self.init(widthPx: widthPx, heightPx: heightPx, opaque: flags)
    }

    /// True when nothing in this frame can be clicked.
    public var isEmpty: Bool { widthPx <= 0 || heightPx <= 0 || !hasAnyOpaquePixel }

    /// `yPx` counts down from the TOP row, matching how the art is stored.
    ///
    /// Out-of-range coordinates read as transparent rather than trapping: the tolerance
    /// search below walks off the edge of the sprite by design.
    public func isOpaque(xPx: Int, yPx: Int) -> Bool {
        guard xPx >= 0, xPx < widthPx, yPx >= 0, yPx < heightPx else { return false }
        let index = yPx * widthPx + xPx
        guard index < opaque.count else { return false }   // a malformed, short mask
        return opaque[index]
    }

    /// Is the art solid under this point of the view?
    ///
    /// `point` is in AppKit view coordinates: origin bottom-left, y increasing upwards.
    /// The art's rows run the other way, which is the flip in the middle of this method.
    ///
    /// `mirrored` must match what PetView actually drew — it flips the walk sheet when the
    /// pet faces left and leaves the front-on sheets alone (PetView.mirrorsWhenFacingLeft).
    ///
    /// `tolerancePx` widens the hit by that many art pixels in every direction. A 32 px cat
    /// drawn at 2x has a tail two points wide; demanding a pixel-exact click on it would
    /// be unusable.
    public func isOpaque(atViewPoint point: CGPoint, viewSize: CGSize,
                         mirrored: Bool, tolerancePx: Int) -> Bool {
        guard widthPx > 0, heightPx > 0, viewSize.width > 0, viewSize.height > 0 else {
            return false
        }
        guard point.x >= 0, point.x < viewSize.width,
              point.y >= 0, point.y < viewSize.height else { return false }

        var column = Int((point.x / viewSize.width) * CGFloat(widthPx))
        // y is measured up from the bottom of the view; row 0 is the top of the art.
        var row = Int(((viewSize.height - point.y) / viewSize.height) * CGFloat(heightPx))

        // Rounding at the very edge can land one past the last index.
        column = min(max(0, column), widthPx - 1)
        row = min(max(0, row), heightPx - 1)

        // The view column shows a mirrored art column when the sheet was drawn flipped.
        if mirrored { column = widthPx - 1 - column }

        let reach = max(0, tolerancePx)
        guard reach > 0 else { return isOpaque(xPx: column, yPx: row) }

        for dy in -reach...reach {
            for dx in -reach...reach where isOpaque(xPx: column + dx, yPx: row + dy) {
                return true
            }
        }
        return false
    }
}

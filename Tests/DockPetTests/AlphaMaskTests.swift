//
//  AlphaMaskTests.swift — assertions for DockPetCore.AlphaMask (M10, click-to-interact)
//
//  The pet's window sits on top of the Dock. If it swallowed every click inside its
//  rectangle, the Dock icons underneath would stop working wherever the cat happened to
//  be standing. The mask is what stops that, so the arithmetic below is the difference
//  between a clickable pet and a broken Dock.
//

import Foundation
import CoreGraphics
import DockPetCore

enum AlphaMaskTests {

    /// A 4x2 mask, written the way the art is stored: first row is the TOP row.
    ///
    ///   row 0 (top)    . X . .
    ///   row 1 (bottom) . . . X
    private static let sample = AlphaMask(widthPx: 4, heightPx: 2, opaque: [
        false, true,  false, false,
        false, false, false, true,
    ])

    static func run() {

        section("alpha mask: pixel lookup")

        check(sample.isOpaque(xPx: 1, yPx: 0), "the marked pixel on the top row is opaque")
        check(sample.isOpaque(xPx: 3, yPx: 1), "the marked pixel on the bottom row is opaque")
        check(!sample.isOpaque(xPx: 0, yPx: 0), "an unmarked pixel is not")

        check(!sample.isOpaque(xPx: -1, yPx: 0), "a negative column is not opaque, not a crash")
        check(!sample.isOpaque(xPx: 4, yPx: 0), "a column past the edge is not opaque")
        check(!sample.isOpaque(xPx: 0, yPx: 2), "a row past the edge is not opaque")

        check(AlphaMask(widthPx: 0, heightPx: 0, opaque: []).isEmpty,
              "a mask with no pixels knows it is empty")
        check(!sample.isEmpty, "a mask with pixels does not")

        // A short `opaque` array is a malformed mask; it must read as transparent rather
        // than index out of bounds.
        let short = AlphaMask(widthPx: 4, heightPx: 2, opaque: [true])
        check(short.isOpaque(xPx: 0, yPx: 0) && !short.isOpaque(xPx: 3, yPx: 1),
              "a mask given too few pixels treats the missing ones as transparent")

        section("alpha mask: view point mapping")

        // The view is 40x20 pt for a 4x2 art grid: 10 pt per art pixel. AppKit points have
        // their origin at the BOTTOM left, so art row 0 is at the TOP of the view.
        let size = CGSize(width: 40, height: 20)

        check(sample.isOpaque(atViewPoint: CGPoint(x: 15, y: 15), viewSize: size,
                              mirrored: false, tolerancePx: 0),
              "a point over the top-row pixel hits — art row 0 is the top of the view")

        check(!sample.isOpaque(atViewPoint: CGPoint(x: 15, y: 5), viewSize: size,
                               mirrored: false, tolerancePx: 0),
              "the same column low down misses — the y axis is not upside down")

        check(sample.isOpaque(atViewPoint: CGPoint(x: 35, y: 5), viewSize: size,
                              mirrored: false, tolerancePx: 0),
              "a point over the bottom-row pixel hits")

        check(!sample.isOpaque(atViewPoint: CGPoint(x: -1, y: 10), viewSize: size,
                               mirrored: false, tolerancePx: 0),
              "a point outside the view misses")
        check(!sample.isOpaque(atViewPoint: CGPoint(x: 40, y: 10), viewSize: size,
                               mirrored: false, tolerancePx: 0),
              "a point on the far edge misses rather than wrapping to column 0")

        check(!sample.isOpaque(atViewPoint: CGPoint(x: 15, y: 15), viewSize: .zero,
                               mirrored: false, tolerancePx: 0),
              "a zero-sized view misses instead of dividing by zero")

        section("alpha mask: the horizontal flip")

        // Facing left mirrors the drawing (PetView), so the hit test has to mirror too.
        // Art column 1 is drawn at column 2 when mirrored: 4 - 1 - 1 = 2.
        check(sample.isOpaque(atViewPoint: CGPoint(x: 25, y: 15), viewSize: size,
                              mirrored: true, tolerancePx: 0),
              "the top-row pixel moves to the mirrored column when the pet faces left")
        check(!sample.isOpaque(atViewPoint: CGPoint(x: 15, y: 15), viewSize: size,
                               mirrored: true, tolerancePx: 0),
              "and is no longer where it was")

        section("alpha mask: click tolerance")

        // A 32 px cat drawn at 2x has a tail a couple of points wide. Demanding a pixel-
        // exact click on it would be unusable, so a hit spreads by a pixel or two of art.
        check(!sample.isOpaque(atViewPoint: CGPoint(x: 5, y: 15), viewSize: size,
                               mirrored: false, tolerancePx: 0),
              "the pixel next door misses with no tolerance")
        check(sample.isOpaque(atViewPoint: CGPoint(x: 5, y: 15), viewSize: size,
                              mirrored: false, tolerancePx: 1),
              "and hits with one pixel of tolerance")
        check(sample.isOpaque(atViewPoint: CGPoint(x: 5, y: 5), viewSize: size,
                              mirrored: false, tolerancePx: 1),
              "tolerance reaches diagonally too")
        check(!AlphaMask(widthPx: 4, heightPx: 2, opaque: Array(repeating: false, count: 8))
                .isOpaque(atViewPoint: CGPoint(x: 5, y: 5), viewSize: size,
                          mirrored: false, tolerancePx: 4),
              "tolerance over a fully transparent mask still misses")

        section("alpha mask: reading a real image")

        // Opaque along the TOP row only. Deliberately asymmetric top-to-bottom: a
        // reader that walked the rows the wrong way up would pass a symmetric fixture
        // and then hit-test the cat upside down.
        let widthPx = 4, heightPx = 2
        var rgba = [UInt8](repeating: 0, count: widthPx * heightPx * 4)
        for col in 0..<2 {
            let i = col * 4
            rgba[i] = 255; rgba[i + 1] = 128; rgba[i + 2] = 0; rgba[i + 3] = 255
        }

        if let image = makeImage(rgba: rgba, widthPx: widthPx, heightPx: heightPx),
           let mask = AlphaMask(image: image) {
            eq(mask.widthPx, widthPx, "the mask takes its width from the image")
            eq(mask.heightPx, heightPx, "and its height")
            check(mask.isOpaque(xPx: 0, yPx: 0) && mask.isOpaque(xPx: 1, yPx: 0),
                  "opaque pixels on the top row read as opaque")
            check(!mask.isOpaque(xPx: 2, yPx: 0),
                  "transparent pixels on the same row read as transparent")
            check(!mask.isOpaque(xPx: 0, yPx: 1) && !mask.isOpaque(xPx: 1, yPx: 1),
                  "the empty bottom row stays empty — the rows are not read upside down")
        } else {
            check(false, "a mask can be built from a CGImage")
        }

        // A nearly-invisible pixel is not something anyone can aim at, so it is not a
        // click target either.
        var faint = [UInt8](repeating: 0, count: widthPx * heightPx * 4)
        for i in stride(from: 0, to: faint.count, by: 4) { faint[i + 3] = 3 }
        if let image = makeImage(rgba: faint, widthPx: widthPx, heightPx: heightPx),
           let mask = AlphaMask(image: image) {
            check(!mask.isOpaque(xPx: 0, yPx: 0),
                  "an all-but-transparent pixel is not a click target")
        } else {
            check(false, "a faint mask can be built from a CGImage")
        }
    }

    private static func makeImage(rgba: [UInt8], widthPx: Int, heightPx: Int) -> CGImage? {
        var bytes = rgba
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let ctx = CGContext(data: raw.baseAddress,
                                      width: widthPx, height: heightPx,
                                      bitsPerComponent: 8, bytesPerRow: widthPx * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
    }
}

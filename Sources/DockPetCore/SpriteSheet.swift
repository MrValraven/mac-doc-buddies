//
//  SpriteSheet.swift — sprite sheet metadata and frame timing. Pure.
//
//  SPEC §5: frame geometry is never hardcoded; it comes from the sidecar JSON next to the
//  sheet. This file owns the parsing, the validation, and the arithmetic that turns
//  elapsed time into a frame index and a source rectangle.
//
//  SPEC §8 trap 4: sizes here are labelled `px` (art/device pixels) or `pt` (points).
//  Anything unlabelled is a count, not a length.
//

import CoreGraphics
import Foundation

/// The sidecar file, e.g. {"frameWidth":32,"frameHeight":32,"frameCount":8,"fps":10}
public struct SpriteMetadata: Codable, Equatable {
    public let frameWidth: Int      // px
    public let frameHeight: Int     // px
    public let frameCount: Int
    public let fps: Double

    public init(frameWidth: Int, frameHeight: Int, frameCount: Int, fps: Double) {
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.frameCount = frameCount
        self.fps = fps
    }
}

public enum SpriteSheetError: Error, Equatable, CustomStringConvertible {
    case nonPositive(field: String, value: String)
    case sheetWidthMismatch(expectedPx: Int, actualPx: Int)
    case sheetHeightMismatch(expectedPx: Int, actualPx: Int)

    public var description: String {
        switch self {
        case .nonPositive(let field, let value):
            return "\(field) must be greater than zero (got \(value))"
        case .sheetWidthMismatch(let expected, let actual):
            return "sheet is \(actual) px wide but frameWidth x frameCount is \(expected) px"
        case .sheetHeightMismatch(let expected, let actual):
            return "sheet is \(actual) px tall but frameHeight is \(expected) px"
        }
    }
}

extension SpriteMetadata {

    /// Total width the sheet must have, in pixels.
    public var sheetWidthPx: Int { frameWidth * frameCount }

    /// Check the numbers make sense on their own.
    public func validate() throws {
        if frameWidth <= 0 { throw SpriteSheetError.nonPositive(field: "frameWidth", value: "\(frameWidth)") }
        if frameHeight <= 0 { throw SpriteSheetError.nonPositive(field: "frameHeight", value: "\(frameHeight)") }
        if frameCount <= 0 { throw SpriteSheetError.nonPositive(field: "frameCount", value: "\(frameCount)") }
        if !(fps > 0) { throw SpriteSheetError.nonPositive(field: "fps", value: "\(fps)") }
    }

    /// Check the numbers match the image that was actually loaded.
    ///
    /// A sheet that disagrees with its sidecar would otherwise render as sliced-up
    /// fragments of neighbouring frames, which looks like a drawing bug rather than a
    /// data one.
    public func validate(againstSheetWidthPx widthPx: Int, heightPx: Int) throws {
        try validate()
        if widthPx != sheetWidthPx {
            throw SpriteSheetError.sheetWidthMismatch(expectedPx: sheetWidthPx, actualPx: widthPx)
        }
        if heightPx != frameHeight {
            throw SpriteSheetError.sheetHeightMismatch(expectedPx: frameHeight, actualPx: heightPx)
        }
    }

    /// The rectangle of frame `index` within the sheet, in the sheet's pixel space.
    ///
    /// Frames run left to right (SPEC §5). The index wraps, so a caller cannot walk off
    /// the end of the sheet.
    public func sourceRectPx(frame index: Int) -> CGRect {
        let wrapped = ((index % frameCount) + frameCount) % frameCount
        return CGRect(x: CGFloat(wrapped * frameWidth), y: 0,
                      width: CGFloat(frameWidth), height: CGFloat(frameHeight))
    }

    /// On-screen size in points at an integer scale factor.
    public func pointSize(scale: Int) -> CGSize {
        CGSize(width: CGFloat(frameWidth * scale), height: CGFloat(frameHeight * scale))
    }

    /// How many device pixels each art pixel covers.
    ///
    /// SPEC §5 wants integer scaling only. This is the number that has to come out whole:
    /// a 2x window on a 2x display puts 4 device pixels under every art pixel, which is
    /// crisp; anything fractional shimmers no matter what the magnification filter says.
    public func devicePixelsPerArtPixel(scale: Int, backingScaleFactor: CGFloat) -> CGFloat {
        CGFloat(scale) * backingScaleFactor
    }

    public func isCrisp(scale: Int, backingScaleFactor: CGFloat) -> Bool {
        let ratio = devicePixelsPerArtPixel(scale: scale, backingScaleFactor: backingScaleFactor)
        return scale >= 1 && ratio > 0 && abs(ratio.rounded() - ratio) < 0.0001
    }
}

/// Turns elapsed time into a frame index at the sheet's own frame rate.
///
/// Deliberately separate from the animation timer: the timer runs at the app's rate
/// (12 fps, SPEC §6) while the sheet plays at whatever its sidecar says (10 fps by
/// default). Tying them together would force one to follow the other.
public struct FrameSequencer: Equatable {

    public let frameCount: Int
    public let fps: Double

    /// Time within one full loop of the sheet. Kept wrapped so it cannot grow without
    /// bound over a day of running.
    private var elapsed: TimeInterval = 0

    public init(frameCount: Int, fps: Double) {
        self.frameCount = max(1, frameCount)
        self.fps = fps > 0 ? fps : 1
    }

    public var index: Int {
        let raw = Int(elapsed * fps)
        return ((raw % frameCount) + frameCount) % frameCount
    }

    /// Length of one complete cycle through the sheet, in seconds.
    public var loopDuration: TimeInterval { TimeInterval(frameCount) / fps }

    public mutating func advance(by dt: TimeInterval) {
        guard dt > 0 else { return }
        elapsed = (elapsed + dt).truncatingRemainder(dividingBy: loopDuration)
    }

    /// Restart the cycle — used when the pet stops walking, so it does not resume
    /// mid-stride.
    public mutating func reset() { elapsed = 0 }
}

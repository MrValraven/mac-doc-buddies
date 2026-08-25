//
//  BubbleGeometry.swift — where the speech bubble goes, and how long it stays. Pure.
//
//  [M10] The pet walks the full width of the Dock, so its bubble spends a lot of its life
//  near a screen edge. Everything here is about the cases where the bubble cannot simply
//  be centred over the pet: it gets shoved sideways to stay on screen, and the tail has to
//  keep pointing back at the cat afterwards or the bubble stops looking like it belongs
//  to it.
//
//  SPEC §5 keeps AppKit out of DockPetCore, which is the point — this is the part of the
//  bubble that can be checked without a screen (SPEC §9). The drawing lives in
//  DockPet/BubbleWindow.swift.
//

import CoreGraphics
import Foundation

public enum BubbleGeometry {

    /// How close the bubble may come to the edge of the usable screen.
    public static let screenMargin: CGFloat = 8

    /// How close the tail may come to the corner of the bubble. The tail is drawn as a
    /// wedge with width of its own; letting its centre reach the corner would hang half of
    /// it off the side of the body it is supposed to be growing out of.
    public static let tailInset: CGFloat = 14

    /// Where a bubble of `size` sits above `petFrame`, kept inside `visibleFrame`.
    ///
    /// The app only ever walks the pet along a bottom Dock (`StripPolicy.horizontalOnly`),
    /// so "above" is always the right side to put it on.
    public static func frame(size: CGSize, above petFrame: CGRect,
                             within visibleFrame: CGRect, gap: CGFloat) -> CGRect {
        var x = petFrame.midX - size.width / 2

        // Clamped rather than centred-and-hoped: a pet at either end of the Dock would
        // otherwise take half the bubble off the side of the screen with it.
        let minX = visibleFrame.minX + screenMargin
        let maxX = visibleFrame.maxX - screenMargin - size.width
        if maxX >= minX {
            x = min(max(minX, x), maxX)
        } else {
            // Wider than the screen: there is no position that satisfies both margins, so
            // show the start of the line rather than centring it and losing both ends.
            x = visibleFrame.minX
        }

        var y = petFrame.maxY + gap
        let topLimit = visibleFrame.maxY - size.height
        if y > topLimit { y = max(visibleFrame.minY, topLimit) }

        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Where the tail meets the bottom of the bubble, in the bubble's own coordinates.
    ///
    /// Follows the pet rather than the bubble, so a bubble that was shoved sideways to stay
    /// on screen still points back at the cat. Kept inside the body's corners, and inside
    /// a degenerate bubble narrower than two insets, where the only sane answer is the
    /// middle.
    public static func tailCenterX(in bubbleFrame: CGRect, pointingAt petFrame: CGRect) -> CGFloat {
        let wanted = petFrame.midX - bubbleFrame.minX
        let low = tailInset
        let high = bubbleFrame.width - tailInset
        guard high > low else { return bubbleFrame.width / 2 }
        return min(max(low, wanted), high)
    }

    /// Seconds to leave the bubble up for.
    ///
    /// A fixed timeout is wrong at both ends: it either blinks a long line away before it
    /// can be read, or leaves "Hi!" sitting there. Scaled by length, with a floor so a
    /// short line is still readable and a ceiling so a long one does not camp on the
    /// screen. Roughly 200 words per minute plus a beat to notice it appeared.
    public static func readingTime(for text: String) -> TimeInterval {
        let perCharacter = 0.045
        let base = 1.6
        return min(12, max(1.6, base + Double(text.count) * perCharacter))
    }
}

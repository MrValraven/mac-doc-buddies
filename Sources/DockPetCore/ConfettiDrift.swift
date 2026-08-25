//
//  ConfettiDrift.swift: [M13] the confetti that falls over the pair on the birthday.
//
//  `HeartDrift`'s sibling, and deliberately shaped like it. It is a pure function of a 0…1
//  progress and the lengths it is scaled by, so the one part of a two-second shower that
//  can be wrong in a way nobody would ever notice (a piece that never fades, twenty-four
//  pieces falling as one rigid block, a rectangle that never turns and so reads as a bar
//  chart tipping over) is checkable without a screen, per SPEC §9. The view that draws it
//  owns no geometry and no clock of its own; it asks this.
//
//  The one important difference from the hearts: hearts rise, confetti falls. The
//  arithmetic below is written with y upward like everything else in this package, so a
//  falling piece is one whose offset goes from positive to negative.
//
//  Randomness is seeded rather than system, for the same reason `BehaviorMachine`'s is: a
//  burst that is different every run cannot be reproduced from a description, and "it
//  looked festive" is not a check. One seed is one burst, forever.
//

import CoreGraphics
import Foundation

/// Where every piece of confetti is, how solid, which way round and what colour, at a
/// moment in one burst.
public enum ConfettiDrift {

    /// How long a burst lasts, start to settled.
    ///
    /// Longer than the hearts' 1.5 s because the pieces have much further to travel. The
    /// hearts drift about one cat-height; the confetti falls past the whole pair and out
    /// the bottom. It is also the one moment in this app worth lingering on. Not longer
    /// still, though: this runs its own timer while it is up (see `ConfettiWindow`), and
    /// every extra second is wakeups spent on decoration, which is precisely what SPEC §6
    /// is protecting.
    public static let duration: TimeInterval = 2.4

    /// Twenty-four pieces.
    ///
    /// Tuned against the two ends rather than picked. Below roughly a dozen the gaps
    /// between pieces are wide enough that it reads as debris falling, and past thirty the
    /// pieces start overlapping each other over a strip only two Dock cats wide, which at
    /// this size is a smear rather than confetti. Twenty-four keeps two or three pieces in
    /// flight across the pair at any instant.
    public static let count = 24

    /// The fraction of the burst each piece waits before it launches, per position in the
    /// order. Staggered for `HeartDrift.stagger`'s reason, only more so: confetti that all
    /// appears on one frame is a curtain dropping, not a shower.
    ///
    /// `stagger * (count - 1)` is the moment the last piece launches, and it must stay
    /// below 1 or that piece would never fall at all. That is checked in `ConfettiTests`
    /// rather than left as a comment, because it is the kind of invariant a later change
    /// to `count` breaks silently.
    public static let stagger: Double = 0.02

    /// How tall a piece is relative to its width.
    ///
    /// A shape choice rather than a drawing detail, so it lives here with the rest of the
    /// geometry. Wider than tall: a square tumbles into a square and the rotation is
    /// invisible, whereas an oblong shows its own turning, which is the entire reason the
    /// pieces rotate. Not thinner than this either, since a 4:1 sliver disappears edge-on
    /// for half of every spin and the shower then looks like it is dropping frames.
    public static let pieceAspect: CGFloat = 0.55

    /// The colours a piece can be, as flat RGB in `CatPalette`'s spelling.
    ///
    /// Expressed as `CatPalette.RGB` rather than `CGColor` because that is how every other
    /// colour in this package is written, and because these are palette entries: flat,
    /// fully opaque inks for pixel art, never gradients and never blended. The alpha the
    /// fade needs is a property of the *moment*, not of the colour, and lives on `Piece`.
    ///
    /// Five hues, spaced roughly evenly around the wheel, all in the same mid-luma register
    /// as the coats. The Dock's glass is light on a light wallpaper and near-black on a
    /// dark one, and a palette that includes white or a deep navy loses a fifth of the
    /// confetti on one of those two backgrounds. Five rather than eight for the same reason
    /// there are twenty-four pieces and not sixty: at 8 pt across, more hues than this stop
    /// reading as distinct colours and start reading as noise.
    public static let palette: [CatPalette.RGB] = [
        CatPalette.RGB(hex: 0xF2545B),   // coral red
        CatPalette.RGB(hex: 0xF5B841),   // gold
        CatPalette.RGB(hex: 0x4CB944),   // green
        CatPalette.RGB(hex: 0x3E8ED0),   // blue
        CatPalette.RGB(hex: 0xB56CE2)    // violet
    ]

    /// One piece of confetti, at one moment.
    public struct Piece: Equatable {
        /// Offset from the centre of the pair, in points, y upward, so a piece above the
        /// cats has a positive `y` and one that has fallen past their feet a negative one.
        ///
        /// The centre rather than the heads (which is where `HeartDrift` measures from)
        /// because the fall is symmetric about the pair: it starts as far above the heads
        /// as it ends below the feet, and hanging that off one edge would put the two
        /// margins in two different places.
        public let offset: CGPoint

        public let alpha: CGFloat

        /// Radians, counter-clockwise, about the piece's own centre.
        public let rotation: CGFloat

        /// An index into `palette`, fixed for the whole life of the piece. An index rather
        /// than a colour so that a burst can be compared for equality in a test without
        /// comparing six numbers per piece, and so the view has exactly one table to read.
        public let colorIndex: Int

        public init(offset: CGPoint, alpha: CGFloat, rotation: CGFloat, colorIndex: Int) {
            self.offset = offset
            self.alpha = alpha
            self.rotation = rotation
            self.colorIndex = colorIndex
        }
    }

    /// Every piece at this moment in the burst.
    ///
    /// `progress` is clamped rather than trusted, in exactly one place and for
    /// `HeartDrift.hearts`' reason: it comes from a wall clock that a stalled or suspended
    /// process can push well past the burst's own duration, and confetti still falling
    /// through the floor of the screen a minute after the birthday greeting is the visible
    /// form of that bug. Clamping here rather than in the view also means there is a single
    /// answer to "what does a progress of 4 mean" that the tests can pin down.
    ///
    /// `spread` is the half-width of the band the pieces start scattered across; `fall` is
    /// the whole vertical distance travelled, half of it above the centre of the pair and
    /// half below; `drift` is the furthest a piece may wander sideways out of its own
    /// column on the way down. A piece therefore never leaves `spread + drift` of the
    /// centre, which is what lets the window be sized so nothing is ever clipped.
    ///
    /// - Parameter seed: the burst. The same seed always produces the same twenty-four
    ///   pieces in the same columns, tumbling the same way, in the same colours.
    public static func pieces(progress: Double, seed: UInt64,
                              spread: CGFloat, fall: CGFloat, drift: CGFloat) -> [Piece] {
        let overall = min(max(0, progress), 1)
        var rng = SplitMix64(seed: seed)

        return (0..<count).map { index in
            // Every constant is drawn for every piece on every call, before anything is
            // decided about whether the piece has launched or is even visible. That is
            // load-bearing: the generator is re-seeded per call, so the draws must happen
            // in the same order every time or the same seed would produce a different
            // burst at a different progress, which is the exact bug the seed exists to
            // rule out. It is cheap enough not to cache, since seven draws times
            // twenty-four pieces, twenty-four times a second, is noise next to compositing
            // the window.
            let column = Double.random(in: -1...1, using: &rng)
            let flutterAmplitude = Double.random(in: 0.35...1, using: &rng)
            let flutterPhase = Double.random(in: 0..<(2 * Double.pi), using: &rng)
            let flutterCycles = Double.random(in: 1...2.5, using: &rng)
            let spin = Double.random(in: 0..<(2 * Double.pi), using: &rng)
            let turns = Double.random(in: 0.75...2.5, using: &rng)
            let clockwise = Bool.random(using: &rng)
            let colorIndex = Int.random(in: palette.indices, using: &rng)

            let start = Double(index) * stagger
            // Each piece runs its own 0…1 over what is left of the burst after its wait,
            // so the last one to launch still completes its fall and its fade before the
            // burst ends. That is the same division `HeartDrift` makes, for the same
            // reason.
            let local = min(max(0, (overall - start) / max(0.0001, 1 - start)), 1)

            // Sideways: the piece keeps its column and flutters about it, rather than
            // sliding steadily to one side. A constant lateral velocity reads as wind and
            // makes twenty-four pieces look like they are being blown off the same shelf;
            // a sine about the column is a flat piece of paper turning over as it falls,
            // which is what confetti actually does.
            let flutter = flutterAmplitude * sin(flutterPhase + local * flutterCycles * 2 * Double.pi)
            let x = CGFloat(column) * spread + drift * CGFloat(flutter)

            // Vertically: from half the fall above the centre of the pair to half of it
            // below, easing *in* rather than linear. Real gravity (local squared) leaves
            // the piece hanging at the top for a third of its life and then whipping past
            // the cats too fast to see; this mild acceleration keeps the whole fall
            // readable while still not looking like a lift descending.
            let fallen = local * (0.55 + 0.45 * local)
            let y = fall / 2 - fall * CGFloat(fallen)

            let rotation = spin + (clockwise ? -1 : 1) * turns * 2 * Double.pi * local

            return Piece(offset: CGPoint(x: x, y: y),
                         alpha: alpha(at: local),
                         rotation: CGFloat(rotation),
                         colorIndex: colorIndex)
        }
    }

    /// In fast, out slow. Zero at both ends, so no piece pops into existence over the cats
    /// and none is left painted on the Dock after the burst.
    ///
    /// The fade-in is half `HeartDrift`'s. A piece enters above the pair, where there is
    /// nothing to compare it against, so it can afford to arrive quickly, whereas a heart
    /// appears between two cats the eye is already on. The fade-out starts at 0.7 so a
    /// piece is nearly gone by the time it reaches the cats' feet, which reads as confetti
    /// settling rather than as confetti falling through the bottom of the screen.
    private static func alpha(at local: Double) -> CGFloat {
        let fadeIn = 0.1, fadeOut = 0.7
        if local <= 0 || local >= 1 { return 0 }
        if local < fadeIn { return CGFloat(local / fadeIn) }
        if local > fadeOut { return CGFloat((1 - local) / (1 - fadeOut)) }
        return 1
    }
}

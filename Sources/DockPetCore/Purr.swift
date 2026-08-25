//
//  Purr.swift. [M13] Press and hold the cat: what a press of a given length means, and
//  what the purr indicator says while the hold lasts. Pure.
//
//  SPEC §5: no AppKit. The whole feature is one number and two decisions taken from it,
//  and those decisions sit directly on top of the app's only existing interaction: a
//  click opens the prompt menu (§7 M10). Getting the split wrong does not look wrong on
//  screen: the cat still sits there taking clicks, it has just quietly stopped answering
//  some of them. That is exactly the class of bug §9 says must be checked without a
//  screen, so the decision lives here and `PetView` only reports mouse events into it.
//
//  Elapsed time is a parameter, never a clock read in here, which is the same rule
//  `BehaviorMachine.advance(by:)` and `KissRoutine.advance(by:touching:)` follow. The
//  AppKit half owns the clock; this owns what its readings mean.
//
//  What is deliberately *not* here: the sitting, the bubble and the pinning of the pet
//  window's mouse events. Those are AppKit's, and keeping them out is what lets a two
//  minute hold be run through in a millisecond by the test harness.
//

import Foundation

/// Press-and-hold on the cat: the threshold, the two ways a press can end, and the
/// indicator that runs while it is being held.
public enum Purr {

    // MARK: - The threshold

    /// How long the button must be down before a press stops being a click and becomes
    /// petting the cat.
    ///
    /// **0.35 s, and the number is the whole feature.** It sits between two failure modes:
    ///
    /// * *Too short* and an ordinary click starts petting the cat. A click is usually
    ///   80 to 120 ms, but the tail is long. A click that lands while the user is still
    ///   deciding, or a trackpad press held through a small hand movement, reaches past
    ///   200 ms without ever being meant as a hold. Below that the app would randomly
    ///   swallow the menu, which is the one thing §7 M10 exists to open.
    /// * *Too long* and the cat ignores a deliberate press. There is no affordance for
    ///   this interaction at all (no button, no tooltip, nothing on screen that says a
    ///   hold does anything, the same problem the pointing-hand cursor was added for in
    ///   M10), so the first half-second of silence is not read as "keep holding", it is
    ///   read as "nothing happened".
    ///
    /// **Rejected: 0.5 s**, iOS's long-press default. It is the right number for a gesture
    /// the user already knows exists, and the wrong one for a gesture they are discovering
    /// by accident. **Rejected: 0.15 s**, which felt immediate in isolation and lost real
    /// clicks the moment it was swept across the range in `PurrTests`. 0.35 s is roughly
    /// three times an ordinary click and comfortably inside the quarter-second-ish window
    /// where a delay still reads as a response rather than as a stall.
    public static let holdThreshold: TimeInterval = 0.35

    /// What a press that has been down this long currently *is*.
    ///
    /// Only two answers, because there are only two things the app can be doing: still
    /// waiting to find out (and so showing nothing, changing nothing), or petting the cat.
    public enum Press: String, Equatable {
        /// Not yet a hold. If the button comes up now, this was a click.
        case deciding
        /// Past the threshold: the cat is sitting and purring for as long as this lasts.
        case purring
    }

    /// Classify a press that has been held for `elapsed`.
    ///
    /// A negative `elapsed` reads as `deciding` rather than trapping: the caller measures
    /// against a monotonic clock, but a stalled or rescheduled timer can hand back a step
    /// that makes no sense, and the safe answer to nonsense is the one that leaves the
    /// existing click behaviour alone.
    public static func press(heldFor elapsed: TimeInterval) -> Press {
        elapsed >= holdThreshold ? .purring : .deciding
    }

    // MARK: - Letting go

    /// What should happen when the button comes up, or when the pointer slides off the
    /// cat, which ends a press just as finally.
    public enum Release: String, Equatable {
        /// The M10 path, untouched: open the prompt menu where the press landed.
        case menu
        /// Stop purring, put the cat back to what it was doing.
        case endPurr
        /// A press that was neither: too short to be a hold, and no longer on the cat, so
        /// there is nothing it could have meant. Distinct from `.menu` on purpose:
        /// pressing the cat and sliding away is how a user backs out of a click, and
        /// popping a menu up at the end of that would be the app arguing with them.
        case nothing
    }

    /// Decide what a press ending now was.
    ///
    /// `overPet` is whether the pointer is still over solid sprite pixels, tested against
    /// the same `AlphaMask` the click itself uses and resolved by the caller.
    ///
    /// The order of the two tests is the requirement: **elapsed first**. A hold that has
    /// already started purring ends the purr whether or not the pointer wandered, and can
    /// never also open the menu. If `overPet` were checked first, letting go of a long
    /// hold with the pointer still on the cat would be indistinguishable from a click.
    public static func release(after elapsed: TimeInterval, overPet: Bool) -> Release {
        if press(heldFor: elapsed) == .purring { return .endPurr }
        return overPet ? .menu : .nothing
    }

    // MARK: - The indicator

    /// The purr, as one glyph.
    ///
    /// **Not `💕`.** That is the kiss's (`HeartsWindow.glyph`), and it means something
    /// specific in this app: two cats, romance, an event that happens *to* the pair. A
    /// hand on one cat is not that, and reusing the heart would make the two read as the
    /// same thing at a glance, which is the only way anyone reads a 16 pt glyph over the
    /// Dock.
    ///
    /// **Not `💤`**, which is sleep and is already a state the pet has. **Not words**,
    /// not "purr…" and not "prrr", because this interaction is the one thing in the app
    /// that is not mediated by words, and putting a caption on it would undo the point
    /// of it.
    ///
    /// A musical note is a *sound the cat is making*, which is literally what a purr is,
    /// and it reads as contentment without claiming speech. It is also a text glyph rather
    /// than an emoji, so it takes the bubble's ink colour and sits in the same near-black
    /// as the cat's own outline.
    public static let glyph = "♪"

    /// How long each glyph stays before the next one joins it.
    ///
    /// A purr is a rhythm, so the indicator has one: slow enough that the bubble is not
    /// strobing (it is redrawn each beat), fast enough that a hold of an ordinary length
    /// visibly *does* something rather than showing one motionless mark.
    public static let beat: TimeInterval = 0.5

    /// How many glyphs the cycle reaches before starting over.
    ///
    /// Three. The indicator is not a progress bar (a hold has no end to progress toward),
    /// so it loops rather than filling up, and three is enough for the loop to be visible
    /// while keeping the bubble near the minimum width `BubbleView` already enforces.
    public static let maximumGlyphs = 3

    /// What the indicator says after `elapsed` of holding, or `nil` when there is nothing
    /// to show yet.
    ///
    /// `nil` for the whole deciding phase, and that is a requirement rather than a detail:
    /// an ordinary click must leave nothing at all behind it, so the bubble cannot flash
    /// up for the frame between the button going down and coming back up.
    public static func indicator(heldFor elapsed: TimeInterval) -> String? {
        guard press(heldFor: elapsed) == .purring else { return nil }

        // Beats since the purr began, wrapped into 1...maximumGlyphs. `floor` on a
        // non-negative value, so integer truncation is the same thing and cheaper.
        let beats = Int((elapsed - holdThreshold) / beat)
        let count = beats % maximumGlyphs + 1
        return Array(repeating: glyph, count: count).joined(separator: " ")
    }
}

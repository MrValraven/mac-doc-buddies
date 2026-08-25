//
//  Kiss.swift — [M12] two cats crossing the Dock to kiss, and the hearts over them.
//
//  SPEC §5: no AppKit. The whole sequence is a phase and a clock, so it can be run to
//  completion in a test rather than described in a commit message — SPEC §9, on a feature
//  that takes six seconds of screen nobody reviewing this can watch.
//
//  What is deliberately *not* here: the walking itself. `Walker.walk(toward:)` moves a cat
//  and this decides what the pair is doing; keeping them apart is what lets the routine be
//  tested without a strip, a Dock or a screen.
//

import CoreGraphics
import Foundation

/// The kiss, from the first step toward each other to the pair walking away again.
///
/// Driven by the app's animation tick: the caller reports how much time passed and whether
/// the two frames are touching *right now*, and gets back the phase to render. It owns no
/// timer of its own for the same reason nothing else in DockPetCore does — one tick drives
/// every pet (SPEC §6).
public struct KissRoutine: Equatable {

    public enum Phase: String, Equatable {
        /// Both cats walk to the midpoint between them, facing each other.
        case approach
        /// The left-hand cat announces the kiss.
        case announce
        /// Bubble down, hearts up.
        case kiss
        /// Hearts down, and the left-hand cat says what the kiss was for.
        case declare
        /// The right-hand cat answers it. A phase of its own rather than a second bubble
        /// during `declare`: two cats standing against each other share the space one
        /// bubble needs, so the pair takes turns — the same rule the meeting follows.
        case reply
        /// They turn around and walk away, still under the routine's control, so the
        /// meeting logic cannot read the overlap they are standing in as a fresh meeting.
        case part
        /// Over. The pair is back under its own behaviour machine.
        case done
    }

    /// How long the pair is given to reach each other before the kiss is called off.
    ///
    /// A ceiling rather than a promise: the approach depends on a strip that can shrink,
    /// move edge or vanish under them mid-walk, and a routine with no way to give up would
    /// hold both cats out of their own behaviour machine forever. Ten seconds is longer
    /// than the widest Dock takes to cross at the default 30 pt/s.
    public static let approachCeiling: TimeInterval = 10

    /// Long enough to read three words and see who said them.
    public static let announceDuration: TimeInterval = 1.5

    /// The hearts' whole life. `HeartDrift.duration` matches it; they are the same moment
    /// seen from two sides.
    public static let kissDuration: TimeInterval = 1.5

    /// Long enough to read the line the hearts were about.
    public static let declareDuration: TimeInterval = 1.5

    /// The same, for the answer. Written separately rather than shared with the line it
    /// answers so the two can be tuned apart if one ever grows longer than the other.
    public static let replyDuration: TimeInterval = 1.5

    /// Long enough for the two frames to stop overlapping at walking speed, so the pair is
    /// visibly apart before anything else looks at them.
    public static let partDuration: TimeInterval = 0.8

    public private(set) var phase: Phase = .approach
    public private(set) var timeInPhase: TimeInterval = 0

    /// True when the routine ended without a kiss — the pair never reached each other.
    /// Kept separate from `phase` because both endings are `.done` to the caller, and only
    /// this one needs explaining in the log.
    public private(set) var abandoned = false

    public var isActive: Bool { phase != .done }

    public init() {}

    /// Advance the routine and report the phase either side of the step.
    ///
    /// Returns both, in the shape `Pet.advanceBehavior` already uses, because every phase
    /// change here has a one-shot side effect hanging off it — a bubble going up, hearts
    /// appearing, two cats turning round — and the caller needs to know a change happened
    /// rather than diff the phase itself.
    ///
    /// At most one phase per call. A stalled process hands back a huge elapsed time, and
    /// running the whole kiss inside one tick would show none of it: the cats would touch
    /// and separate with no line and no hearts, which is the entire feature skipped in the
    /// one situation where the user is already watching a frozen screen.
    @discardableResult
    public mutating func advance(by dt: TimeInterval,
                                 touching: Bool) -> (previous: Phase, current: Phase) {
        let previous = phase
        guard dt > 0, phase != .done else { return (previous, phase) }

        timeInPhase += min(dt, BehaviorMachine.maximumStep)

        switch phase {
        case .approach:
            // Touching is tested before the ceiling, so a pair that arrives on the very
            // last tick kisses instead of being called off for being slow.
            if touching {
                enter(.announce)
            } else if timeInPhase >= Self.approachCeiling {
                abandoned = true
                enter(.done)
            }
        case .announce:
            if timeInPhase >= Self.announceDuration { enter(.kiss) }
        case .kiss:
            if timeInPhase >= Self.kissDuration { enter(.declare) }
        case .declare:
            if timeInPhase >= Self.declareDuration { enter(.reply) }
        case .reply:
            if timeInPhase >= Self.replyDuration { enter(.part) }
        case .part:
            if timeInPhase >= Self.partDuration { enter(.done) }
        case .done:
            break
        }

        return (previous, phase)
    }

    private mutating func enter(_ next: Phase) {
        phase = next
        timeInPhase = 0
    }
}

/// [M12] Where the hearts are, and how solid, at a moment in the kiss.
///
/// Pure arithmetic on a 0…1 progress, so the one part of the hearts that can be wrong in a
/// way nobody would notice — a heart that never fades, one that starts off-centre, four
/// that move as a single block — is checkable without a screen. The view that draws them
/// owns no timing of its own; it asks this.
public enum HeartDrift {

    /// The same moment `KissRoutine.kiss` lasts. Written as one so the hearts cannot
    /// outlive the phase that shows them.
    public static let duration: TimeInterval = KissRoutine.kissDuration

    /// Four. Three reads as a shrug and five needs more width than two Dock-sized cats
    /// have between them.
    public static let count = 4

    /// The fraction of the kiss each heart waits before it starts, per position in the
    /// fan. Staggered rather than simultaneous: four hearts appearing on one frame is a
    /// puff of smoke, not affection.
    public static let stagger: Double = 0.15

    public struct Heart: Equatable {
        /// Offset from the point between the two cats, in points, y upward.
        public let offset: CGPoint
        public let alpha: CGFloat

        public init(offset: CGPoint, alpha: CGFloat) {
            self.offset = offset
            self.alpha = alpha
        }
    }

    /// Every heart at this moment.
    ///
    /// `progress` is clamped rather than trusted: it comes from a phase clock that a
    /// stalled tick can push past its own duration, and hearts still climbing after the
    /// cats have walked away is the visible form of that bug.
    public static func hearts(progress: Double, spread: CGFloat, rise: CGFloat) -> [Heart] {
        let overall = min(max(0, progress), 1)

        return (0..<count).map { index in
            let start = Double(index) * stagger
            // Each heart runs its own 0…1 over what is left of the kiss after its wait, so
            // the last one still completes its rise and its fade before the phase ends.
            let local = min(max(0, (overall - start) / max(0.0001, 1 - start)), 1)

            let fan = count > 1 ? (CGFloat(index) / CGFloat(count - 1)) * 2 - 1 : 0
            let offset = CGPoint(x: fan * spread * CGFloat(local), y: rise * CGFloat(local))

            return Heart(offset: offset, alpha: alpha(at: local))
        }
    }

    /// In quickly, out slowly. Zero at both ends, so a heart is never cut off mid-flight
    /// and never left painted on the Dock after the kiss.
    private static func alpha(at local: Double) -> CGFloat {
        let fadeIn = 0.2, fadeOut = 0.6
        if local <= 0 || local >= 1 { return 0 }
        if local < fadeIn { return CGFloat(local / fadeIn) }
        if local > fadeOut { return CGFloat((1 - local) / (1 - fadeOut)) }
        return 1
    }
}

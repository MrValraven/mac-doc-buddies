//
//  Scene.swift: [M13] the birthday scene. The two cats stop what they are doing, walk to
//  each other, and make a fuss of her, without her having clicked anything.
//
//  SPEC §5: no AppKit. The windows, the confetti and the bubbles are the app's problem;
//  the order things happen in, and how long each one lasts, is not.
//
//  ## Why this is a routine and not a script
//
//  Everything else the cats do is either continuous (walking, sleeping) or answers a click.
//  This answers a *date*, runs for about ten seconds, and happens once a year. That makes
//  it the one sequence in the app with no way to try again: if it deadlocks, or fires
//  twice, or is cut off half way, the failure lands on the single morning it exists for.
//
//  So it is written as KissRoutine's sibling, and deliberately so. The kiss already solved
//  the same four problems, and solving them a second way would mean two sets of bugs:
//
//    * a bounded step, so a stalled process cannot burn the whole scene in one tick
//    * at most one phase per call, for the same reason
//    * a ceiling on the approach, so a Dock that moved cannot strand two cats walking
//      toward a point that no longer exists
//    * both endings spelled `.done`, with the abandoned one flagged separately, because
//      the caller tears down identically and only the log needs to tell them apart
//

import Foundation

/// The birthday scene: approach, gather, announce, celebrate, wish, part.
public struct BirthdayScene: Equatable {

    /// Which of the pair is speaking. Settled once by the caller when the scene begins,
    /// never re-read per frame: during the approach the two cats cross and re-cross, and
    /// deciding "who is on the left" every tick moves the line from one cat to the other
    /// half way through a sentence. The kiss learned this the same way.
    public enum Speaker: String, Equatable {
        case left, right
    }

    public enum Phase: String, Equatable, CaseIterable {
        /// Both cats walk to the point between them, whatever else they were doing.
        case approach
        /// They stop, turn to face each other, and sit. A beat before anyone speaks, so
        /// the line does not arrive while they are still visibly moving.
        case gather
        /// The left cat gives the birthday line.
        case announce
        /// Confetti falls and the hearts rise. Nobody talks over it.
        case celebrate
        /// The right cat answers, so the scene reads as the pair rather than a monologue.
        case wish
        /// Both turn around and walk away, which is what makes the ending look like the
        /// cats decided it rather than like a cutscene stopping.
        case part
        case done

        /// Who says something when this phase begins, or `nil` for the phases that are
        /// movement and decoration.
        public var speaker: Speaker? {
            switch self {
            case .announce: return .left
            case .wish:     return .right
            default:        return nil
            }
        }

        /// Whether confetti should be on screen during this phase.
        public var showsConfetti: Bool { self == .celebrate }

        /// Whether the hearts should be rising during this phase.
        ///
        /// The same phase as the confetti rather than the one after it. Two bursts in
        /// sequence read as the app doing two things; together they read as one moment,
        /// which is the whole point of the scene.
        public var showsHearts: Bool { self == .celebrate }
    }

    /// How long the pair has to reach each other before the scene gives up.
    ///
    /// The same ten seconds the kiss allows, for the same failure: a Dock that moved or a
    /// strip that shrank mid-approach. Ten seconds is far longer than the walk needs and
    /// far shorter than she would spend wondering what the cats are doing.
    public static let approachCeiling: TimeInterval = 10

    /// A beat to settle before the first line.
    public static let gatherDuration: TimeInterval = 0.8
    /// Long enough to read "Happy birthday, Philippine!" without hurrying.
    public static let announceDuration: TimeInterval = 2.5
    /// The confetti's own length. The view is handed a progress across exactly this.
    public static let celebrateDuration: TimeInterval = 3.0
    /// The answer, given the same room as the announcement.
    public static let wishDuration: TimeInterval = 2.5
    /// Turning round, before the walk away becomes an ordinary walk again.
    public static let partDuration: TimeInterval = 0.8

    public private(set) var phase: Phase = .approach
    public private(set) var timeInPhase: TimeInterval = 0

    /// True when the scene ended without ever happening, because the pair never met.
    ///
    /// Separate from `phase` because both endings are `.done` to the caller: it releases
    /// the cats and takes the windows down identically either way, and only the log needs
    /// to say which one it was.
    public private(set) var wasAbandoned = false

    public var isFinished: Bool { phase == .done }

    public init() {}

    /// The pair has reached each other. A one-way door.
    ///
    /// A method rather than a `touching:` parameter on `advance`, which is how the kiss
    /// spells the same thing. Two cats standing nose to nose overlap for many consecutive
    /// ticks, so the caller would be passing `touching: true` for the whole rest of the
    /// scene, and every phase after the approach would have to remember to ignore it.
    /// Arriving is an event; making it one removes the question.
    public mutating func arrive() {
        guard phase == .approach else { return }
        enter(.gather)
    }

    /// Advance the scene, reporting the phase either side of the step.
    ///
    /// Both phases are returned, in the shape `Pet.advanceBehavior` and `KissRoutine`
    /// already use, because every transition here has a one-shot side effect hanging off
    /// it: a bubble going up, confetti starting, two cats turning round. The caller needs
    /// to be told a change happened rather than diff the phase itself and hope it did not
    /// miss one.
    ///
    /// At most one phase per call, and the step is bounded. A stalled process hands back a
    /// huge elapsed time, and running the whole scene inside one tick would show her none
    /// of it: the cats would touch and separate with no line, no confetti and no hearts,
    /// on the one morning it exists for.
    @discardableResult
    public mutating func advance(by dt: TimeInterval) -> (previous: Phase, current: Phase) {
        let previous = phase
        guard dt > 0, phase != .done else { return (previous, phase) }

        timeInPhase += min(dt, BehaviorMachine.maximumStep)

        switch phase {
        case .approach:
            // Nothing to test but the ceiling: arrival comes in through `arrive()`, which
            // the caller drives from the live frames.
            if timeInPhase >= Self.approachCeiling {
                wasAbandoned = true
                enter(.done)
            }
        case .gather:
            if timeInPhase >= Self.gatherDuration { enter(.announce) }
        case .announce:
            if timeInPhase >= Self.announceDuration { enter(.celebrate) }
        case .celebrate:
            if timeInPhase >= Self.celebrateDuration { enter(.wish) }
        case .wish:
            if timeInPhase >= Self.wishDuration { enter(.part) }
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

    /// Should the scene run at all?
    ///
    /// Every input is passed in, including today's date as a stamp, for the reason SPEC §9
    /// gives: a birthday feature that can only be tested on the birthday is not tested.
    ///
    /// The day stamp is `Occasion.dayStamp`, the same string the dedication already
    /// persists, so "has it run today" survives a restart and a laptop that was shut for a
    /// week. Comparing full stamps rather than month and day is what stops last year's run
    /// suppressing this year's.
    public static func shouldRun(isBirthday: Bool, lastRunDay: String?, today: String) -> Bool {
        guard isBirthday else { return false }
        return lastRunDay != today
    }
}

//
//  Cuddle.swift: [M14] the cuddle nap. Two cats decide to sleep against each other for a
//  while, say three soft things about it, and then get on with their day.
//
//  SPEC §5: no AppKit. The windows and the sheets are the app's problem; the order things
//  happen in, and how long each one lasts, is not.
//
//  ## Why a third routine rather than a flag on the kiss
//
//  The kiss and the birthday scene already have this shape, and the nap is the same animal:
//  a sequence that takes both cats away from their behaviour machines, runs on the app's
//  own tick, and must not be able to strand them. What is different is everything the user
//  sees. The kiss is six seconds of hearts and is over; the nap is twenty seconds of two
//  cats asleep, which is the longest anything in this app holds a pair. Folding it into
//  KissRoutine would mean a phase list where half the cases are inert for either caller,
//  and a duration table where half the constants belong to the other feature.
//
//  What is deliberately copied is the machinery, not the code: a bounded step, at most one
//  phase per call, a ceiling on the approach, and both endings spelled `.done` with the
//  abandoned one flagged separately. Solving those a second way would mean two sets of bugs.
//

import Foundation

/// The nap, from setting off to walking away again: approach, settle, snuggle, reply,
/// sleep, wake, part.
///
/// Driven by the app's animation tick, like everything else here that has a clock. It owns
/// no timer of its own for the reason SPEC §6 gives: one tick drives every pet.
public struct CuddleRoutine: Equatable {

    /// Which of the pair is speaking. Settled once by the caller when the nap begins, never
    /// re-read per frame: during the approach the two cats cross and re-cross, and deciding
    /// "who is on the left" every tick moves a line from one cat to the other half way
    /// through it. The kiss and the scene both learned this the same way.
    public enum Speaker: String, Equatable {
        case left, right
    }

    public enum Phase: String, Equatable, CaseIterable {
        /// Both walk to the point between them, whatever else they were doing. A walk, not
        /// the kiss's run: cats on their way to a nap are in no hurry, and the contrast
        /// with the kiss is most of what tells the two sequences apart from across a room.
        case approach
        /// They stop, turn to face each other, and sit. A beat before anyone speaks, so the
        /// line does not arrive while they are still visibly moving.
        case settle
        /// The left cat suggests it.
        case snuggle
        /// The right cat answers. A phase of its own rather than a second bubble during
        /// `snuggle`: two cats lying against each other share the space one bubble needs,
        /// so the pair takes turns, which is the rule the meeting and the kiss both follow.
        case reply
        /// Both asleep, nobody talking. The long phase, and the whole point of the feature.
        case sleep
        /// The left cat wakes up with something to say about it.
        case wake
        /// They turn around and walk away, still under the routine's control, so the
        /// meeting logic cannot read the overlap they are standing in as a fresh meeting.
        case part
        /// Over. The pair is back under its own behaviour machine.
        case done

        /// Who says something when this phase begins, or `nil` for the phases that are
        /// movement and sleeping.
        ///
        /// The left cat opens and closes, the right cat answers in between: the same
        /// division the kiss uses, so a pair that kisses and then naps an hour later does
        /// not appear to swap personalities.
        public var speaker: Speaker? {
            switch self {
            case .snuggle: return .left
            case .reply:   return .right
            case .wake:    return .left
            default:       return nil
            }
        }

        /// Whether the pair should be on the `sleep` sheet during this phase.
        ///
        /// Only the one phase. They sit to talk either side of it: a cat that says
        /// something while lying flat asleep reads as a bubble that has come up over the
        /// wrong cat.
        public var isAsleep: Bool { self == .sleep }
    }

    /// How long the pair has to reach each other before the nap is called off.
    ///
    /// The same ten seconds the kiss and the scene allow, for the same failure: a strip
    /// that moved, shrank or vanished under them mid-walk. A routine with no way to give up
    /// would hold both cats out of their own behaviour machine forever.
    public static let approachCeiling: TimeInterval = 10

    /// A beat to curl up before the first line.
    public static let settleDuration: TimeInterval = 0.8

    /// Long enough to read a short line and see which cat said it.
    public static let snuggleDuration: TimeInterval = 2

    /// The same, for the answer. Written separately rather than shared with the line it
    /// answers so the two can be tuned apart if one ever grows longer than the other.
    public static let replyDuration: TimeInterval = 2

    /// The nap itself.
    ///
    /// Eight seconds is the number that makes this a nap rather than a blink. Long enough
    /// that catching sight of the Dock mid-way shows two cats asleep together with no
    /// explanation on screen, which is the feature; short enough that a pair is never
    /// unavailable long enough for the user to wonder what is wrong with them.
    public static let sleepDuration: TimeInterval = 8

    /// Long enough to read the line they wake up with.
    public static let wakeDuration: TimeInterval = 2

    /// Long enough for the two frames to stop overlapping at walking speed, so the pair is
    /// visibly apart before anything else looks at them.
    public static let partDuration: TimeInterval = 0.8

    public private(set) var phase: Phase = .approach
    public private(set) var timeInPhase: TimeInterval = 0

    /// True when the nap ended without ever happening, because the pair never met.
    ///
    /// Separate from `phase` because both endings are `.done` to the caller: it releases
    /// the cats and takes any bubble down identically either way, and only the log needs to
    /// say which one it was.
    public private(set) var wasAbandoned = false

    public var isFinished: Bool { phase == .done }

    public init() {}

    /// The pair has reached each other. A one-way door.
    ///
    /// A method rather than a `touching:` parameter on `advance`, which is how the birthday
    /// scene spells the same thing and why it is spelled that way here: two cats lying
    /// against each other overlap for every tick of the nap, so the caller would be passing
    /// `touching: true` for the whole of it and every phase after the approach would have
    /// to remember to ignore it. Arriving is an event; making it one removes the question.
    public mutating func arrive() {
        guard phase == .approach else { return }
        enter(.settle)
    }

    /// Advance the routine and report the phase either side of the step.
    ///
    /// Both are returned, in the shape `KissRoutine` and `BirthdayScene` already use,
    /// because every transition here has a one-shot side effect hanging off it: a bubble
    /// going up, two cats lying down, two cats turning round. The caller needs to be told a
    /// change happened rather than diff the phase itself and hope it did not miss one.
    ///
    /// At most one phase per call, and the step is bounded. A stalled process hands back a
    /// huge elapsed time, and running the whole nap inside one tick would show none of it.
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
        case .settle:
            if timeInPhase >= Self.settleDuration { enter(.snuggle) }
        case .snuggle:
            if timeInPhase >= Self.snuggleDuration { enter(.reply) }
        case .reply:
            if timeInPhase >= Self.replyDuration { enter(.sleep) }
        case .sleep:
            if timeInPhase >= Self.sleepDuration { enter(.wake) }
        case .wake:
            if timeInPhase >= Self.wakeDuration { enter(.part) }
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

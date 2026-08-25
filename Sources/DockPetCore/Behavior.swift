//
//  Behavior.swift — how the pet moves. Pure and testable.
//
//  SPEC §5: no AppKit in this file. That is enforced by construction here — DockPetCore
//  links CoreGraphics only, so an accidental `import AppKit` fails to build.
//
//  M3 supplies the walk; M5 adds the weighted state machine that decides when to do it.
//

import CoreGraphics
import Foundation

/// Walks back and forth along a strip, turning at each end.
///
/// Holds a *distance along the strip* rather than a point, so it is independent of where
/// the strip currently is. That is what lets the Dock move, resize, or change screens
/// without the pet losing its place — SPEC §7 M3 requires the position be recomputed
/// against the live strip every tick, never cached.
public struct Walker: Equatable {

    public enum Direction: Int, Equatable {
        case forward = 1
        case backward = -1

        public var reversed: Direction { self == .forward ? .backward : .forward }
    }

    /// Distance from the near end of the strip, in points.
    public private(set) var distance: CGFloat

    public private(set) var direction: Direction

    /// Points per second. SPEC §7 M3 asks for ~30 px/s.
    public var speed: CGFloat

    /// Largest time step honoured in one `advance`.
    ///
    /// A timer that stalls — display sleep, a long menu tracking loop, the machine being
    /// suspended — hands back a huge elapsed time on the next fire. Without a ceiling the
    /// pet would teleport the length of the Dock. Clamping makes a stall look like a brief
    /// pause instead.
    public static let maximumStep: TimeInterval = 0.25

    public init(distance: CGFloat = 0, direction: Direction = .forward, speed: CGFloat = 30) {
        self.distance = distance
        self.direction = direction
        self.speed = speed
    }

    /// Advance by `dt` seconds, staying within `0...maxDistance` and reversing at each end.
    ///
    /// `maxDistance` is passed in per call rather than stored, because the strip it comes
    /// from can change under us at any tick.
    public mutating func advance(by dt: TimeInterval, maxDistance: CGFloat) {
        let limit = max(0, maxDistance)

        // A strip with no room to walk: park at the near end and stop.
        guard limit > 0 else {
            distance = 0
            return
        }

        let step = CGFloat(min(max(0, dt), Self.maximumStep)) * speed
        var next = distance + step * CGFloat(direction.rawValue)

        // Reverse at whichever end we reached. A single step cannot cross both ends
        // because `step` is bounded and `limit > 0`, so one test each is enough.
        if next > limit {
            next = limit
            direction = direction.reversed
        } else if next < 0 {
            next = 0
            direction = direction.reversed
        }

        distance = next
    }

    /// Bring the walker back inside a strip that has shrunk beneath it.
    ///
    /// Called when the strip changes — a smaller screen, a Dock that moved edge — so the
    /// pet never sits beyond the end it is meant to turn at.
    public mutating func clamp(to maxDistance: CGFloat) {
        distance = min(max(0, distance), max(0, maxDistance))
    }

    /// [M11] Turn around where you stand. Used when two pets meet: they part rather than
    /// walking through each other.
    public mutating func reverse() {
        direction = direction.reversed
    }

    /// [M12] Walk toward one point on the strip instead of back and forth, and say whether
    /// we are standing on it. Used by the kiss, where two cats have somewhere to be.
    ///
    /// Deliberately *not* built on `advance`: that method's whole job is to turn round at
    /// the ends, which is the one thing a cat crossing the Dock to meet another must not
    /// do. The bounded step and the clamp to the strip are shared, because a stalled timer
    /// and a shrinking Dock are no less real during a kiss.
    ///
    /// `target` is clamped to the strip rather than refused: the midpoint between two cats
    /// is derived from live frames, and a Dock that shrinks mid-approach must leave them
    /// walking to the nearest reachable point rather than to a place that no longer exists.
    ///
    /// [M14] `speedMultiplier` is how the kiss makes the pair *run* at each other instead
    /// of strolling over. It multiplies the speed rather than the time step on purpose:
    /// `maximumStep` is a ceiling on how much *time* one tick may account for, so a stalled
    /// timer covers a quarter-second of running here, and stretching `dt` instead would
    /// quietly raise that ceiling and let a running cat teleport further than a walking one
    /// ever could.
    ///
    /// Passed per call rather than kept in `speed`, which belongs to the user's config: a
    /// kiss that ended between the two writes, whether abandoned or with the cast rebuilt
    /// mid-approach, would leave a cat running for the rest of the session.
    @discardableResult
    public mutating func walk(toward target: CGFloat, by dt: TimeInterval,
                              maxDistance: CGFloat,
                              speedMultiplier: CGFloat = 1) -> Bool {
        let limit = max(0, maxDistance)

        // The same answer `advance` gives a strip with no room: park at the near end. A
        // cat inching toward zero on a Dock that has no walkable length is a worse reading
        // of the situation than a cat that has simply stopped.
        guard limit > 0 else {
            distance = 0
            return true
        }

        let goal = min(max(0, target), limit)

        let step = CGFloat(min(max(0, dt), Self.maximumStep)) * speed * max(0, speedMultiplier)
        let gap = goal - distance

        // Arrival covers both "already there" and "this step would overshoot". Landing on
        // the target rather than oscillating around it is what lets the caller treat
        // arrival as a one-way door.
        guard abs(gap) > step else {
            distance = goal
            return true
        }

        direction = gap > 0 ? .forward : .backward
        distance += step * CGFloat(direction.rawValue)
        return false
    }
}

// MARK: - State machine (M5)

/// What the pet is doing. SPEC §7 M5.
public enum PetState: String, CaseIterable, Equatable {
    case walk, idle, sit, sleep

    /// Only walking moves the pet along the strip. The rest are stationary, which is what
    /// lets the animation timer suspend while they run (SPEC §6).
    public var isMoving: Bool { self == .walk }
}

public struct WeightedTransition: Equatable {
    public let state: PetState
    public let weight: Double

    public init(_ state: PetState, _ weight: Double) {
        self.state = state
        self.weight = weight
    }
}

/// How long a state lasts and what it tends to become next.
public struct StateProfile: Equatable {
    public let minDwell: TimeInterval
    public let maxDwell: TimeInterval
    public let transitions: [WeightedTransition]

    public init(minDwell: TimeInterval, maxDwell: TimeInterval, transitions: [WeightedTransition]) {
        self.minDwell = minDwell
        self.maxDwell = maxDwell
        self.transitions = transitions
    }
}

/// Deterministic PRNG (SplitMix64), so weighted randomness stays testable.
///
/// The system generator would make the state machine unverifiable — SPEC §9 requires the
/// behaviour be checkable, and "it looked plausible when I watched it" is not a check.
public struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Decides what the pet is doing, given elapsed time.
///
/// SPEC §5/§7 M5: pure and testable, no AppKit. Takes elapsed time, returns a state.
/// Transitions never target the current state, so every transition is a visible change.
public struct BehaviorMachine {

    /// Longest time step honoured in one `advance`, for the same reason `Walker` has one:
    /// a stalled or suspended process must not burn through a dozen states at once.
    public static let maximumStep: TimeInterval = 1.0

    /// Tuned so the pet mostly walks, pauses often and briefly, sits regularly, and sleeps
    /// rarely — the rhythm Shimeji and oneko get right (SPEC §10).
    ///
    /// Weights alone do not determine the feel: a state's *share of the clock* is roughly
    /// its visit rate times its dwell length. An early draft gave sleep a low weight (10)
    /// but a 15–45 s dwell, and it still ate 34% of the day. The dwell ranges below matter
    /// as much as the weights, and `StateMachineTests` measures the resulting distribution
    /// rather than trusting either.
    public static let defaultProfiles: [PetState: StateProfile] = [
        .walk: StateProfile(minDwell: 8, maxDwell: 22, transitions: [
            WeightedTransition(.idle, 58), WeightedTransition(.sit, 37), WeightedTransition(.sleep, 5),
        ]),
        .idle: StateProfile(minDwell: 1.5, maxDwell: 4, transitions: [
            WeightedTransition(.walk, 78), WeightedTransition(.sit, 20), WeightedTransition(.sleep, 2),
        ]),
        .sit: StateProfile(minDwell: 3, maxDwell: 9, transitions: [
            WeightedTransition(.walk, 62), WeightedTransition(.idle, 32), WeightedTransition(.sleep, 6),
        ]),
        .sleep: StateProfile(minDwell: 12, maxDwell: 30, transitions: [
            WeightedTransition(.walk, 60), WeightedTransition(.idle, 32), WeightedTransition(.sit, 8),
        ]),
    ]

    public private(set) var state: PetState
    public private(set) var timeInState: TimeInterval = 0
    public private(set) var currentDwell: TimeInterval = 0

    /// How many transitions have happened — used by tests to confirm a long stall does not
    /// stampede through states.
    public private(set) var transitionCount: Int = 0

    private let profiles: [PetState: StateProfile]
    private var rng: SplitMix64

    public init(seed: UInt64,
                initial: PetState = .walk,
                profiles: [PetState: StateProfile] = BehaviorMachine.defaultProfiles) {
        self.state = initial
        self.profiles = profiles
        self.rng = SplitMix64(seed: seed)
        self.currentDwell = Self.pickDwell(for: initial, profiles: profiles, rng: &rng)
    }

    /// Advance the clock and return the state that is now current.
    @discardableResult
    public mutating func advance(by dt: TimeInterval) -> PetState {
        guard dt > 0 else { return state }

        timeInState += min(dt, Self.maximumStep)

        // A loop rather than an `if`: a single step can outlast a short dwell.
        while timeInState >= currentDwell {
            timeInState -= currentDwell
            transition()
        }
        return state
    }

    /// Time left before the next change, for logging.
    public var remainingDwell: TimeInterval { max(0, currentDwell - timeInState) }

    /// Put the pet into a state now, whatever it had planned.
    ///
    /// [M10] Clicking "Take a nap" is the only caller. It rolls a fresh dwell rather than
    /// pinning the state, so the pet wakes up on its own afterwards and the click is a
    /// nudge rather than a mode the user has to click their way back out of.
    ///
    /// Forcing the state the pet is already in is a no-op: it does not restart the dwell,
    /// and it does not count as a transition, because nothing about the pet changed.
    public mutating func force(_ newState: PetState) {
        guard newState != state else { return }
        state = newState
        timeInState = 0
        currentDwell = Self.pickDwell(for: newState, profiles: profiles, rng: &rng)
        transitionCount += 1
    }

    private mutating func transition() {
        state = Self.pickNext(from: state, profiles: profiles, rng: &rng)
        currentDwell = Self.pickDwell(for: state, profiles: profiles, rng: &rng)
        transitionCount += 1
    }

    private static func pickDwell(for state: PetState,
                                  profiles: [PetState: StateProfile],
                                  rng: inout SplitMix64) -> TimeInterval {
        guard let profile = profiles[state] else { return 1 }
        let low = max(0.1, min(profile.minDwell, profile.maxDwell))
        let high = max(low, profile.maxDwell)
        guard high > low else { return low }
        return TimeInterval.random(in: low...high, using: &rng)
    }

    private static func pickNext(from state: PetState,
                                 profiles: [PetState: StateProfile],
                                 rng: inout SplitMix64) -> PetState {
        // Only transitions with positive weight are eligible, and a profile never lists
        // its own state, so the pet always actually changes what it is doing.
        guard let profile = profiles[state] else { return state }
        let eligible = profile.transitions.filter { $0.weight > 0 && $0.state != state }
        guard !eligible.isEmpty else { return state }

        let total = eligible.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return eligible[0].state }

        var roll = Double.random(in: 0..<total, using: &rng)
        for transition in eligible {
            roll -= transition.weight
            if roll < 0 { return transition.state }
        }
        return eligible[eligible.count - 1].state
    }
}

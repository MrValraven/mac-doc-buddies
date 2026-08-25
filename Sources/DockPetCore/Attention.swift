//
//  Attention.swift: [M13] the cats notice the cursor.
//
//  SPEC §5: no AppKit. The whole feature is here, and the AppKit half (`CursorWatcher`) is
//  a throttled `NSEvent` monitor that reports a point and decides nothing. That split is
//  deliberate and it is the only reason a feature about a pointer can be tested at all,
//  because a test can move this cursor and a test cannot move the real one.
//
//  SPEC §9: elapsed time is a parameter, exactly as `MeetingCoordinator.advance(by:)` takes
//  it. Nothing in this file reads a clock, so an eight second cooldown and a four second
//  attention span can both be run to completion in microseconds.
//
//  **What this deliberately does not do: follow the cursor.** The cats turn and watch, and
//  that is the whole behaviour. `oneko` (SPEC §10) chases, and chasing is wrong here for two
//  separate reasons. It turns a background decoration into something that moves under the
//  user's hand while they are trying to work, which is the thing that gets a desktop pet
//  uninstalled by lunchtime. And it would fight `Walker`, the meeting and the kiss for
//  control of the same cat's position, where turning and sitting only ever contend for the
//  cat's *pose*, which the behaviour machine already treats as interruptible. There is no
//  flag for following, and there should not be one: a switch would mean both behaviours have
//  to keep working forever.
//

import CoreGraphics
import Foundation

/// Decides which cat, if any, is watching the pointer, which way it is facing, and whether
/// it has settled down to sit.
///
/// Driven from the app's 12 fps animation tick, like everything else that has a clock:
/// `noteCursor(_:)` records where the pointer is (called from the mouse monitor), and
/// `advance(by:on:candidates:)` does all the deciding (called from the tick). Splitting it
/// that way is what keeps SPEC §6 satisfied: this type adds no timer of its own, and the
/// monitor does no work beyond storing a point.
///
/// The alternative considered and rejected was doing the decision inside the monitor
/// callback. It would react a few milliseconds sooner and it would run the whole pick,
/// hysteresis and pose calculation on every throttled mouse event forever, including all the
/// ones where the pointer is nowhere near the Dock. Deciding on the tick means the work
/// happens at most twelve times a second, and only while the tick is running at all.
public struct AttentionCoordinator {

    // MARK: - What comes out

    /// The two things a watching cat can be doing. Only two, because attention is not a
    /// state machine of its own: it borrows two of `PetState`'s poses and gives them back.
    public enum Pose: String, Equatable {
        /// Stood up, stopped, facing the pointer.
        case watch
        /// Settled. What the cat does once the pointer has been there a moment.
        case sit
    }

    /// One cat is paying attention, and this is everything the caller needs to render it.
    public struct Focus: Equatable {
        /// The `index` of the winning `Candidate`, which is `Pet.index` when the caller
        /// builds its candidates from its own array (and any other identifier if it does
        /// not: this type never dereferences it).
        public let petIndex: Int

        /// Which way to face. `Walker.Direction` rather than a fresh left/right enum,
        /// because the app already owns exactly one line that turns a direction into a
        /// mirrored sprite (`facing = direction == .forward ? .right : .left`) and a second
        /// vocabulary for the same idea is a second place for it to be got backwards.
        public let facing: Walker.Direction

        public let pose: Pose

        public init(petIndex: Int, facing: Walker.Direction, pose: Pose) {
            self.petIndex = petIndex
            self.facing = facing
            self.pose = pose
        }

        /// The pose as a behaviour state, for a caller that drives the pet through
        /// `BehaviorMachine.force(_:)`.
        ///
        /// `watch` is `.idle` rather than `.walk` because idle is stationary, so the
        /// existing "only walking moves the pet" rule stops the cat with no second switch
        /// for it. This is the same trick `PetInteraction.say(_:)` uses to hold a cat still
        /// while it talks.
        public var petState: PetState { pose == .sit ? .sit : .idle }
    }

    // MARK: - What goes in

    /// One cat, as far as attention is concerned: where it is, and whether it is free.
    ///
    /// `isAvailable` is the whole "this feature must be able to lose" mechanism, and it is a
    /// value passed in per tick rather than a flag this type stores. A cat that is kissing,
    /// talking, being petted or under any future routine is simply not offered, so a
    /// priority mechanism that grows a fifth reason tomorrow does not have to come back here
    /// and add a fifth `isKissing`-shaped property. It defaults to `true` so a caller that
    /// has not yet wired its priorities up gets working attention rather than silence.
    public struct Candidate: Equatable {
        public let index: Int

        /// The pet's window frame in the same space as the cursor and the strip, which for
        /// this app is AppKit screen coordinates, y upward.
        public let frame: CGRect

        public let isAvailable: Bool

        public init(index: Int, frame: CGRect, isAvailable: Bool = true) {
            self.index = index
            self.frame = frame
            self.isAvailable = isAvailable
        }
    }

    // MARK: - Timings

    /// How far from the Dock's inner edge a pointer is close enough to be noticed, in
    /// points, measured both outward (up, over a bottom Dock) and inward (down, over the
    /// tiles themselves).
    ///
    /// 120 pt is roughly two Dock heights at the measured insets in `PROBE.md` (80 pt at
    /// tilesize 54, 125 pt at tilesize 128). Smaller and the cat only reacts once the
    /// pointer is already on top of it, which reads as a lag rather than as noticing.
    /// Larger and a pointer merely passing across the lower third of the screen sets cats
    /// off, which is the same failure the cooldown exists to prevent, arriving from a
    /// direction the cooldown cannot see.
    public static let noticeReach: CGFloat = 120

    /// Extra slack the pointer must clear before attention is *dropped*, on top of
    /// `noticeReach`.
    ///
    /// This is half the hysteresis story (see the type's Hysteresis note). A pointer resting
    /// on the boundary itself is otherwise in and out of the zone on alternate samples, and
    /// a cat that stands up and sits down twenty times a second is worse than no feature.
    public static let releaseMargin: CGFloat = 30

    /// How long the pointer must stay in the zone before any cat reacts.
    ///
    /// This is what makes a fast sweep across the Dock cost nothing. At 12 fps a quarter of
    /// a second is three ticks, so a pointer merely crossing the strip on its way somewhere
    /// is gone before the third one. It is short enough that a pointer that has actually
    /// arrived is noticed within a frame or two of stopping.
    public static let noticeDelay: TimeInterval = 0.25

    /// How long the cat watches, stood up, before it settles.
    ///
    /// One second. The beat is the point: "stop, look, then sit" reads as an animal deciding
    /// the pointer is not going anywhere. Sitting immediately reads as a state change, and
    /// three seconds is long enough that most pointers have left before it lands.
    public static let sitDelay: TimeInterval = 1.0

    /// How long attention survives after the pointer stops moving.
    ///
    /// The mouse monitor only fires on movement, so silence genuinely is the pointer having
    /// stopped, and this is the timeout on that silence. Four seconds is long enough that
    /// pausing to look at the cat does not dismiss it, and short enough that a pointer
    /// abandoned near the Dock while the user reads something gives the cat its afternoon
    /// back.
    public static let attentionSpan: TimeInterval = 4.0

    /// The longest a single episode may run, however busy the pointer stays.
    ///
    /// `attentionSpan` only ends an episode once the pointer goes *still*. A user whose
    /// mouse simply lives near the Dock, nudged constantly, would otherwise hold one cat
    /// frozen in a sit for the whole afternoon: a cat that never walks again is a broken app
    /// that looks like a working one. Twelve seconds is long enough that no ordinary visit
    /// to the Dock hits it, so in practice this ceiling only fires on the pathological case
    /// it was written for.
    public static let maximumEpisode: TimeInterval = 12

    /// How long after an episode ends before another may start.
    ///
    /// The rate limit on the whole feature. Without it, a pointer travelling to and from the
    /// Dock a few times a minute (which is what a Dock is for) produces a cat that is
    /// permanently sitting down and standing up. Eight seconds is longer than the round trip
    /// to click a Dock icon and come back, so a single errand costs one reaction rather than
    /// three.
    public static let cooldown: TimeInterval = 8

    /// How much nearer a rival cat must be, in points, before attention moves to it.
    ///
    /// The other half of the hysteresis story. 24 pt is roughly a third of a 64 pt cat at
    /// 2x scale: comfortably more than the jitter of a hand resting on a mouse, comfortably
    /// less than the width of the cat the pointer would have to walk over to earn the swap.
    public static let switchMargin: CGFloat = 24

    /// How far past the watching cat's own centre the pointer must be before the sprite
    /// mirrors, in points.
    ///
    /// A third hysteresis case, and the easiest one to miss: the facing test is a comparison
    /// against a single coordinate, so a pointer resting on the cat's centre flips the
    /// sprite on every sample even when the choice of cat is perfectly stable. 12 pt is
    /// about a sixth of the cat's width, so the dead zone is invisible while the pointer is
    /// moving and decisive while it is not.
    public static let facingDeadZone: CGFloat = 12

    /// Movement below this, in points, is not movement.
    ///
    /// Guards two things at once: a mouse that reports the same location twice, and the
    /// sub-pixel tremor of a hand at rest, which would otherwise keep `attentionSpan` from
    /// ever expiring. Sub-threshold reports are dropped rather than accumulated, so a slow
    /// genuine drift still registers once it has covered 2 pt.
    public static let minimumMovement: CGFloat = 2

    /// How often `CursorWatcher` is allowed to report, in seconds.
    ///
    /// Lives here rather than in the AppKit shell because it is policy, and the shell holds
    /// none. 20 Hz against a 12 fps tick means every tick sees at least one report from a
    /// moving pointer, while an untinted `.mouseMoved` stream (which can exceed 200 Hz on a
    /// high-polling-rate mouse) is thrown away before it reaches any decision.
    public static let reportInterval: TimeInterval = 0.05

    // MARK: - State

    /// One live episode of a cat watching the pointer.
    private struct Episode {
        var petIndex: Int
        var facing: Walker.Direction
        /// Since this cat took over, not since the episode began: a handover restarts it, so
        /// the cat receiving attention gets its own watch-then-sit beat.
        var elapsed: TimeInterval = 0
        /// Since the pointer last moved.
        var still: TimeInterval = 0
    }

    private var cursor: CGPoint?
    private var cursorMoved = false

    /// Whether the pointer has *arrived* rather than merely being present.
    ///
    /// Set by a movement report inside the notice zone, cleared when the pointer leaves it
    /// and when an episode ends. Without this the dwell clock would run for a pointer parked
    /// near the Dock since before launch, and the cat would be pulled back into a sit every
    /// time the cooldown lapsed: a pointer nobody has touched in an hour would pulse a cat
    /// every twenty seconds, forever.
    private var armed = false

    private var dwellInZone: TimeInterval = 0

    /// Starts at the cooldown, so the first pointer of a session is not swallowed. Same
    /// reasoning as `MeetingCoordinator`: cats that ignore you for the first eight seconds
    /// after launch look broken.
    private var sinceEpisodeEnd: TimeInterval = AttentionCoordinator.cooldown

    private var episode: Episode?

    /// The last answer `advance` gave, so a caller that ticks in one place and renders in
    /// another does not have to stash it.
    public private(set) var focus: Focus?

    public init() {}

    /// True while a cat is actually watching.
    ///
    /// Offered for the caller's SPEC §6 suspend predicate: the animation timer stops when
    /// every pet is stationary, and a watching cat *is* stationary, so without this the tick
    /// that owns this coordinator's clock would suspend mid-episode and the cat would be
    /// left sitting and staring until something else woke it.
    public var isEngaged: Bool { episode != nil }

    // MARK: - Input

    /// Record where the pointer is. Called from the mouse monitor, and only on movement.
    ///
    /// Deliberately takes no time and returns no decision: everything that could be wrong
    /// about attention should be wrong in `advance`, where a test can drive it.
    public mutating func noteCursor(_ point: CGPoint) {
        guard let previous = cursor else {
            cursor = point
            cursorMoved = true
            return
        }
        let dx = point.x - previous.x
        let dy = point.y - previous.y
        guard (dx * dx + dy * dy).squareRoot() >= Self.minimumMovement else { return }
        cursor = point
        cursorMoved = true
    }

    // MARK: - The decision

    /// Advance the clocks and say who, if anyone, is watching the pointer.
    ///
    /// `strip` is optional so the caller may call unconditionally: a Dock that has gone away
    /// (autohidden, fullscreen, the Tahoe post-screensaver bug in SPEC §8) ends attention
    /// rather than freezing it, which is the same answer the rest of the app gives.
    ///
    /// `candidates` is rebuilt per tick from live frames, for the reason SPEC §7 M3 gives
    /// for the strip itself: the Dock can move, resize or change screens between two ticks,
    /// and a cached frame decides "which cat is nearest" using a position the cat left.
    @discardableResult
    public mutating func advance(by dt: TimeInterval,
                                 on strip: WalkStrip?,
                                 candidates: [Candidate]) -> Focus? {
        // Bounded for the same reason `Walker`, `BehaviorMachine` and `MeetingCoordinator`
        // bound theirs: a stalled process (display sleep, menu tracking, a suspended app)
        // hands back a huge elapsed time on the next fire. Unbounded, one such tick would
        // expire the attention span, run out the episode ceiling and clear the cooldown all
        // at once, so the user would come back from lunch to a cat that had silently
        // finished reacting to a pointer that had not moved.
        let step = min(max(0, dt), BehaviorMachine.maximumStep)

        let moved = cursorMoved
        cursorMoved = false

        // Saturating rather than merely accumulating: this counter is only ever compared
        // against `cooldown`, and an app that runs all day (SPEC §6) would otherwise spend
        // the afternoon adding thousandths to a number in the tens of thousands, where the
        // additions stop landing.
        sinceEpisodeEnd = min(sinceEpisodeEnd + step, Self.cooldown)

        guard let strip = strip, let cursor = cursor else { return stop() }

        // Hysteresis, first of three. Getting in is judged against the notice zone; staying
        // in is judged against a strictly larger one, so a pointer sitting on the boundary
        // cannot be alternately in and out.
        let reach = episode == nil ? Self.noticeReach : Self.noticeReach + Self.releaseMargin
        guard Self.zone(for: strip, reach: reach).contains(cursor) else { return stop() }

        if var live = episode {
            live.elapsed += step
            live.still = moved ? 0 : live.still + step

            guard live.still < Self.attentionSpan, live.elapsed < Self.maximumEpisode else {
                return stop()
            }

            // The cat this episode is about has been claimed by something with a better
            // claim (a click, a kiss, a nap). Attention is dropped rather than handed to
            // whichever cat is next nearest: the pointer has not moved, so a second cat
            // across the Dock suddenly turning to look at it would read as a bug rather than
            // as a reaction. Dropping it here spends the cooldown too, which is what stops
            // the same cat re-noticing the pointer the instant it finishes its sentence.
            guard candidates.contains(where: { $0.index == live.petIndex && $0.isAvailable }),
                  let target = Self.nearest(to: cursor, on: strip, among: candidates,
                                            incumbent: live.petIndex) else {
                return stop()
            }

            // A handover inside one episode is legitimate and is not flicker: it is what
            // happens when the pointer genuinely travels from one cat to the other, and
            // `nearest` will only allow it once the rival is `switchMargin` nearer.
            let handedOver = target.index != live.petIndex
            if handedOver { live.elapsed = 0 }

            live.facing = Self.facing(cursor: cursor, target: target.frame, on: strip,
                                      current: handedOver ? nil : live.facing)
            live.petIndex = target.index
            episode = live

            return publish(Focus(petIndex: live.petIndex, facing: live.facing,
                                 pose: live.elapsed >= Self.sitDelay ? .sit : .watch))
        }

        // No episode: decide whether one starts.
        if moved { armed = true }
        guard armed else { focus = nil; return nil }

        dwellInZone += step
        guard dwellInZone >= Self.noticeDelay, sinceEpisodeEnd >= Self.cooldown else {
            focus = nil
            return nil
        }

        // Everyone is busy. Nothing happens, and crucially no cooldown is spent on an
        // episode that never existed, so the dwell survives and whichever cat comes free
        // first picks the pointer up without a wait the user would read as the feature
        // being broken.
        guard let target = Self.nearest(to: cursor, on: strip, among: candidates,
                                        incumbent: nil) else {
            focus = nil
            return nil
        }

        let facing = Self.facing(cursor: cursor, target: target.frame, on: strip, current: nil)
        episode = Episode(petIndex: target.index, facing: facing)
        dwellInZone = 0

        return publish(Focus(petIndex: target.index, facing: facing, pose: .watch))
    }

    private mutating func publish(_ next: Focus) -> Focus {
        focus = next
        return next
    }

    /// End whatever was happening and reset every clock but the cooldown, which starts.
    ///
    /// The cooldown is spent only if there was an episode to end. A pointer that wanders
    /// past the Dock without ever getting a cat's attention has not used anything up.
    @discardableResult
    private mutating func stop() -> Focus? {
        if episode != nil { sinceEpisodeEnd = 0 }
        episode = nil
        armed = false
        dwellInZone = 0
        focus = nil
        return nil
    }

    // MARK: - Geometry

    /// The rectangle around the strip within which a pointer counts as near the Dock.
    ///
    /// The strip is a line (a baseline plus a span), so this is that line inflated by
    /// `reach` in every direction: outward from the Dock, inward over the tiles, and past
    /// each end so a cat parked at the end of the strip can still see a pointer just beyond
    /// it. One formula for all three Dock edges, with `edge` deciding only which axis is
    /// which, because SPEC §8 trap 1 is that coordinate rules written twice are written
    /// differently.
    public static func zone(for strip: WalkStrip, reach: CGFloat) -> CGRect {
        let r = max(0, reach)
        let span = max(0, strip.length)
        switch strip.axis {
        case .horizontal:
            return CGRect(x: strip.start - r, y: strip.baseline - r,
                          width: span + 2 * r, height: 2 * r)
        case .vertical:
            return CGRect(x: strip.baseline - r, y: strip.start - r,
                          width: 2 * r, height: span + 2 * r)
        }
    }

    /// Is this pointer close enough to the Dock to be worth ticking for?
    ///
    /// The caller's wake-up hook, and the reason it exists: SPEC §6 suspends the animation
    /// timer when every pet is stationary, and this coordinator's clock rides on that timer.
    /// A pointer arriving while every cat sits still would otherwise never be advanced into
    /// an episode at all. Asked from the mouse monitor's callback, this answers "resume the
    /// tick" without the monitor knowing anything about attention.
    ///
    /// Judged against the release zone, not the notice zone, so a cat already watching from
    /// inside the release margin keeps getting the ticks that end its episode cleanly.
    public static func isNear(_ point: CGPoint, strip: WalkStrip) -> Bool {
        zone(for: strip, reach: noticeReach + releaseMargin).contains(point)
    }

    /// The pointer's coordinate along the strip's free axis.
    public static func freeCoordinate(of point: CGPoint, on strip: WalkStrip) -> CGFloat {
        strip.axis == .horizontal ? point.x : point.y
    }

    /// A pet's centre along the strip's free axis.
    ///
    /// The centre rather than the near edge of the frame, so "which cat is nearest" does not
    /// change its answer when the two cats have different sprite widths.
    public static func center(of frame: CGRect, on strip: WalkStrip) -> CGFloat {
        strip.axis == .horizontal ? frame.midX : frame.midY
    }

    /// Which way a cat at `frame` should face to look at `cursor`.
    ///
    /// `current` is the facing it already has, or `nil` when there is none yet (a fresh
    /// episode, or attention that has just moved to a different cat). With a current facing
    /// the answer sticks until the pointer is `facingDeadZone` clear of the cat's centre on
    /// the other side; without one it is the plain comparison, with a pointer exactly on the
    /// centre resolving forward so the answer is deterministic rather than merely arbitrary.
    public static func facing(cursor: CGPoint, target frame: CGRect, on strip: WalkStrip,
                              current: Walker.Direction?) -> Walker.Direction {
        let pointer = freeCoordinate(of: cursor, on: strip)
        let middle = center(of: frame, on: strip)

        guard let current = current else { return pointer >= middle ? .forward : .backward }

        switch current {
        case .forward:  return pointer < middle - facingDeadZone ? .backward : .forward
        case .backward: return pointer > middle + facingDeadZone ? .forward : .backward
        }
    }

    /// The available cat nearest the pointer along the strip, with the incumbent sticky.
    ///
    /// Hysteresis, the second of three, and the one the feature would be unusable without: a
    /// pointer resting exactly between two cats is nearer to each of them in turn as a hand
    /// nudges the mouse a pixel at a time, so an honest "nearest" answer alternates on every
    /// sample and both cats sit down and stand up together, several times a second.
    ///
    /// A dead zone alone (ignore movements under n points) was considered and is not enough:
    /// it suppresses jitter but not a pointer that genuinely crosses the midpoint slowly, so
    /// the flicker returns at whatever speed defeats the threshold. Stickiness fixes the
    /// case at its cause instead. The incumbent keeps attention unless a rival is
    /// `switchMargin` *nearer*, which makes the boundary between the two cats two boundaries
    /// separated by 48 pt, one for each direction of travel.
    ///
    /// With no incumbent the answer is the plain nearest, ties going to the earlier
    /// candidate so that a caller passing its pets in array order gets the lower index
    /// rather than an answer that depends on how the tie fell out.
    public static func nearest(to cursor: CGPoint, on strip: WalkStrip,
                               among candidates: [Candidate],
                               incumbent: Int?) -> Candidate? {
        let pointer = freeCoordinate(of: cursor, on: strip)

        var best: Candidate?
        var bestGap = CGFloat.greatestFiniteMagnitude
        for candidate in candidates where candidate.isAvailable {
            let gap = abs(pointer - center(of: candidate.frame, on: strip))
            if gap < bestGap {
                best = candidate
                bestGap = gap
            }
        }
        guard let best = best else { return nil }

        if let incumbent = incumbent,
           let held = candidates.first(where: { $0.index == incumbent && $0.isAvailable }) {
            let heldGap = abs(pointer - center(of: held.frame, on: strip))
            // Keep the incumbent unless the rival is decisively nearer. Written as "keep"
            // rather than "switch" so the equality case lands on staying put, which is the
            // whole point.
            if bestGap + switchMargin >= heldGap { return held }
        }

        return best
    }
}

//
//  CuddleDirector.swift: [M14] driving the cuddle nap, the third thing that takes both cats
//  away from their own behaviour machines.
//
//  A file of its own beside SceneDirector, for the reason given there: AppDelegate is
//  nineteen hundred lines and shrinking it was a stated goal of M11c. Only the stored state
//  lives over there, because a Swift extension cannot hold any. CuddleRoutine in
//  DockPetCore owns the order and the clock; this owns the cats, the sheets and the bubbles.
//
//  It is the kiss's shape, and deliberately: settle left and right once, steer only during
//  the approach, hang the one-shot work off the phase change, and have exactly one release
//  path so no bubble can be left over a cat that has walked away.
//
//  The one thing it does that neither of its siblings does is put the pair to sleep for
//  eight seconds, and that is where its two extra rules come from. The behaviour clock is
//  held while the nap runs, or the machine would decide to stand up half way through it,
//  and a hand reaching for either cat ends the nap rather than being ignored.
//

import AppKit
import DockPetCore

/// The nap in progress: the routine, the pair it belongs to, and the three lines.
struct CuddleInProgress {
    var routine = CuddleRoutine()
    let left: Pet
    let right: Pet

    /// Chosen when the nap begins rather than at the moment each is said.
    ///
    /// Fixed up front for the same reason `left` and `right` are, and the same reason the
    /// birthday scene fixes its two: a line drawn mid-nap would be drawn from a generator
    /// that has moved on, so the log printed when the nap starts could not say what the
    /// cats are about to say.
    let opener: String
    let reply: String
    let waking: String
}

extension AppDelegate {

    // MARK: - Starting

    /// Send both cats to each other and start the routine.
    ///
    /// `reason` is for the log and nothing else, on a sequence nobody reading this can
    /// watch (SPEC §9). "they met" and "asked for it" are the two.
    func beginCuddle(_ a: Pet, _ b: Pet, reason: String) {
        guard cuddle == nil, kiss == nil, scene == nil, pets.count == 2 else { return }

        // Settled here, once. During the approach the two cross and re-cross; reading "who
        // is on the left" per frame would move a line from one cat to the other mid-nap.
        let aIsLeft = a.window.frame.minX <= b.window.frame.minX
        let left = aIsLeft ? a : b
        let right = aIsLeft ? b : a

        guard occupancy.claim(.cuddle, pets: [left.index, right.index]) else {
            print("[cuddle] not started: something else has the cats")
            return
        }

        let pairs = Phrasebook.cuddlePairs
        let wakingLines = Phrasebook.cuddleWakingLines
        guard !pairs.isEmpty, !wakingLines.isEmpty else {
            occupancy.release(.cuddle, pets: [left.index, right.index])
            return
        }
        let pair = pairs[Int.random(in: 0..<pairs.count, using: &cuddleRng)]
        let waking = wakingLines[Int.random(in: 0..<wakingLines.count, using: &cuddleRng)]

        cuddle = CuddleInProgress(left: left, right: right,
                                  opener: pair.opener, reply: pair.reply, waking: waking)

        // A cat mid-sentence stops talking rather than walking off with its bubble in tow.
        for pet in [left, right] {
            pet.interaction.dismissBubble()
            pet.behavior.force(.walk)
            pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
        }

        print("[cuddle] pet \(left.index) and pet \(right.index) set off, \(reason)")
        print("[cuddle] they will say: \"\(pair.opener)\" \"\(pair.reply)\" \"\(waking)\"")
        logLocation("pet \(left.index) and pet \(right.index) walk toward each other to nap")
        updateAnimationState()
    }

    // MARK: - Per frame

    /// Whether this pet is being walked by the nap rather than by its own walker.
    ///
    /// True only during the approach, exactly as it is for the kiss and the scene: once
    /// they are together the pair sits, and the walk away at the end is an ordinary walk in
    /// a reversed direction.
    func isSteeredByCuddle(_ pet: Pet) -> Bool {
        guard let cuddle, cuddle.routine.phase == .approach else { return false }
        return pet === cuddle.left || pet === cuddle.right
    }

    /// Whether the nap is holding this cat at all, in any phase.
    ///
    /// Used for the behaviour clock rather than for movement, which is why it is not
    /// `isSteeredByCuddle`: the pair is asleep for eight seconds, and its own machine would
    /// otherwise spend that time deciding to get up, walk, and wander off out of a nap the
    /// routine still believes it is running.
    func cuddleHolds(_ pet: Pet) -> Bool {
        guard let cuddle else { return false }
        return pet === cuddle.left || pet === cuddle.right
    }

    /// One frame: steer the pair, then act on any phase it just entered.
    func advanceCuddle(by dt: TimeInterval, on strip: WalkStrip) {
        guard var current = cuddle else { return }

        // Settings can rebuild the cast at any moment, and a nap holding two cats that are
        // no longer on screen would never end.
        guard pets.contains(where: { $0 === current.left }),
              pets.contains(where: { $0 === current.right }) else {
            print("[cuddle] abandoned: the cast changed mid-nap")
            endCuddle()
            return
        }

        let left = current.left, right = current.right

        if MeetingCoordinator.haveMet(left.window.frame, right.window.frame) {
            current.routine.arrive()
        }
        let (previous, phase) = current.routine.advance(by: dt)
        cuddle = current

        if phase != previous { enterCuddlePhase(phase) }

        // Per-frame work, after the transition so a phase entered this frame gets its own
        // first frame rather than the outgoing phase's.
        if cuddle?.routine.phase == .approach {
            // Both walk to the point between them, at their own speed. Not the kiss's run:
            // two cats on their way to a nap are in no hurry, and the difference in pace is
            // most of what tells the two sequences apart from across the room.
            //
            // Recomputed every frame rather than fixed at the start: the strip can move or
            // shrink under them, and a target from four seconds ago can be somewhere
            // neither cat can stand.
            let midpoint = (left.walker.distance + right.walker.distance) / 2
            for pet in [left, right] {
                pet.walker.walk(toward: midpoint, by: dt,
                                maxDistance: Geometry.maximumDistance(for: pet.size, on: strip))
            }
            // Facing is taken from the pair rather than from each walker, so a cat that has
            // arrived and stopped does not turn its back on the frame it gets there.
            left.view.facing = .right
            right.view.facing = .left
        }
    }

    /// The one-shot work hanging off each phase.
    private func enterCuddlePhase(_ phase: CuddleRoutine.Phase) {
        guard let current = cuddle else { return }
        let left = current.left, right = current.right

        switch phase {
        case .approach:
            break   // where every nap starts; nothing to enter

        case .settle:
            for pet in [left, right] {
                pet.behavior.force(.sit)
                pet.applyBehaviorState(.sit, spriteSet: sprites(for: pet))
            }
            left.view.facing = .right
            right.view.facing = .left
            logLocation("pet \(left.index) and pet \(right.index) settle down together")

        case .snuggle:
            print("[cuddle] pet \(left.index) → \"\(current.opener)\"")
            left.interaction.showBubble(current.opener)

        case .reply:
            // The first line comes down before the answer goes up. Two cats lying against
            // each other stand well inside one bubble's width, so leaving it up means two
            // opaque rectangles overlapping: the same rule the meeting and the kiss follow.
            left.interaction.dismissBubble()
            print("[cuddle] pet \(right.index) → \"\(current.reply)\"")
            right.interaction.showBubble(current.reply)

        case .sleep:
            right.interaction.dismissBubble()
            for pet in [left, right] {
                pet.behavior.force(.sleep)
                pet.applyBehaviorState(.sleep, spriteSet: sprites(for: pet))
            }
            print("[cuddle] pet \(left.index) and pet \(right.index) fall asleep together")

        case .wake:
            // Sitting up first: the line belongs to a cat that has woken, and a bubble over
            // the sleep pose reads as a cat talking in its sleep.
            for pet in [left, right] {
                pet.behavior.force(.sit)
                pet.applyBehaviorState(.sit, spriteSet: sprites(for: pet))
            }
            print("[cuddle] pet \(left.index) → \"\(current.waking)\"")
            left.interaction.showBubble(current.waking)

        case .part:
            left.interaction.dismissBubble()
            for pet in [left, right] {
                pet.walker.reverse()
                pet.behavior.force(.walk)
                pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
                pet.view.facing = pet.walker.direction == .forward ? .right : .left
            }
            print("[cuddle] pet \(left.index) and pet \(right.index) walk away")
            updateAnimationState()

        case .done:
            if current.routine.wasAbandoned {
                print("[cuddle] abandoned: the two never reached each other")
                for pet in [left, right] {
                    pet.behavior.force(.walk)
                    pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
                }
            }
            endCuddle()
        }
    }

    // MARK: - Ending

    /// Let the nap go and put the timer right. The ordinary ending, and the teardown path.
    func endCuddle() {
        guard cuddle != nil else { return }
        releaseCuddle()
        updateAnimationState()
    }

    /// Cut a nap short because the user has reached for one of the cats.
    ///
    /// The pair is put back on its feet rather than left in whatever pose the phase had it
    /// in: a nap that ends with the human's cat sitting up and the other one still lying
    /// flat on the Dock reads as the app having lost track of one of them.
    func interruptCuddle(reason: String) {
        guard let current = cuddle else { return }
        print("[cuddle] cut short: \(reason)")
        for pet in [current.left, current.right] {
            pet.behavior.force(.walk)
            pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
        }
        endCuddle()
    }

    /// Drop the nap without touching the timer.
    ///
    /// Separate from `endCuddle` for one caller, `updateAnimationState`, which is already
    /// deciding about the timer when it finds a nap it has to let go. Exactly the split the
    /// kiss and the scene use, and for the same re-entrancy reason.
    func releaseCuddle() {
        guard let current = cuddle else { return }
        // A nap let go mid-sentence must not leave a line hanging over a cat that is about
        // to walk off under it.
        for pet in [current.left, current.right] { pet.interaction.dismissBubble() }
        occupancy.release(.cuddle, pets: [current.left.index, current.right.index])
        cuddle = nil

        // The pair has just spent twenty seconds against each other. Without this they
        // would strike up a conversation the instant they part, which reads as two features
        // fighting over the same cats rather than as one pair of them. It is also the only
        // stamp a nap asked for from the menu ever gets.
        meetings.noteMeeting()
    }

    /// For `--cuddle-test`, which has to follow a sequence it cannot watch (SPEC §9).
    var cuddlePhase: CuddleRoutine.Phase? { cuddle?.routine.phase }
}

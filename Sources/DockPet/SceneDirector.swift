//
//  SceneDirector.swift: [M13] driving the birthday scene, which is the one thing in this
//  app that happens without her touching anything.
//
//  A file of its own rather than another two hundred lines of AppDelegate, which is 1900
//  lines and whose shrinking was a stated goal of M11c. Only the stored state lives over
//  there, because a Swift extension cannot hold any; everything that decides or draws is
//  here, and BirthdayScene in DockPetCore already owns the part that can be tested.
//
//  It is deliberately the kiss's shape. The kiss is the only other sequence that takes
//  both cats away from their behaviour machines, and it worked out the hard parts already:
//  settle left and right once, steer only during the approach, hang one-shot work off the
//  phase change, and have exactly one release path so no window can be left on screen.
//

import AppKit
import DockPetCore

/// The scene in progress: the routine, the pair it belongs to, and whatever is on screen.
struct SceneInProgress {
    var routine = BirthdayScene()
    let left: Pet
    let right: Pet
    var hearts: HeartsWindow?
    var confetti: ConfettiWindow?

    /// The two lines, chosen when the scene begins rather than at the moment each is said.
    ///
    /// Fixed up front for the same reason `left` and `right` are: a line picked mid-scene
    /// would be picked from a phrasebook seeded by a clock that has moved on, so the log
    /// line printed when the scene starts could not name what she is about to be told.
    let announcement: String
    let wish: String

    /// Whether `wish` is the configured dedication, which decides whether saying it should
    /// also spend the day's dedication.
    let wishIsDedication: Bool
}

extension AppDelegate {

    // MARK: - Starting

    /// Is today the day, and has the scene not already had its turn?
    ///
    /// Called from the 500 ms poll rather than at launch, because at launch there may be no
    /// Dock yet: she may open the lid at nine, and the app has been running since Tuesday.
    /// The gate is a day stamp on disk, so a machine that was asleep at midnight still gets
    /// the scene the first time it sees the Dock on the day.
    func considerBirthdayScene() {
        guard pets.count == 2, kiss == nil, scene == nil else { return }
        // A self-test must never spend the scene. It happens once a year, and burning it
        // on a --render-test would be indistinguishable from the feature never working.
        guard !options.isSelfTest || options.sceneTest else { return }

        let now = Date()
        let today = Occasion.dayStamp(now)
        let isBirthday = options.sceneTest
            || Occasion.isBirthday(now, birthday: config.birthday)
        // --scene-test lifts the once-a-day gate as well as the date, so it can be run
        // twice in a row while working on it. It never touches the real stamp; see below.
        guard options.sceneTest
            || BirthdayScene.shouldRun(isBirthday: isBirthday,
                                       lastRunDay: StateStore.lastSceneDay,
                                       today: today) else { return }

        beginBirthdayScene(reason: options.sceneTest ? "asked for it" : "it is her birthday")

        // Stamped here, at the start, not at the end. A scene abandoned half way has still
        // had its turn; retrying it every 500 ms for the rest of the day would be worse
        // than missing it once. The test mode is excluded so rehearsing it in August does
        // not silence the real one two days later.
        if !options.sceneTest { StateStore.lastSceneDay = today }
    }

    /// Send both cats to each other and start the routine.
    func beginBirthdayScene(reason: String) {
        guard scene == nil, pets.count == 2 else { return }

        let a = pets[0], b = pets[1]
        // Settled once, as the kiss settles it: during the approach the two cross and
        // re-cross, and reading "who is on the left" per frame would move the birthday line
        // from one cat to the other half way through it.
        let aIsLeft = a.window.frame.minX <= b.window.frame.minX
        let left = aIsLeft ? a : b
        let right = aIsLeft ? b : a

        guard occupancy.claim(.scene, pets: [left.index, right.index]) else {
            print("[scene] not started: something else has the cats")
            return
        }

        let name = interactionUserName(for: left.interaction)
        let lines = Phrasebook.birthdayLines
        var rng = SplitMix64(seed: UInt64(abs(Occasion.dayStamp(Date()).hashValue % 100_000)))
        let announcement = Phrasebook.render(lines[Int.random(in: 0..<lines.count, using: &rng)],
                                             name: name)

        // The dedication is the line she actually wrote to be read, so the scene says it
        // rather than a second stock birthday line. Without one, a different line from the
        // same pool, drawn so it cannot repeat the announcement.
        let dedication = config.dedication
        let wish: String
        if let dedication, !dedication.trimmingCharacters(in: .whitespaces).isEmpty {
            wish = Phrasebook.render(dedication, name: name)
        } else {
            let others = lines.filter { Phrasebook.render($0, name: name) != announcement }
            let pool = others.isEmpty ? lines : others
            wish = Phrasebook.render(pool[Int.random(in: 0..<pool.count, using: &rng)], name: name)
        }

        scene = SceneInProgress(left: left, right: right,
                                announcement: announcement, wish: wish,
                                wishIsDedication: dedication != nil)

        for pet in [left, right] {
            pet.interaction.dismissBubble()
            pet.behavior.force(.walk)
            pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
        }

        print("[scene] pet \(left.index) and pet \(right.index) set off, \(reason)")
        print("[scene] she will be told: \"\(announcement)\" then \"\(wish)\"")
        updateAnimationState()
    }

    // MARK: - Per frame

    /// Whether this pet is being walked by the scene rather than by its own walker.
    ///
    /// True only during the approach, exactly as `isSteered` is for the kiss: once they are
    /// together the pair sits, and the walk away at the end is an ordinary walk in a
    /// reversed direction, which is what makes the parting look like the cats decided it.
    func isSteeredByScene(_ pet: Pet) -> Bool {
        guard let scene, scene.routine.phase == .approach else { return false }
        return pet === scene.left || pet === scene.right
    }

    /// One frame: steer the pair, then act on any phase it just entered.
    func advanceScene(by dt: TimeInterval, on strip: WalkStrip) {
        guard var current = scene else { return }

        // Settings can rebuild the cast at any moment. A scene holding two cats that are no
        // longer on screen would keep confetti falling over nothing and never end.
        guard pets.contains(where: { $0 === current.left }),
              pets.contains(where: { $0 === current.right }) else {
            print("[scene] abandoned: the cast changed mid-scene")
            endScene()
            return
        }

        let left = current.left, right = current.right

        if MeetingCoordinator.haveMet(left.window.frame, right.window.frame) {
            current.routine.arrive()
        }
        let (previous, phase) = current.routine.advance(by: dt)
        scene = current

        if phase != previous { enterScenePhase(phase, on: strip) }

        switch scene?.routine.phase {
        case .approach:
            // Recomputed every frame, never fixed at the start: the strip can move or
            // shrink under them, and a target from four seconds ago can be somewhere
            // neither cat can stand.
            let midpoint = (left.walker.distance + right.walker.distance) / 2
            for pet in [left, right] {
                pet.walker.walk(toward: midpoint, by: dt,
                                maxDistance: Geometry.maximumDistance(for: pet.size, on: strip))
            }
            // From the pair rather than from each walker, so a cat that has arrived and
            // stopped does not turn its back on the frame it gets there.
            left.view.facing = .right
            right.view.facing = .left
        case .celebrate:
            // The Dock can be resized mid-scene. Both windows belong over the pair, not
            // over the place the pair was standing when they went up.
            let pair = left.window.frame.union(right.window.frame)
            scene?.hearts?.reposition(over: pair)
            scene?.confetti?.reposition(over: pair)
        default:
            break
        }
    }

    /// The one-shot work hanging off each phase.
    private func enterScenePhase(_ phase: BirthdayScene.Phase, on strip: WalkStrip) {
        guard let current = scene else { return }
        let left = current.left, right = current.right

        switch phase {
        case .approach:
            break   // where every scene starts

        case .gather:
            for pet in [left, right] {
                pet.behavior.force(.sit)
                pet.applyBehaviorState(.sit, spriteSet: sprites(for: pet))
            }
            left.view.facing = .right
            right.view.facing = .left
            logLocation("pet \(left.index) and pet \(right.index) reach each other for the scene")

        case .announce:
            print("[scene] pet \(left.index) → \"\(current.announcement)\"")
            left.interaction.showBubble(current.announcement)

        case .celebrate:
            // The line comes down before anything goes up, for the reason the kiss takes
            // its bubble down first: two cats this close share the space a bubble needs.
            left.interaction.dismissBubble()
            let pair = left.window.frame.union(right.window.frame)

            let hearts = HeartsWindow(over: pair, scale: config.scale)
            scene?.hearts = hearts
            hearts.start { [weak self] in self?.scene?.hearts = nil }

            let confetti = ConfettiWindow(over: pair, scale: config.scale,
                                          seed: UInt64.random(in: UInt64.min...UInt64.max))
            scene?.confetti = confetti
            confetti.start { [weak self] in self?.scene?.confetti = nil }

            print("[scene] confetti and hearts up over pet \(left.index) and pet \(right.index)")

        case .wish:
            // Taken down here rather than left to their own timers: the lengths match, but
            // a stalled frame can leave a window up past its phase, and a bubble under
            // falling confetti is the glitch `.celebrate` took the last one down for.
            scene?.hearts?.dismiss()
            scene?.hearts = nil
            scene?.confetti?.dismiss()
            scene?.confetti = nil

            print("[scene] pet \(right.index) → \"\(current.wish)\"")
            right.interaction.showBubble(current.wish)

            // The scene has just said the dedication out loud, so the day's dedication is
            // spent. Without this the first click of the morning would repeat it, which
            // reads as the app having lost its place rather than as a second gift.
            if current.wishIsDedication, !options.sceneTest {
                StateStore.lastGreetedDay = Occasion.dayStamp(Date())
            }

        case .part:
            right.interaction.dismissBubble()
            for pet in [left, right] {
                pet.walker.reverse()
                pet.behavior.force(.walk)
                pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
                pet.view.facing = pet.walker.direction == .forward ? .right : .left
            }
            print("[scene] pet \(left.index) and pet \(right.index) walk away")
            updateAnimationState()

        case .done:
            if current.routine.wasAbandoned {
                print("[scene] abandoned: the two never reached each other")
                for pet in [left, right] {
                    pet.behavior.force(.walk)
                    pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
                }
            }
            endScene()
        }
    }

    // MARK: - Ending

    /// Let the scene go and put the timer right. The ordinary ending, and the teardown.
    func endScene() {
        guard scene != nil else { return }
        releaseScene()
        updateAnimationState()
    }

    /// Drop the scene without touching the timer.
    ///
    /// Separate from `endScene` for one caller, `updateAnimationState`, which is already
    /// deciding about the timer when it finds a scene it has to let go. Exactly the split
    /// the kiss uses, and for the same re-entrancy reason.
    func releaseScene() {
        guard let current = scene else { return }
        current.hearts?.dismiss()
        current.confetti?.dismiss()
        for pet in [current.left, current.right] { pet.interaction.dismissBubble() }
        occupancy.release(.scene, pets: [current.left.index, current.right.index])
        scene = nil

        // The pair has just spent ten seconds nose to nose. Without this they would strike
        // up a conversation the instant they part, which reads as two features fighting
        // over the same cats rather than as one pair of them.
        meetings.noteMeeting()
    }

    /// For `--scene-test`, which has to follow a sequence it cannot watch (SPEC §9).
    var scenePhase: BirthdayScene.Phase? { scene?.routine.phase }
    var sceneConfettiIsUp: Bool { scene?.confetti?.isVisible ?? false }
    var sceneHeartsAreUp: Bool { scene?.hearts?.isVisible ?? false }
}

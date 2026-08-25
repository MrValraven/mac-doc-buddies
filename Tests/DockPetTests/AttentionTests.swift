//
//  AttentionTests.swift: [M13] the cats notice the cursor.
//
//  Every check below runs the coordinator on a clock the test owns: `advance(by:)` takes the
//  elapsed time as a parameter, so a feature whose entire content is timing can be run to
//  completion in microseconds instead of being watched (SPEC §9). Nothing here reads
//  `Date()` or `CACurrentMediaTime()`, and nothing here needs a cursor, a screen or a Dock.
//

import Foundation
import CoreGraphics
import DockPetCore

enum AttentionTests {

    // MARK: - The stage

    /// A bottom Dock 1000 pt wide whose inner edge is at y = 100.
    private static let strip = WalkStrip(edge: .bottom, baseline: 100, start: 0, end: 1000)

    /// Two 64 pt cats standing on it. Centres at x = 132 and x = 532, so the point exactly
    /// between them is x = 332, which is the coordinate the flicker test lives on.
    private static let catA = CGRect(x: 100, y: 100, width: 64, height: 64)
    private static let catB = CGRect(x: 500, y: 100, width: 64, height: 64)

    private static func cast(availableA: Bool = true, availableB: Bool = true)
        -> [AttentionCoordinator.Candidate] {
        [AttentionCoordinator.Candidate(index: 0, frame: catA, isAvailable: availableA),
         AttentionCoordinator.Candidate(index: 1, frame: catB, isAvailable: availableB)]
    }

    /// One frame of the app's 12 fps animation tick.
    private static let tick: TimeInterval = 1.0 / 12

    /// Report a cursor position and run one tick, the way `CursorWatcher` and
    /// `animationTick` between them do.
    @discardableResult
    private static func step(_ coordinator: inout AttentionCoordinator,
                             cursor: CGPoint?,
                             candidates: [AttentionCoordinator.Candidate],
                             dt: TimeInterval = tick) -> AttentionCoordinator.Focus? {
        if let cursor = cursor { coordinator.noteCursor(cursor) }
        return coordinator.advance(by: dt, on: strip, candidates: candidates)
    }

    /// Put the cursor somewhere until attention starts, and hand back the focus.
    private static func engage(_ coordinator: inout AttentionCoordinator,
                               at point: CGPoint,
                               candidates: [AttentionCoordinator.Candidate] = cast())
        -> AttentionCoordinator.Focus? {
        var focus: AttentionCoordinator.Focus?
        for _ in 0..<6 { focus = step(&coordinator, cursor: point, candidates: candidates) }
        return focus
    }

    static func run() {

        section("[M13] attention: the zone")

        do {
            let notice = AttentionCoordinator.zone(for: strip,
                                                   reach: AttentionCoordinator.noticeReach)
            check(notice.contains(CGPoint(x: 500, y: 100)),
                  "a point on the Dock's inner edge is in the zone")
            check(notice.contains(CGPoint(x: 500, y: 40)),
                  "a point over the Dock itself is in the zone")
            check(notice.contains(CGPoint(x: 500, y: 200)),
                  "a point just above the cats is in the zone")
            check(!notice.contains(CGPoint(x: 500, y: 400)),
                  "a point up in the middle of the screen is not")
            check(!notice.contains(CGPoint(x: 2000, y: 120)),
                  "a point far past the end of the strip is not")
            check(notice.contains(CGPoint(x: -60, y: 120)),
                  "a point just past the near end still is, so a cat at the end can see it")

            let release = AttentionCoordinator.zone(
                for: strip,
                reach: AttentionCoordinator.noticeReach + AttentionCoordinator.releaseMargin)
            check(release.insetBy(dx: 1, dy: 1).contains(notice),
                  "the release zone strictly contains the notice zone, which is what makes "
                  + "the edge hysteresis possible at all")

            let sideStrip = WalkStrip(edge: .left, baseline: 80, start: 0, end: 600)
            let sideZone = AttentionCoordinator.zone(for: sideStrip,
                                                     reach: AttentionCoordinator.noticeReach)
            check(sideZone.contains(CGPoint(x: 120, y: 300)),
                  "a vertical strip's zone runs along y, not x")
            check(!sideZone.contains(CGPoint(x: 400, y: 300)),
                  "and is narrow across x")
        }

        section("[M13] attention: noticing takes a moment")

        do {
            var coordinator = AttentionCoordinator()
            check(coordinator.advance(by: tick, on: strip, candidates: cast()) == nil,
                  "a coordinator that has never seen the cursor reports nothing")

            let first = step(&coordinator, cursor: CGPoint(x: 200, y: 150), candidates: cast())
            check(first == nil, "one tick inside the zone is not yet attention")

            // Two ticks is 0.167s, still short of the 0.25s notice delay. The third is what
            // reaches it, which is the arithmetic the delay was picked for: three frames of
            // a 12 fps tick.
            let second = step(&coordinator, cursor: CGPoint(x: 200, y: 150), candidates: cast())
            check(second == nil,
                  "still nothing before the notice delay of \(AttentionCoordinator.noticeDelay)s")

            let focus = step(&coordinator, cursor: CGPoint(x: 200, y: 150), candidates: cast())
            check(focus != nil, "past the notice delay, a cat is paying attention")
            eq(focus?.petIndex, 0, "and it is the near one")
            eq(focus?.pose, AttentionCoordinator.Pose.watch, "it watches before it sits")
            eq(focus?.petState, PetState.idle, "which is a stationary state, so it stops")
        }

        do {
            // A pointer crossing the strip on its way somewhere else, in and straight out
            // again. It is inside the zone for a single tick, so no cat breaks stride.
            var coordinator = AttentionCoordinator()
            var sawFocus = false
            for y in [CGFloat(900), 150, 900, 1200] {
                if step(&coordinator, cursor: CGPoint(x: 300, y: y), candidates: cast()) != nil {
                    sawFocus = true
                }
            }
            check(!sawFocus, "a pointer crossing the strip and leaving triggers nothing")
        }

        do {
            // The sweep along the Dock is the case the cooldown is for. A pointer travelling
            // the length of the strip passes every cat in turn, and the failure mode is not
            // that one cat notices (it is standing right there, and noticing is the feature)
            // but that cat after cat fires as the pointer goes by: a Mexican wave of sitting
            // cats following the mouse. The guarantee is one episode, on one cat.
            var coordinator = AttentionCoordinator()
            var episodes = 0
            var wasEngaged = false
            var runs: [Int] = []
            for x in stride(from: CGFloat(0), through: 1000, by: 40) {
                let focus = step(&coordinator, cursor: CGPoint(x: x, y: 150), candidates: cast())
                if coordinator.isEngaged, !wasEngaged { episodes += 1 }
                wasEngaged = coordinator.isEngaged
                if let focus = focus, runs.last != focus.petIndex { runs.append(focus.petIndex) }
            }
            eq(episodes, 1,
               "a pointer sweeping the whole length of the Dock starts one episode, not one "
               + "per cat it passes")
            check(runs.count == Set(runs).count,
                  "and attention passes each cat at most once: a cat it has already handed "
                  + "off never takes it back as the pointer keeps going",
                  detail: "the order attention moved in was \(runs)")
        }

        do {
            // A cursor that arrives and then rests is still an arrival, so it counts.
            var coordinator = AttentionCoordinator()
            coordinator.noteCursor(CGPoint(x: 200, y: 150))
            var focus: AttentionCoordinator.Focus?
            for _ in 0..<3 {
                focus = coordinator.advance(by: tick, on: strip, candidates: cast())
            }
            check(focus != nil,
                  "a cursor that arrived and then stopped still counts, because the arrival "
                  + "armed it")
        }

        do {
            // Between the notice zone and the release zone is nobody's land: too far to
            // start attention, close enough to keep it. Starting there would make the
            // release margin a second, larger notice zone.
            var coordinator = AttentionCoordinator()
            var focus: AttentionCoordinator.Focus?
            for _ in 0..<40 {
                focus = step(&coordinator, cursor: CGPoint(x: 300, y: 230), candidates: cast())
            }
            check(focus == nil, "a cursor inside the release margin only never starts attention")
        }

        section("[M13] attention: watch, then sit")

        do {
            var coordinator = AttentionCoordinator()
            guard let first = engage(&coordinator, at: CGPoint(x: 200, y: 150)) else {
                Harness.bail("expected the near cat to notice a cursor beside it")
            }
            eq(first.pose, AttentionCoordinator.Pose.watch, "it is stood up watching at first")

            var focus = first
            // Jiggled, so the cursor is present rather than abandoned. A still cursor has
            // its own section below.
            var toggle = false
            for _ in 0..<Int(AttentionCoordinator.sitDelay / tick) + 2 {
                toggle.toggle()
                guard let next = step(&coordinator,
                                      cursor: CGPoint(x: toggle ? 203 : 200, y: 150),
                                      candidates: cast()) else {
                    Harness.bail("attention ended while the cursor was still moving beside it")
                }
                focus = next
            }
            eq(focus.pose, AttentionCoordinator.Pose.sit, "after a moment it sits down")
            eq(focus.petState, PetState.sit, "which is the sit state the caller forces")
            eq(focus.petIndex, 0, "the same cat throughout")
        }

        section("[M13] attention: which way it faces")

        do {
            var coordinator = AttentionCoordinator()
            let focus = engage(&coordinator, at: CGPoint(x: 300, y: 150))
            eq(focus?.petIndex, 0, "the cursor at x=300 is nearer the cat at x=132")
            eq(focus?.facing, Walker.Direction.forward,
               "a cursor to the right of the cat faces it forward, which the app draws as right")
        }

        do {
            var coordinator = AttentionCoordinator()
            let focus = engage(&coordinator, at: CGPoint(x: 40, y: 150))
            eq(focus?.petIndex, 0, "still the near cat")
            eq(focus?.facing, Walker.Direction.backward,
               "a cursor to the left of the cat faces it backward, which the app draws as left")
        }

        section("[M13] attention: the nearest cat, and only one")

        do {
            var coordinator = AttentionCoordinator()
            eq(engage(&coordinator, at: CGPoint(x: 560, y: 150))?.petIndex, 1,
               "a cursor by the far cat picks the far cat")
        }

        do {
            var coordinator = AttentionCoordinator()
            check(engage(&coordinator, at: CGPoint(x: 300, y: 150), candidates: []) == nil,
                  "no cats at all is not a crash")
        }

        section("[M13] hysteresis: the point exactly between two cats")

        do {
            // This is the case the feature dies of: a pointer resting on the midpoint,
            // moved a pixel at a time by a hand on the mouse. Without the switch margin
            // every one of those pixels changes the answer, and both cats stand up and sit
            // down twenty times a second.
            var coordinator = AttentionCoordinator()
            guard let first = engage(&coordinator, at: CGPoint(x: 332, y: 150)) else {
                Harness.bail("expected one of the two cats to notice a cursor between them")
            }
            let chosen = first.petIndex

            var flips = 0
            var toggle = false
            for _ in 0..<60 {
                toggle.toggle()
                // Four points either side of the exact midpoint: the *unstuck* answer
                // alternates between the two cats on every single sample (the gaps are
                // 196/204 one way and 204/196 the other), and 8 pt of travel clears
                // `minimumMovement` so these count as a hand on the mouse rather than as a
                // pointer that has been abandoned.
                let x: CGFloat = toggle ? 328 : 336
                guard let focus = step(&coordinator, cursor: CGPoint(x: x, y: 150),
                                       candidates: cast()) else {
                    Harness.bail("attention ended while the cursor was still being jiggled")
                }
                if focus.petIndex != chosen { flips += 1 }
            }
            eq(flips, 0,
               "sixty samples straddling the exact midpoint never move attention to the "
               + "other cat: the switch margin is what makes this impossible, not luck")

            // And it is stickiness, not paralysis: a decisive move hands over.
            var handed: AttentionCoordinator.Focus?
            for _ in 0..<3 {
                handed = step(&coordinator, cursor: CGPoint(x: 540, y: 150), candidates: cast())
            }
            eq(handed?.petIndex, 1,
               "a cursor that actually walks over to the other cat does hand attention over")
            eq(handed?.pose, AttentionCoordinator.Pose.watch,
               "and the cat it hands over to starts by watching, not already sitting")
        }

        section("[M13] hysteresis: the edge of the zone")

        do {
            var coordinator = AttentionCoordinator()
            guard engage(&coordinator, at: CGPoint(x: 300, y: 210)) != nil else {
                Harness.bail("expected a cursor just inside the zone to be noticed")
            }

            var lost = 0
            var toggle = false
            for _ in 0..<60 {
                toggle.toggle()
                // 219/221 straddles the notice boundary at y = 220. Without the release
                // margin, attention would end and restart on alternate samples.
                let y: CGFloat = toggle ? 219 : 221
                if step(&coordinator, cursor: CGPoint(x: 300, y: y), candidates: cast()) == nil {
                    lost += 1
                }
            }
            eq(lost, 0,
               "sixty samples straddling the notice boundary never drop attention, because "
               + "leaving is judged against the larger release zone")

            var left: AttentionCoordinator.Focus?
            for _ in 0..<2 {
                left = step(&coordinator, cursor: CGPoint(x: 300, y: 400), candidates: cast())
            }
            check(left == nil, "a cursor that genuinely leaves does end attention")
        }

        section("[M13] hysteresis: the cat's own centre")

        do {
            var coordinator = AttentionCoordinator()
            guard let first = engage(&coordinator, at: CGPoint(x: 200, y: 150)) else {
                Harness.bail("expected the near cat to notice")
            }
            eq(first.facing, Walker.Direction.forward, "it starts facing the cursor's side")

            var flips = 0
            var toggle = false
            for _ in 0..<60 {
                toggle.toggle()
                // 131/133 straddles the cat's own centre at x = 132. Without the facing
                // dead zone the sprite would mirror on every sample.
                let x: CGFloat = toggle ? 131 : 133
                guard let focus = step(&coordinator, cursor: CGPoint(x: x, y: 150),
                                       candidates: cast()) else {
                    Harness.bail("attention ended while the cursor was over the cat")
                }
                if focus.facing != first.facing { flips += 1 }
            }
            eq(flips, 0,
               "sixty samples straddling the cat's own centre never mirror the sprite")

            var turned: AttentionCoordinator.Focus?
            for _ in 0..<3 {
                turned = step(&coordinator, cursor: CGPoint(x: 60, y: 150), candidates: cast())
            }
            eq(turned?.facing, Walker.Direction.backward,
               "a cursor decisively on the other side does turn the cat round")
        }

        section("[M13] attention: it ends when the cursor stops")

        do {
            var coordinator = AttentionCoordinator()
            guard engage(&coordinator, at: CGPoint(x: 200, y: 150)) != nil else {
                Harness.bail("expected the near cat to notice")
            }

            // No further reports: the monitor only fires on movement, so silence *is* the
            // cursor having stopped.
            var focus: AttentionCoordinator.Focus?
            for _ in 0..<Int((AttentionCoordinator.attentionSpan - 0.5) / tick) {
                focus = coordinator.advance(by: tick, on: strip, candidates: cast())
            }
            check(focus != nil, "half a second before the span is up, the cat is still watching")

            for _ in 0..<Int(0.5 / tick) + 2 {
                focus = coordinator.advance(by: tick, on: strip, candidates: cast())
            }
            check(focus == nil, "once the span is up, the cat goes back to its own life")
            check(!coordinator.isEngaged, "and the coordinator reports it is no longer engaged")
        }

        do {
            // A pointer that lives near the Dock all afternoon must not freeze a cat all
            // afternoon. The episode has a ceiling of its own.
            var coordinator = AttentionCoordinator()
            guard engage(&coordinator, at: CGPoint(x: 200, y: 150)) != nil else {
                Harness.bail("expected the near cat to notice")
            }
            var toggle = false
            var endedAfter: TimeInterval?
            var elapsed: TimeInterval = 0
            for _ in 0..<Int(AttentionCoordinator.maximumEpisode / tick) + 20 {
                toggle.toggle()
                elapsed += tick
                let focus = step(&coordinator, cursor: CGPoint(x: toggle ? 203 : 200, y: 150),
                                 candidates: cast())
                if focus == nil, endedAfter == nil { endedAfter = elapsed }
            }
            check(endedAfter != nil,
                  "a cursor moving beside the cat forever does not hold it forever")
            // `engage` above already spent the first three ticks of the ceiling getting the
            // episode started, so the loop sees the remainder rather than the whole of it.
            check((endedAfter ?? 0) >= AttentionCoordinator.maximumEpisode - 0.5,
                  "and it is held for essentially the whole ceiling first",
                  detail: "ended after \(endedAfter ?? -1)s, ceiling "
                  + "\(AttentionCoordinator.maximumEpisode)s")
        }

        section("[M13] attention: the cooldown")

        do {
            var coordinator = AttentionCoordinator()
            guard engage(&coordinator, at: CGPoint(x: 200, y: 150)) != nil else {
                Harness.bail("expected the near cat to notice")
            }
            // Walk away, which ends it.
            for _ in 0..<2 {
                step(&coordinator, cursor: CGPoint(x: 200, y: 600), candidates: cast())
            }

            check(engage(&coordinator, at: CGPoint(x: 200, y: 150)) == nil,
                  "coming straight back does not start a second episode")

            // `advance` bounds a single step, so the cooldown is simulated in real ones.
            // Same idiom MeetingTests uses on `MeetingCoordinator`.
            for _ in 0..<Int(AttentionCoordinator.cooldown) {
                coordinator.advance(by: 1, on: strip, candidates: cast())
            }
            check(engage(&coordinator, at: CGPoint(x: 200, y: 150)) != nil,
                  "once the cooldown is up, the cat can notice again")
        }

        do {
            // Repeated dips in and out of the zone are the other half of the sweep problem:
            // each one is a fresh arrival, and without the cooldown each one lands.
            //
            // Twelve half-second rounds is six seconds, comfortably inside the eight second
            // cooldown, so the whole burst is entitled to exactly one reaction.
            var coordinator = AttentionCoordinator()
            var episodes = 0
            var wasEngaged = false
            for round in 0..<12 {
                let inside = round % 2 == 0
                for _ in 0..<6 {
                    step(&coordinator,
                         cursor: CGPoint(x: 200, y: inside ? 150 : 700),
                         candidates: cast())
                }
                if coordinator.isEngaged, !wasEngaged { episodes += 1 }
                wasEngaged = coordinator.isEngaged
            }
            eq(episodes, 1,
               "six trips in and out of the zone inside one cooldown produce one episode, "
               + "not six")
        }

        section("[M13] attention: a bounded time step")

        do {
            var coordinator = AttentionCoordinator()
            guard engage(&coordinator, at: CGPoint(x: 200, y: 150)) != nil else {
                Harness.bail("expected the near cat to notice")
            }
            let focus = coordinator.advance(by: 3600, on: strip, candidates: cast())
            check(focus != nil,
                  "an hour handed back by a stalled process is one clamped step, so a cat "
                  + "watching the cursor does not silently give up during a display sleep")
        }

        do {
            var coordinator = AttentionCoordinator()
            guard engage(&coordinator, at: CGPoint(x: 200, y: 150)) != nil else {
                Harness.bail("expected the near cat to notice")
            }
            for _ in 0..<2 {
                step(&coordinator, cursor: CGPoint(x: 200, y: 600), candidates: cast())
            }
            coordinator.advance(by: 3600, on: strip, candidates: cast())
            check(engage(&coordinator, at: CGPoint(x: 200, y: 150)) == nil,
                  "and one huge step does not burn the whole cooldown either")
        }

        section("[M13] attention: a cat that is busy")

        do {
            var coordinator = AttentionCoordinator()
            let focus = engage(&coordinator, at: CGPoint(x: 300, y: 150),
                               candidates: cast(availableA: false))
            eq(focus?.petIndex, 1,
               "when the nearest cat is busy, the next nearest available one notices instead")
        }

        do {
            var coordinator = AttentionCoordinator()
            check(engage(&coordinator, at: CGPoint(x: 300, y: 150),
                         candidates: cast(availableA: false, availableB: false)) == nil,
                  "when every cat is busy, nobody notices and nothing crashes")

            // The cooldown was not spent on an episode that never happened, so the moment
            // a cat is free it can pick the cursor up.
            let freed = step(&coordinator, cursor: CGPoint(x: 302, y: 150), candidates: cast())
            eq(freed?.petIndex, 0,
               "and the moment a cat is free it notices, with no cooldown to wait out")
        }

        do {
            var coordinator = AttentionCoordinator()
            guard engage(&coordinator, at: CGPoint(x: 200, y: 150)) != nil else {
                Harness.bail("expected the near cat to notice")
            }
            let dropped = step(&coordinator, cursor: CGPoint(x: 202, y: 150),
                               candidates: cast(availableA: false))
            check(dropped == nil,
                  "a cat that is claimed mid-episode drops attention rather than handing it "
                  + "to a cat on the other side of the Dock")
            check(engage(&coordinator, at: CGPoint(x: 200, y: 150)) == nil,
                  "and that counts as an episode, so the cooldown is spent")
        }

        section("[M13] attention: no Dock, no attention")

        do {
            var coordinator = AttentionCoordinator()
            guard engage(&coordinator, at: CGPoint(x: 200, y: 150)) != nil else {
                Harness.bail("expected the near cat to notice")
            }
            coordinator.noteCursor(CGPoint(x: 200, y: 150))
            check(coordinator.advance(by: tick, on: nil, candidates: cast()) == nil,
                  "a Dock that has gone away takes the attention with it")
            check(!coordinator.isEngaged, "and the coordinator is no longer engaged")
        }

        section("[M13] attention: the caller's wake-up hook")

        do {
            check(AttentionCoordinator.isNear(CGPoint(x: 500, y: 150), strip: strip),
                  "a cursor beside the Dock is near it")
            check(!AttentionCoordinator.isNear(CGPoint(x: 500, y: 700), strip: strip),
                  "a cursor up in the document is not")
            check(AttentionCoordinator.isNear(CGPoint(x: 500, y: 240), strip: strip),
                  "the hook uses the release zone, so a cat already watching keeps its ticks")
        }
    }
}

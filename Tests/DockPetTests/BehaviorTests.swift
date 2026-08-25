//
//  BehaviorTests.swift — assertions for DockPetCore.Walker
//

import Foundation
import CoreGraphics
import DockPetCore

enum BehaviorTests {

    /// The measured bottom strip from PROBE.md Run 1, with a 50-pt pet: 1512 - 50.
    private static let maxDistance: CGFloat = 1462

    static func run() {

        section("walker: speed")

        // Every step here is below Walker.maximumStep, so no stall clamping is involved;
        // the clamp gets its own test below.
        var w = Walker(speed: 30)
        for _ in 0..<10 { w.advance(by: 0.1, maxDistance: maxDistance) }
        eq(w.distance, 30, "30 px/s covers 30 pt over one second of real ticks")

        w = Walker(speed: 30)
        for _ in 0..<12 { w.advance(by: 1.0 / 12.0, maxDistance: maxDistance) }
        eq(w.distance, 30, "twelve 12-fps frames also cover exactly 30 pt")

        // Frame rate must not change the distance travelled.
        var slow = Walker(speed: 30)
        var fast = Walker(speed: 30)
        for _ in 0..<10 { slow.advance(by: 0.1, maxDistance: maxDistance) }
        for _ in 0..<100 { fast.advance(by: 0.01, maxDistance: maxDistance) }
        eq(slow.distance, fast.distance, "distance is independent of tick rate")

        section("walker: turning")

        // 0.2 s at 30 px/s is 6 pt, which overshoots the remaining 5 pt.
        w = Walker(distance: maxDistance - 5, direction: .forward, speed: 30)
        w.advance(by: 0.2, maxDistance: maxDistance)
        eq(w.distance, maxDistance, "stops exactly at the far end, never past it")
        check(w.direction == .backward, "turns around at the far end")

        w.advance(by: 0.2, maxDistance: maxDistance)
        eq(w.distance, maxDistance - 6, "walks back the other way after turning")
        check(w.direction == .backward, "keeps going backward until the near end")

        w = Walker(distance: 5, direction: .backward, speed: 30)
        w.advance(by: 0.2, maxDistance: maxDistance)
        eq(w.distance, 0, "stops exactly at the near end")
        check(w.direction == .forward, "turns around at the near end")

        // A full there-and-back lap must return to the start, still heading forward.
        w = Walker(speed: 30)
        let lapSeconds = Double(maxDistance) / 30.0
        for _ in 0..<Int(lapSeconds * 12 * 2) { w.advance(by: 1.0 / 12.0, maxDistance: maxDistance) }
        check(w.distance >= 0 && w.distance <= maxDistance, "stays on the strip across a full lap",
              detail: "distance=\(w.distance)")

        section("walker: stalled timers (SPEC §8 trap 3)")

        w = Walker(speed: 30)
        w.advance(by: 3600, maxDistance: maxDistance)
        eq(w.distance, 30 * CGFloat(Walker.maximumStep),
           "an hour-long stall advances by at most one clamped step (7.5 pt), not the whole Dock")

        // The clamp must bite at exactly the documented threshold, not somewhere near it.
        var justUnder = Walker(speed: 30)
        justUnder.advance(by: Walker.maximumStep - 0.01, maxDistance: maxDistance)
        eq(justUnder.distance, 30 * CGFloat(Walker.maximumStep - 0.01), "a step just under the ceiling is unclamped")

        var justOver = Walker(speed: 30)
        justOver.advance(by: Walker.maximumStep + 0.01, maxDistance: maxDistance)
        eq(justOver.distance, 30 * CGFloat(Walker.maximumStep), "a step just over the ceiling is clamped")

        w = Walker(speed: 30)
        w.advance(by: -5, maxDistance: maxDistance)
        eq(w.distance, 0, "a negative dt does not move the pet backwards")

        section("walker: the strip changing underneath")

        w = Walker(distance: 1400, direction: .forward, speed: 30)
        w.advance(by: 0.2, maxDistance: 100)
        check(w.distance <= 100, "a strip that shrank mid-walk cannot leave the pet beyond it",
              detail: "distance=\(w.distance)")

        w = Walker(distance: 1400, direction: .forward, speed: 30)
        w.clamp(to: 100)
        eq(w.distance, 100, "clamp pulls the pet back onto a shorter strip")

        w = Walker(distance: 50, direction: .forward, speed: 30)
        w.clamp(to: 1462)
        eq(w.distance, 50, "clamp leaves a pet that is already on the strip alone")

        section("walker: degenerate strips")

        w = Walker(distance: 40, direction: .forward, speed: 30)
        w.advance(by: 0.2, maxDistance: 0)
        eq(w.distance, 0, "a strip with no room parks the pet at the near end")

        w = Walker(distance: 40, direction: .forward, speed: 30)
        w.advance(by: 0.2, maxDistance: -50)
        eq(w.distance, 0, "a negative maxDistance is treated as no room, not as a crash")

        w = Walker(speed: 0)
        w.advance(by: 0.2, maxDistance: maxDistance)
        eq(w.distance, 0, "zero speed does not move")
    }
}

// MARK: - State machine (M5)

enum StateMachineTests {

    static func run() {

        section("state machine: determinism")

        var a = BehaviorMachine(seed: 42)
        var b = BehaviorMachine(seed: 42)
        var sequenceA: [PetState] = []
        var sequenceB: [PetState] = []
        for _ in 0..<2000 {
            sequenceA.append(a.advance(by: 0.5))
            sequenceB.append(b.advance(by: 0.5))
        }
        check(sequenceA == sequenceB, "the same seed produces the same sequence of states")
        check(a.transitionCount == b.transitionCount, "and the same number of transitions")

        var c = BehaviorMachine(seed: 1)
        var d = BehaviorMachine(seed: 99999)
        var differs = false
        for _ in 0..<2000 where c.advance(by: 0.5) != d.advance(by: 0.5) { differs = true }
        check(differs, "different seeds diverge")

        section("state machine: dwell times are respected")

        // Step finely and record how long each state actually lasted.
        var machine = BehaviorMachine(seed: 7)
        var durations: [PetState: [TimeInterval]] = [:]
        var current = machine.state
        var elapsed: TimeInterval = 0
        let step = 0.05
        for _ in 0..<200_000 {                       // ~2.7 simulated hours
            let next = machine.advance(by: step)
            elapsed += step
            if next != current {
                durations[current, default: []].append(elapsed)
                current = next
                elapsed = 0
            }
        }

        for state in PetState.allCases {
            guard let profile = BehaviorMachine.defaultProfiles[state],
                  let observed = durations[state], !observed.isEmpty else {
                check(false, "\(state.rawValue) occurred at least once")
                continue
            }
            let shortest = observed.min()!
            let longest = observed.max()!
            // One step of slack: a transition is only noticed on the step that crosses it.
            check(shortest >= profile.minDwell - step * 2,
                  "\(state.rawValue) never ends sooner than its \(profile.minDwell)s minimum",
                  detail: "shortest was \(String(format: "%.2f", shortest))s")
            check(longest <= profile.maxDwell + step * 2,
                  "\(state.rawValue) never runs past its \(profile.maxDwell)s maximum",
                  detail: "longest was \(String(format: "%.2f", longest))s")
        }

        section("state machine: transitions")

        check(PetState.allCases.allSatisfy { durations[$0]?.isEmpty == false },
              "all four states are reachable",
              detail: "seen: \(durations.keys.map(\.rawValue).sorted().joined(separator: ", "))")

        // A transition to the same state would be an invisible "change".
        var selfTransitions = 0
        var m = BehaviorMachine(seed: 3)
        var previous = m.state
        for _ in 0..<200_000 {
            let next = m.advance(by: 0.05)
            if next != previous {
                if next == previous { selfTransitions += 1 }
                previous = next
            }
        }
        check(selfTransitions == 0, "the pet never transitions to the state it is already in")

        // Every profile must list only reachable, non-self targets with positive weight.
        for (state, profile) in BehaviorMachine.defaultProfiles {
            check(!profile.transitions.contains { $0.state == state },
                  "\(state.rawValue)'s profile does not list itself as a target")
            check(profile.transitions.allSatisfy { $0.weight > 0 },
                  "\(state.rawValue)'s transitions all have positive weight")
            check(profile.minDwell > 0 && profile.maxDwell >= profile.minDwell,
                  "\(state.rawValue)'s dwell range is sane",
                  detail: "\(profile.minDwell)...\(profile.maxDwell)")
        }

        section("state machine: the resulting rhythm")

        // Total time spent in each state over the long run.
        var totals: [PetState: TimeInterval] = [:]
        for (state, list) in durations { totals[state] = list.reduce(0, +) }
        let grand = totals.values.reduce(0, +)
        for state in PetState.allCases {
            let share = (totals[state] ?? 0) / grand * 100
            print(String(format: "        %-6@ %5.1f%% of the time, %d visits",
                         state.rawValue as NSString, share, durations[state]?.count ?? 0))
        }

        // The intended feel, pinned. These are deliberately wide bands — they exist to
        // catch a retune that quietly turns the pet into a sleeping rock, not to freeze
        // the exact numbers.
        let walkShare = (totals[.walk] ?? 0) / grand
        check(walkShare > 0.45, "the pet spends most of its time walking",
              detail: String(format: "%.1f%%", walkShare * 100))

        let sleepShare = (totals[.sleep] ?? 0) / grand
        check(sleepShare < 0.20, "the pet is not asleep for a large share of the day",
              detail: String(format: "%.1f%%", sleepShare * 100))

        let movingShare = walkShare
        check(movingShare > (totals[.sleep] ?? 0) / grand * 2,
              "walking outweighs sleeping by a clear margin")

        let sleepVisits = durations[.sleep]?.count ?? 0
        let walkVisits = durations[.walk]?.count ?? 0
        check(sleepVisits < walkVisits, "sleeping is rarer than walking",
              detail: "\(sleepVisits) sleeps vs \(walkVisits) walks")

        // Weighted choice must actually follow the weights: from walk, idle (55) should be
        // chosen appreciably more often than sleep (10).
        var fromWalk: [PetState: Int] = [:]
        var w = BehaviorMachine(seed: 11, initial: .walk)
        var prev = w.state
        for _ in 0..<400_000 {
            let next = w.advance(by: 0.05)
            if next != prev {
                if prev == .walk { fromWalk[next, default: 0] += 1 }
                prev = next
            }
        }
        let idleFromWalk = fromWalk[.idle] ?? 0
        let sleepFromWalk = fromWalk[.sleep] ?? 0
        check(idleFromWalk > sleepFromWalk * 3,
              "leaving walk, idle (weight 58) is picked far more than sleep (weight 5)",
              detail: "idle \(idleFromWalk) vs sleep \(sleepFromWalk)")

        section("state machine: time handling")

        var still = BehaviorMachine(seed: 5)
        let before = still.state
        still.advance(by: 0)
        still.advance(by: -10)
        check(still.state == before && still.transitionCount == 0,
              "zero and negative dt do not advance the machine")

        // SPEC §8 trap 3 again: a stalled timer must not stampede through states.
        var stalled = BehaviorMachine(seed: 5)
        stalled.advance(by: 3600)
        check(stalled.transitionCount <= 1,
              "an hour-long stall causes at most one transition, not hundreds",
              detail: "\(stalled.transitionCount) transitions")

        // Fine and coarse stepping must agree, within the clamp.
        var fine = BehaviorMachine(seed: 21)
        var coarse = BehaviorMachine(seed: 21)
        for _ in 0..<100 { fine.advance(by: 0.01) }
        coarse.advance(by: 1.0)
        check(fine.state == coarse.state, "100 small steps match one 1 s step",
              detail: "\(fine.state.rawValue) vs \(coarse.state.rawValue)")

        section("state machine: movement")

        check(PetState.walk.isMoving, "walk moves the pet")
        check(!PetState.idle.isMoving && !PetState.sit.isMoving && !PetState.sleep.isMoving,
              "idle, sit and sleep are stationary")

        section("state machine: forcing a state (M10)")

        // Clicking "Take a nap" has to override whatever the machine had planned, without
        // leaving the pet stuck there — it goes to sleep, then carries on as normal.
        var forced = BehaviorMachine(seed: 5, initial: .walk)
        forced.force(.sleep)
        check(forced.state == .sleep, "a forced state takes effect immediately")
        check(forced.timeInState == 0, "and starts its dwell from zero")
        check(forced.currentDwell > 0, "with a dwell of its own, so it is not left stuck")

        let countBefore = forced.transitionCount
        forced.force(.sleep)
        check(forced.state == .sleep, "forcing the state it is already in is not an error")
        check(forced.transitionCount == countBefore,
              "and does not count as a transition, because nothing changed")

        var resumes = BehaviorMachine(seed: 5, initial: .walk)
        resumes.force(.sleep)
        // Stepped rather than one big jump: `advance` clamps a single step to
        // `maximumStep`, so one 600 s call would only simulate a second.
        for _ in 0..<1200 { resumes.advance(by: 0.5) }
        check(resumes.transitionCount > 1,
              "the pet wakes up again on its own after a forced nap",
              detail: "still \(resumes.state.rawValue) after 600 s")

        var counted = BehaviorMachine(seed: 5, initial: .walk)
        let transitionsBefore = counted.transitionCount
        counted.force(.sleep)
        check(counted.transitionCount == transitionsBefore + 1, "a real forced change counts as one transition")
    }
}

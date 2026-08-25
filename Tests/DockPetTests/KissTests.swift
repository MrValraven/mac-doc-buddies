//
//  KissTests.swift — [M12] the kiss: steering toward a partner, the routine's phases,
//  and the hearts.
//
//  SPEC §9: none of this can be watched from here, so every part of it that can be
//  checked without a screen is checked here rather than described.
//

import Foundation
import CoreGraphics
import DockPetCore

enum KissTests {

    static func run() {
        section("[M12] Walker — steering toward a point on the strip")

        do {
            var walker = Walker(distance: 0, direction: .backward, speed: 30)
            let arrived = walker.walk(toward: 300, by: 1, maxDistance: 600)
            eq(walker.distance, 7.5, "one bounded step at 30 pt/s is 7.5 pt toward the target")
            eq(walker.direction, .forward, "and it turns to face the way it is going")
            eq(arrived, false, "300 pt away is not arrival")
        }

        do {
            var walker = Walker(distance: 400, direction: .forward, speed: 30)
            walker.walk(toward: 100, by: 1, maxDistance: 600)
            eq(walker.distance, 392.5, "a target behind it walks it backward")
            eq(walker.direction, .backward, "facing follows the target, not the old heading")
        }

        do {
            var walker = Walker(distance: 95, direction: .forward, speed: 30)
            let arrived = walker.walk(toward: 100, by: 1, maxDistance: 600)
            eq(walker.distance, 100, "a step longer than the gap lands on the target")
            eq(arrived, true, "and reports arrival rather than overshooting")
        }

        do {
            var walker = Walker(distance: 100, direction: .forward, speed: 30)
            eq(walker.walk(toward: 100, by: 1, maxDistance: 600), true,
               "standing on the target is arrival, without a step")
            eq(walker.distance, 100, "and it does not drift off the target it reached")
        }

        do {
            var walker = Walker(distance: 595, direction: .forward, speed: 30)
            let arrived = walker.walk(toward: 900, by: 1, maxDistance: 600)
            eq(walker.distance, 600, "a target off the end of the strip is clamped to the end")
            eq(arrived, true, "and reaching the clamped target is arrival")
        }

        do {
            var walker = Walker(distance: 0, direction: .forward, speed: 30)
            walker.walk(toward: 600, by: 60, maxDistance: 600)
            eq(walker.distance, 30 * CGFloat(Walker.maximumStep),
               "a stalled timer covers one bounded step, not the length of the Dock")
        }

        do {
            var walker = Walker(distance: 40, direction: .forward, speed: 30)
            eq(walker.walk(toward: 10, by: 1, maxDistance: 0), true,
               "a strip with no room to walk parks the pet at the near end")
            eq(walker.distance, 0, "which is distance zero")
        }

        section("[M14] Walker: running rather than strolling")

        do {
            check(KissRoutine.approachSpeedMultiplier > 1,
                  "a pair asked to kiss runs at each other rather than strolling over")
        }

        do {
            var walker = Walker(distance: 0, direction: .forward, speed: 30)
            walker.walk(toward: 300, by: 1, maxDistance: 600, speedMultiplier: 2)
            eq(walker.distance, 15, "twice the speed covers twice the ground in one step")
        }

        do {
            var walker = Walker(distance: 0, direction: .forward, speed: 30)
            walker.walk(toward: 300, by: 1, maxDistance: 600, speedMultiplier: 1)
            eq(walker.distance, 7.5, "and a multiplier of one is the walk it always was")
        }

        do {
            var walker = Walker(distance: 95, direction: .forward, speed: 30)
            let arrived = walker.walk(toward: 100, by: 1, maxDistance: 600, speedMultiplier: 4)
            eq(arrived, true, "a running step longer than the gap is still arrival")
            eq(walker.distance, 100, "and it lands on the target rather than overshooting it")
        }

        do {
            var walker = Walker(distance: 0, direction: .forward, speed: 30)
            walker.walk(toward: 600, by: 60, maxDistance: 600, speedMultiplier: 2)
            eq(walker.distance, 30 * 2 * CGFloat(Walker.maximumStep),
               "a stalled timer covers one bounded step of running, not the length of the Dock")
        }

        do {
            var walker = Walker(distance: 300, direction: .forward, speed: 30)
            walker.walk(toward: 0, by: 1, maxDistance: 600, speedMultiplier: 3)
            eq(walker.distance, 277.5, "running backward is running too")
            eq(walker.direction, .backward, "and facing still follows the target")
        }

        do {
            var walker = Walker(distance: 40, direction: .forward, speed: 30)
            eq(walker.walk(toward: 10, by: 1, maxDistance: 0, speedMultiplier: 5), true,
               "and a strip with no room to run parks the pet at the near end all the same")
            eq(walker.distance, 0, "which is distance zero")
        }

        section("[M12] KissRoutine — the six phases")

        /// Run the routine forward in animation-sized steps.
        func advance(_ routine: inout KissRoutine, seconds: TimeInterval, touching: Bool) {
            var elapsed: TimeInterval = 0
            while elapsed < seconds {
                routine.advance(by: 0.25, touching: touching)
                elapsed += 0.25
            }
        }

        do {
            let routine = KissRoutine()
            eq(routine.phase, .approach, "a kiss opens by walking toward the other cat")
            eq(routine.isActive, true, "and is live from the moment it is made")
            eq(routine.abandoned, false, "nothing has gone wrong yet")
        }

        do {
            var routine = KissRoutine()
            advance(&routine, seconds: 3, touching: false)
            eq(routine.phase, .approach, "cats that have not reached each other are still walking")
        }

        do {
            var routine = KissRoutine()
            routine.advance(by: 0.25, touching: true)
            eq(routine.phase, .announce, "touching is what ends the approach")
            eq(routine.timeInPhase, 0, "and the line starts from the top, not mid-phase")
        }

        do {
            var routine = KissRoutine()
            routine.advance(by: 0.25, touching: true)
            advance(&routine, seconds: KissRoutine.announceDuration, touching: true)
            eq(routine.phase, .kiss, "the announcement is what the hearts follow")
            eq(routine.timeInPhase, 0, "and they start from the top, not mid-phase")
        }

        do {
            var routine = KissRoutine()
            routine.advance(by: 0.25, touching: true)
            advance(&routine, seconds: KissRoutine.announceDuration - 0.5, touching: true)
            eq(routine.phase, .announce, "the line stays up for as long as it takes to read")
            advance(&routine, seconds: 0.75, touching: true)
            eq(routine.phase, .kiss, "and then they kiss")

            advance(&routine, seconds: KissRoutine.kissDuration - 0.5, touching: true)
            eq(routine.phase, .kiss, "the hearts get the whole of their own phase")
            advance(&routine, seconds: 0.75, touching: true)
            eq(routine.phase, .declare, "and once they have gone, one of them says it")

            advance(&routine, seconds: 0.5, touching: true)
            eq(routine.phase, .declare, "which stays up for as long as it takes to read")
            advance(&routine, seconds: KissRoutine.declareDuration, touching: true)
            eq(routine.phase, .reply, "and then the other one answers")

            advance(&routine, seconds: 0.75, touching: true)
            eq(routine.phase, .part, "the answer is the last thing said")

            advance(&routine, seconds: KissRoutine.partDuration, touching: false)
            eq(routine.phase, .done, "and the pair is handed back to its own behaviour")
            eq(routine.isActive, false, "a finished routine is not active")
            eq(routine.abandoned, false, "a kiss that happened was not abandoned")
        }

        do {
            var routine = KissRoutine()
            advance(&routine, seconds: KissRoutine.approachCeiling + 1, touching: false)
            eq(routine.phase, .done, "an approach that never arrives gives up rather than hanging")
            eq(routine.abandoned, true, "and says so, so the log can explain the cats parting")
        }

        do {
            var routine = KissRoutine()
            advance(&routine, seconds: KissRoutine.approachCeiling - 0.25, touching: false)
            routine.advance(by: 0.25, touching: true)
            eq(routine.phase, .announce, "arriving on the last tick still kisses")
            eq(routine.abandoned, false, "the ceiling never pre-empts a pair that made it")
        }

        do {
            var routine = KissRoutine()
            routine.advance(by: 600, touching: true)
            eq(routine.phase, .announce, "a stalled timer advances one phase, not the whole kiss")
            routine.advance(by: 600, touching: true)
            eq(routine.phase, .announce,
               "and it spends a bounded second in that phase, not the ten minutes it was handed")
            routine.advance(by: 600, touching: true)
            eq(routine.phase, .kiss, "so the line is still on screen for a readable time")
            routine.advance(by: 600, touching: true)
            routine.advance(by: 600, touching: true)
            eq(routine.phase, .declare, "the hearts are not skipped either")
            routine.advance(by: 600, touching: true)
            routine.advance(by: 600, touching: true)
            eq(routine.phase, .reply, "and neither is the line that answers them")
        }

        do {
            var routine = KissRoutine()
            advance(&routine, seconds: KissRoutine.approachCeiling + 1, touching: false)
            let (previous, current) = routine.advance(by: 0.25, touching: true)
            eq(previous, .done, "a finished routine stays finished")
            eq(current, .done, "even when the cats are standing on each other")
        }

        do {
            var routine = KissRoutine()
            routine.advance(by: 0, touching: true)
            eq(routine.phase, .approach, "a zero-length tick is not a tick")
            routine.advance(by: -5, touching: true)
            eq(routine.phase, .approach, "and neither is a clock that ran backwards")
        }

        section("[M12] HeartDrift — hearts rising over the pair")

        do {
            let hearts = HeartDrift.hearts(progress: 0.5, spread: 20, rise: 40)
            eq(hearts.count, HeartDrift.count, "the drift draws every heart, every frame")
        }

        do {
            let hearts = HeartDrift.hearts(progress: 0, spread: 20, rise: 40)
            check(hearts.allSatisfy { $0.alpha == 0 },
                  "nothing is on screen on the frame the kiss starts")
            check(hearts.allSatisfy { $0.offset == .zero },
                  "and every heart starts between the two cats")
        }

        do {
            let hearts = HeartDrift.hearts(progress: 1, spread: 20, rise: 40)
            check(hearts.allSatisfy { $0.alpha == 0 },
                  "and nothing is left on screen when the kiss ends")
            eq(hearts[0].offset.y, 40, "the first heart has risen its full height by then")
        }

        do {
            let low = HeartDrift.hearts(progress: 0.3, spread: 20, rise: 40)[0]
            let high = HeartDrift.hearts(progress: 0.6, spread: 20, rise: 40)[0]
            check(high.offset.y > low.offset.y, "hearts rise rather than hover")
        }

        do {
            let hearts = HeartDrift.hearts(progress: 0.1, spread: 20, rise: 40)
            eq(hearts[HeartDrift.count - 1].alpha, 0,
               "the last heart has not appeared yet — they are staggered, not a single puff")
            eq(hearts[HeartDrift.count - 1].offset.y, 0, "and it has not moved either")
            check(hearts[0].alpha > 0, "while the first one is already up")
        }

        do {
            let hearts = HeartDrift.hearts(progress: 0.5, spread: 20, rise: 40)
            check(hearts.first!.offset.x < 0 && hearts.last!.offset.x > 0,
                  "the hearts fan out both ways rather than stacking in a column")
            check(hearts.allSatisfy { abs($0.offset.x) <= 20 },
                  "and none of them drifts wider than the spread it was given")
        }

        do {
            let past = HeartDrift.hearts(progress: 4, spread: 20, rise: 40)
            let end = HeartDrift.hearts(progress: 1, spread: 20, rise: 40)
            check(past == end, "a progress past the end is the end, not a heart in orbit")

            let before = HeartDrift.hearts(progress: -2, spread: 20, rise: 40)
            let start = HeartDrift.hearts(progress: 0, spread: 20, rise: 40)
            check(before == start, "and a negative one is the start")
        }

        do {
            eq(HeartDrift.duration, KissRoutine.kissDuration,
               "the hearts last exactly as long as the phase that shows them")
        }

        section("[M12] The meeting that becomes a kiss")

        let left = CGRect(x: 100, y: 0, width: 32, height: 32)
        let touching = CGRect(x: 120, y: 0, width: 32, height: 32)

        /// Run the cooldown out. `advance` clamps each step to a second, so a single call
        /// with the cooldown's own length elapses one second of it — the same bound that
        /// stops a stalled process burning the whole cooldown in one tick.
        func elapseCooldown(_ coordinator: inout MeetingCoordinator) {
            for _ in 0..<Int(MeetingCoordinator.cooldown) { coordinator.advance(by: 1) }
        }

        do {
            check(!Phrasebook.kissLine.contains(Phrasebook.nameSlot),
                  "the kiss line names nobody — it is said to a cat standing right there")
            check(!Phrasebook.kissLine.isEmpty, "and there is a line to say")
        }

        do {
            let love = Phrasebook.loveLine
            check(!love.opener.contains(Phrasebook.nameSlot)
                  && !love.reply.contains(Phrasebook.nameSlot),
                  "neither half of what follows the hearts names anybody either")
            check(!love.opener.isEmpty && !love.reply.isEmpty, "and both halves have words")
            check(love.opener != love.reply,
                  "the answer is an answer, not the same line said twice")
            check(love.opener != Phrasebook.kissLine,
                  "and it is not the announcement said a second time")
        }

        do {
            var coordinator = MeetingCoordinator(seed: 5)
            guard let encounter = coordinator.meet(left, touching, openerName: "Mochi",
                                                   replierName: "Tigre", kissesAllowed: false)
            else { Harness.bail("a meeting inside the cooldown should still produce something") }
            check(encounter.exchange != nil, "a chat encounter carries the words traded")
            eq(encounter.isKiss, false, "and is not a kiss")
        }

        do {
            var coordinator = MeetingCoordinator(seed: 5)
            var kisses = 0
            for _ in 0..<400 {
                elapseCooldown(&coordinator)
                let encounter = coordinator.meet(left, touching, openerName: "Mochi",
                                                 replierName: "Tigre", kissesAllowed: false)
                if encounter?.isKiss == true { kisses += 1 }
            }
            eq(kisses, 0, "with kissing switched off, four hundred meetings are four hundred chats")
        }

        do {
            var coordinator = MeetingCoordinator(seed: 5)
            var kisses = 0
            for _ in 0..<400 {
                elapseCooldown(&coordinator)
                let encounter = coordinator.meet(left, touching, openerName: "Mochi",
                                                 replierName: "Tigre", kissesAllowed: true)
                if encounter?.isKiss == true { kisses += 1 }
            }
            check((40...128).contains(kisses),
                  "roughly one meeting in five is a kiss — the rest stay conversations",
                  detail: "\(kisses) of 400")
        }

        do {
            var coordinator = MeetingCoordinator(seed: 5)
            var line: String?
            for _ in 0..<400 where line == nil {
                elapseCooldown(&coordinator)
                if case .kiss(let said)? = coordinator.meet(left, touching, openerName: "Mochi",
                                                            replierName: "Tigre",
                                                            kissesAllowed: true) {
                    line = said
                }
            }
            eq(line, Phrasebook.kissLine, "a kiss is announced with the kiss line")
        }

        do {
            var a = MeetingCoordinator(seed: 77)
            var b = MeetingCoordinator(seed: 77)
            var same = true
            for _ in 0..<50 {
                elapseCooldown(&a)
                elapseCooldown(&b)
                let one = a.meet(left, touching, openerName: "M", replierName: "T",
                                 kissesAllowed: true)
                let two = b.meet(left, touching, openerName: "M", replierName: "T",
                                 kissesAllowed: true)
                if one != two { same = false }
            }
            check(same, "two coordinators on one seed kiss and chat in the same order")
        }

        section("[M12] MeetingCoordinator — stamping the cooldown without an exchange")

        do {
            var coordinator = MeetingCoordinator(seed: 5)
            coordinator.noteMeeting()
            check(coordinator.meet(left, touching, openerName: "Mochi",
                                   replierName: "Tigre") == nil,
                  "a kiss asked for from the menu spends the cooldown like any other meeting")

            for _ in 0..<Int(MeetingCoordinator.cooldown) { coordinator.advance(by: 1) }
            check(coordinator.meet(left, touching, openerName: "Mochi",
                                   replierName: "Tigre") != nil,
                  "and the pair is talking again a cooldown later, not silenced for good")
        }

        section("[M12] config — the kissing toggle")

        func decode(_ json: String) -> PetConfig? {
            try? JSONDecoder().decode(PetConfig.self, from: Data(json.utf8))
        }

        eq(PetConfig.default.kisses, true,
           "cats kiss by default — a feature switched off by default is one nobody finds")
        eq(decode("{}")?.kisses, true,
           "and a config written before M12 gets the default rather than nothing")
        eq(decode(#"{"kisses":false}"#)?.kisses, false, "turning it off decodes")

        do {
            let off = PetConfig(kisses: false)
            guard let data = try? JSONEncoder().encode(off),
                  let back = try? JSONDecoder().decode(PetConfig.self, from: data) else {
                Harness.bail("a config with kissing off should round-trip through JSON")
            }
            eq(back.kisses, false, "and survives being written to disk and read back")
        }

        do {
            let validated = PetConfig(kisses: false).validated()
            eq(validated.config.kisses, false, "validation leaves the toggle where the user put it")
            check(validated.corrections.isEmpty, "and has nothing to correct about a Bool")
        }
    }
}

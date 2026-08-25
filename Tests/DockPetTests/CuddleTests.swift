//
//  CuddleTests.swift: [M14] the cuddle nap. The phases and their clock, the words, the
//  roll that turns a meeting into one, and who is allowed to take a sleeping cat.
//
//  SPEC §9: the nap takes the best part of twenty seconds of screen and leaves nothing
//  behind, so everything about it that can be checked without a Dock is checked here.
//

import Foundation
import CoreGraphics
import DockPetCore

enum CuddleTests {

    static func run() {
        section("[M14] CuddleRoutine: the seven phases")

        /// Run the routine forward in animation-sized steps.
        func advance(_ routine: inout CuddleRoutine, seconds: TimeInterval) {
            var elapsed: TimeInterval = 0
            while elapsed < seconds {
                routine.advance(by: 0.25)
                elapsed += 0.25
            }
        }

        do {
            let routine = CuddleRoutine()
            eq(routine.phase, .approach, "a nap opens by walking over to the other cat")
            eq(routine.isFinished, false, "and is live from the moment it is made")
            eq(routine.wasAbandoned, false, "nothing has gone wrong yet")
        }

        do {
            var routine = CuddleRoutine()
            advance(&routine, seconds: 3)
            eq(routine.phase, .approach, "cats that have not reached each other are still walking")
        }

        do {
            var routine = CuddleRoutine()
            routine.arrive()
            let (previous, current) = routine.advance(by: 0.25)
            eq(current, .settle, "arriving is what ends the approach")
            eq(routine.timeInPhase, 0, "and the settling starts from the top, not mid-phase")
            // The bug this pins: `arrive()` used to change the phase itself, so the tick a
            // pair arrived on reported settle → settle and the caller, which hangs its
            // one-shot work off a *change*, never sat the cats down. They said every line
            // of the nap on the walk sheet, still walking, and wandered apart through it.
            eq(previous, .approach,
               "and the tick it happens on reports the approach it left, so the caller can"
               + " see the change and sit them down")
        }

        do {
            var routine = CuddleRoutine()
            routine.arrive()
            let (previous, current) = routine.advance(by: 600)
            eq(previous, .approach, "arriving on a stalled tick is still one reported change")
            eq(current, .settle, "and one phase, not the settling skipped on the way past")
        }

        do {
            var routine = CuddleRoutine()
            routine.arrive()
            advance(&routine, seconds: CuddleRoutine.settleDuration + 1)
            routine.arrive()
            eq(routine.phase, .snuggle, "arriving a second time is not a second approach")
        }

        do {
            var routine = CuddleRoutine()
            routine.arrive()

            advance(&routine, seconds: CuddleRoutine.settleDuration - 0.5)
            eq(routine.phase, .settle, "they get a beat to curl up before anybody speaks")
            advance(&routine, seconds: 0.75)
            eq(routine.phase, .snuggle, "and then one of them says something")

            advance(&routine, seconds: CuddleRoutine.snuggleDuration - 0.5)
            eq(routine.phase, .snuggle, "which stays up for as long as it takes to read")
            advance(&routine, seconds: 0.75)
            eq(routine.phase, .reply, "and the other one answers it")

            advance(&routine, seconds: CuddleRoutine.replyDuration)
            eq(routine.phase, .sleep, "the answer is the last thing said before they drop off")

            advance(&routine, seconds: CuddleRoutine.sleepDuration - 1)
            eq(routine.phase, .sleep, "the nap is the long part, and nobody talks through it")
            advance(&routine, seconds: 1.25)
            eq(routine.phase, .wake, "then one of them wakes up with something to say")

            advance(&routine, seconds: CuddleRoutine.wakeDuration)
            eq(routine.phase, .part, "and the pair turns around")

            advance(&routine, seconds: CuddleRoutine.partDuration)
            eq(routine.phase, .done, "and is handed back to its own behaviour")
            eq(routine.isFinished, true, "a finished nap is finished")
            eq(routine.wasAbandoned, false, "a nap that happened was not abandoned")
        }

        do {
            var routine = CuddleRoutine()
            advance(&routine, seconds: CuddleRoutine.approachCeiling + 1)
            eq(routine.phase, .done, "an approach that never arrives gives up rather than hanging")
            eq(routine.wasAbandoned, true, "and says so, so the log can explain the cats parting")
        }

        do {
            var routine = CuddleRoutine()
            advance(&routine, seconds: CuddleRoutine.approachCeiling + 1)
            routine.arrive()
            eq(routine.phase, .done, "a nap that gave up is not restarted by arriving late")
        }

        do {
            var routine = CuddleRoutine()
            routine.arrive()
            routine.advance(by: 600)
            eq(routine.phase, .settle, "a stalled timer advances one phase, not the whole nap")
            routine.advance(by: 600)
            eq(routine.phase, .snuggle, "so the pair is sat down before anybody speaks")
            routine.advance(by: 600)
            eq(routine.phase, .snuggle,
               "and spends a bounded second there, not the ten minutes it was handed")
            routine.advance(by: 600)
            eq(routine.phase, .reply, "so the first line is on screen for a readable time")
            routine.advance(by: 600)
            routine.advance(by: 600)
            eq(routine.phase, .sleep, "and so is the answer")
        }

        do {
            var routine = CuddleRoutine()
            routine.arrive()
            routine.advance(by: 0)
            eq(routine.phase, .approach, "a zero-length tick is not a tick, arrival or not")
            routine.advance(by: -5)
            eq(routine.phase, .approach, "and neither is a clock that ran backwards")
            routine.advance(by: 0.25)
            eq(routine.phase, .settle, "the arrival is still there to be spent afterwards")
        }

        do {
            var routine = CuddleRoutine()
            advance(&routine, seconds: CuddleRoutine.approachCeiling + 1)
            let (previous, current) = routine.advance(by: 0.25)
            eq(previous, .done, "a finished routine stays finished")
            eq(current, .done, "however long it is ticked for")
        }

        section("[M14] CuddleRoutine: who speaks, and who is asleep")

        do {
            eq(CuddleRoutine.Phase.snuggle.speaker, .left, "the left cat suggests the nap")
            eq(CuddleRoutine.Phase.reply.speaker, .right, "the right one answers")
            eq(CuddleRoutine.Phase.wake.speaker, .left, "and the left one says how it went")
            check(CuddleRoutine.Phase.allCases.filter { $0.speaker != nil }.count == 3,
                  "three lines in the whole nap, so no two bubbles ever share the space")
        }

        do {
            check(CuddleRoutine.Phase.sleep.isAsleep, "they are asleep for the sleeping phase")
            check(CuddleRoutine.Phase.allCases.filter { $0.isAsleep } == [.sleep],
                  "and for no other: a cat that talks in its sleep is a cat still on the walk sheet")
        }

        do {
            check(CuddleRoutine.sleepDuration > CuddleRoutine.snuggleDuration
                  + CuddleRoutine.replyDuration,
                  "the nap is the point of the nap, not the words either side of it")
        }

        section("[M14] Phrasebook: cuddle words")

        do {
            check(!Phrasebook.cuddlePairs.isEmpty, "there are words to say")
            check(Phrasebook.cuddlePairs.allSatisfy { !$0.opener.isEmpty && !$0.reply.isEmpty },
                  "and both halves of every pair have some")
            check(Phrasebook.cuddlePairs.allSatisfy { $0.opener != $0.reply },
                  "an answer is an answer, not the same line said twice")
            check(Phrasebook.cuddlePairs.allSatisfy {
                      !$0.opener.contains(Phrasebook.nameSlot)
                          && !$0.reply.contains(Phrasebook.nameSlot)
                  },
                  "and none of it names anybody: it is said to a cat lying right there")
        }

        do {
            check(!Phrasebook.cuddleWakingLines.isEmpty, "there is something to say on waking")
            check(Phrasebook.cuddleWakingLines.allSatisfy { !$0.isEmpty }, "and it has words")
            check(Phrasebook.cuddleWakingLines.allSatisfy {
                      !$0.contains(Phrasebook.nameSlot)
                  },
                  "which names nobody either")
        }

        section("[M14] The meeting that becomes a nap")

        let left = CGRect(x: 100, y: 0, width: 32, height: 32)
        let touching = CGRect(x: 120, y: 0, width: 32, height: 32)

        /// Run the cooldown out, a bounded step at a time.
        func elapseCooldown(_ coordinator: inout MeetingCoordinator) {
            for _ in 0..<Int(MeetingCoordinator.cooldown) { coordinator.advance(by: 1) }
        }

        do {
            var coordinator = MeetingCoordinator(seed: 9)
            var cuddles = 0
            for _ in 0..<400 {
                elapseCooldown(&coordinator)
                let encounter = coordinator.meet(left, touching, openerName: "Mochi",
                                                 replierName: "Tigre")
                if encounter?.isCuddle == true { cuddles += 1 }
            }
            eq(cuddles, 0, "with napping switched off, four hundred meetings are four hundred chats")
        }

        do {
            var coordinator = MeetingCoordinator(seed: 9)
            var cuddles = 0
            for _ in 0..<400 {
                elapseCooldown(&coordinator)
                let encounter = coordinator.meet(left, touching, openerName: "Mochi",
                                                 replierName: "Tigre", cuddlesAllowed: true)
                if encounter?.isCuddle == true { cuddles += 1 }
            }
            check((30...100).contains(cuddles),
                  "roughly one meeting in seven is a nap, the rest stay conversations",
                  detail: "\(cuddles) of 400")
        }

        do {
            var coordinator = MeetingCoordinator(seed: 9)
            var kisses = 0, cuddles = 0, chats = 0
            for _ in 0..<400 {
                elapseCooldown(&coordinator)
                let encounter = coordinator.meet(left, touching, openerName: "Mochi",
                                                 replierName: "Tigre",
                                                 kissesAllowed: true, cuddlesAllowed: true)
                if encounter?.isKiss == true { kisses += 1 }
                if encounter?.isCuddle == true { cuddles += 1 }
                if encounter?.exchange != nil { chats += 1 }
            }
            check(kisses > 0 && cuddles > 0 && chats > kisses + cuddles,
                  "with both switched on the pair still mostly talks",
                  detail: "\(kisses) kisses, \(cuddles) naps, \(chats) chats")
        }

        do {
            var coordinator = MeetingCoordinator(seed: 9)
            var cuddle: MeetingCoordinator.Encounter?
            for _ in 0..<400 where cuddle == nil {
                elapseCooldown(&coordinator)
                let encounter = coordinator.meet(left, touching, openerName: "Mochi",
                                                 replierName: "Tigre", cuddlesAllowed: true)
                if encounter?.isCuddle == true { cuddle = encounter }
            }
            eq(cuddle?.exchange, nil, "a nap carries no words: the routine says its own")
            eq(cuddle?.isKiss, false, "and it is not a kiss")
        }

        do {
            var a = MeetingCoordinator(seed: 31)
            var b = MeetingCoordinator(seed: 31)
            var same = true
            for _ in 0..<50 {
                elapseCooldown(&a)
                elapseCooldown(&b)
                let one = a.meet(left, touching, openerName: "M", replierName: "T",
                                 kissesAllowed: true, cuddlesAllowed: true)
                let two = b.meet(left, touching, openerName: "M", replierName: "T",
                                 kissesAllowed: true, cuddlesAllowed: true)
                if one != two { same = false }
            }
            check(same, "two coordinators on one seed nap, kiss and chat in the same order")
        }

        do {
            var withNaps = MeetingCoordinator(seed: 44)
            var without = MeetingCoordinator(seed: 44)
            var same = true
            for _ in 0..<50 {
                elapseCooldown(&withNaps)
                elapseCooldown(&without)
                let one = withNaps.meet(left, touching, openerName: "M", replierName: "T",
                                        cuddlesAllowed: false)
                let two = without.meet(left, touching, openerName: "M", replierName: "T")
                if one != two { same = false }
            }
            check(same, "and switching napping off leaves the conversations a seed produces alone")
        }

        section("[M14] Occupancy: a sleeping pair")

        do {
            check(PetActivity.cuddle > PetActivity.meeting,
                  "a nap outranks the chat, so nobody strikes up a conversation over it")
            check(PetActivity.cuddle > PetActivity.napSpot,
                  "and outranks a cat's own trip to a Dock tile")
            check(PetActivity.cuddle > PetActivity.reacting,
                  "and a remark about an app")
            check(PetActivity.cuddle < PetActivity.talking,
                  "a hand reaching for a cat beats a nap")
            check(PetActivity.cuddle < PetActivity.petted, "so does petting one")
            check(PetActivity.cuddle < PetActivity.kiss, "the kiss runs to completion over it")
            check(PetActivity.cuddle < PetActivity.scene, "and so does her birthday")
        }

        do {
            var occupancy = PetOccupancy(petCount: 2)
            check(occupancy.claim(.cuddle, pets: [0, 1]), "a free pair may go and nap")
            check(!occupancy.isAvailable(0, for: .meeting),
                  "and is not available to talk while it does")
            check(occupancy.isAvailable(1, for: .talking), "but is still available to be clicked")
            occupancy.release(.cuddle, pets: [0, 1])
            check(occupancy.activity(of: 0) == nil, "and both cats are handed back at the end")
        }

        do {
            var occupancy = PetOccupancy(petCount: 2)
            occupancy.claim(.talking, pets: [1])
            check(!occupancy.claim(.cuddle, pets: [0, 1]),
                  "a nap is all or nothing: one cat mid-sentence refuses the whole thing")
            check(occupancy.activity(of: 0) == nil,
                  "and the other cat is left alone rather than walked to a nap on its own")
        }

        section("[M14] config: the napping toggle")

        func decode(_ json: String) -> PetConfig? {
            try? JSONDecoder().decode(PetConfig.self, from: Data(json.utf8))
        }

        eq(PetConfig.default.cuddles, true,
           "cats nap together by default: a feature switched off by default is one nobody finds")
        eq(decode("{}")?.cuddles, true,
           "and a config written before M14 gets the default rather than nothing")
        eq(decode(#"{"cuddles":false}"#)?.cuddles, false, "turning it off decodes")

        do {
            let off = PetConfig(cuddles: false)
            guard let data = try? JSONEncoder().encode(off),
                  let back = try? JSONDecoder().decode(PetConfig.self, from: data) else {
                Harness.bail("a config with napping off should round-trip through JSON")
            }
            eq(back.cuddles, false, "and survives being written to disk and read back")
        }

        do {
            let validated = PetConfig(cuddles: false).validated()
            eq(validated.config.cuddles, false, "validation leaves the toggle where the user put it")
            check(validated.corrections.isEmpty, "and has nothing to correct about a Bool")
        }
    }
}

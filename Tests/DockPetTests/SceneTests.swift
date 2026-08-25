//
//  SceneTests.swift: [M13] the birthday scene, which happens once a year and cannot be
//  rehearsed by waiting for the date.
//
//  SPEC §9: this is nine seconds of screen that nobody reading this can watch, on a day
//  that comes round once. Every part of it that can be checked without a screen is checked
//  here. "It looked lovely on the morning" is not a check, and by then it is too late.
//

import Foundation
import CoreGraphics
import DockPetCore

enum SceneTests {

    static func run() {
        section("[M13] BirthdayScene: the phase order")

        do {
            let scene = BirthdayScene()
            eq(scene.phase, .approach, "a scene opens with the two cats walking to each other")
            eq(scene.isFinished, false, "and is not over before it starts")
        }

        do {
            // Driven by elapsed time rather than by a clock, exactly as KissRoutine is, so
            // the whole nine seconds runs in a test in no time at all.
            var scene = BirthdayScene()
            scene.arrive()
            eq(scene.phase, .gather, "arriving ends the approach")

            var seen: [BirthdayScene.Phase] = [scene.phase]
            for _ in 0..<400 {
                let previous = scene.phase
                scene.advance(by: 0.1)
                if scene.phase != previous { seen.append(scene.phase) }
                if scene.isFinished { break }
            }
            eq(seen, [.gather, .announce, .celebrate, .wish, .part, .done],
               "and the rest runs in order, once each, to done")
        }

        do {
            var scene = BirthdayScene()
            scene.arrive()
            var elapsed: TimeInterval = 0
            while !scene.isFinished && elapsed < 60 {
                scene.advance(by: 0.1)
                elapsed += 0.1
            }
            check(scene.isFinished, "the scene always ends")
            check(elapsed > 6 && elapsed < 20,
                  "and lasts long enough to be a moment without becoming a hostage situation",
                  detail: "took \(elapsed)s")
        }

        section("[M13] BirthdayScene: it cannot get stuck")

        do {
            var scene = BirthdayScene()
            // The Dock moved, the strip shrank, a cat cannot reach the middle. The kiss
            // has the same failure and the same answer (KissRoutine.approachCeiling): give
            // up rather than leave two cats walking at a point that no longer exists.
            //
            // Stepped rather than jumped, because the step is bounded: one enormous tick
            // adds one bounded step, not eleven seconds. That is the same guarantee the
            // stampede check below relies on, tested from the other side.
            var elapsed: TimeInterval = 0
            while !scene.isFinished && elapsed < 30 {
                scene.advance(by: 0.5)
                elapsed += 0.5
            }
            eq(scene.phase, .done, "an approach that never arrives is abandoned, not retried")
            check(scene.isFinished, "and the scene reports itself over so the cats are released")
            check(scene.wasAbandoned, "and says it was abandoned, so the log can explain it")
            check(elapsed >= BirthdayScene.approachCeiling,
                  "and not before the ceiling it is waiting on", detail: "gave up after \(elapsed)s")
        }

        do {
            var scene = BirthdayScene()
            scene.arrive()
            var elapsed: TimeInterval = 0
            while !scene.isFinished && elapsed < 60 {
                scene.advance(by: 0.1)
                elapsed += 0.1
            }
            check(!scene.wasAbandoned,
                  "the ceiling applies only to the approach, not to the rest of the scene")
        }

        do {
            var scene = BirthdayScene()
            scene.arrive()
            // A stalled process (display sleep, a long menu tracking loop) hands back a
            // huge elapsed time on the next tick. Every other clock in this app bounds its
            // step for exactly this reason; a scene that burned all six phases in one tick
            // would show her nothing at all.
            scene.advance(by: 90)
            check(scene.phase != .done,
                  "one enormous tick does not stampede through the whole scene",
                  detail: "landed on \(scene.phase.rawValue)")
        }

        do {
            var scene = BirthdayScene()
            scene.arrive()
            let before = scene.phase
            scene.advance(by: -5)
            eq(scene.phase, before, "time does not run backwards")
            scene.advance(by: 0)
            eq(scene.phase, before, "and a zero step changes nothing")
        }

        section("[M13] BirthdayScene: arriving")

        do {
            var scene = BirthdayScene()
            scene.arrive()
            scene.arrive()
            eq(scene.phase, .gather,
               "arriving twice is harmless: the pair touches for several consecutive ticks")
        }

        do {
            var scene = BirthdayScene()
            scene.arrive()
            while scene.phase == .gather { scene.advance(by: 0.1) }
            let mid = scene.phase
            scene.arrive()
            eq(scene.phase, mid, "and arriving late, past the approach, is ignored entirely")
        }

        section("[M13] BirthdayScene: which cat speaks, and when things appear")

        do {
            // The pair is settled once, at the start, for the reason the kiss settles it:
            // during the approach the cats cross and re-cross, and reading "who is on the
            // left" per frame moves the line from one cat to the other mid-sentence.
            check(BirthdayScene.Phase.announce.speaker == .left,
                  "the left cat gives the birthday line")
            check(BirthdayScene.Phase.wish.speaker == .right,
                  "and the other one answers, so it reads as the pair rather than a monologue")
            eq(BirthdayScene.Phase.celebrate.speaker, nil,
               "nobody talks over the confetti")
            eq(BirthdayScene.Phase.approach.speaker, nil, "and nobody talks on the way there")
        }

        do {
            check(BirthdayScene.Phase.celebrate.showsConfetti,
                  "confetti belongs to the celebrate phase")
            check(BirthdayScene.Phase.celebrate.showsHearts,
                  "and the hearts rise with it rather than after it")
            check(!BirthdayScene.Phase.announce.showsConfetti,
                  "nothing falls before she has been told why")
            check(!BirthdayScene.Phase.done.showsConfetti,
                  "and nothing is left on screen once the scene is over")
            check(!BirthdayScene.Phase.done.showsHearts, "including the hearts")
        }

        section("[M13] BirthdayScene: the once-a-day gate")

        do {
            let day = Occasion.dayStamp(Date())
            check(BirthdayScene.shouldRun(isBirthday: true, lastRunDay: nil, today: day),
                  "on the birthday, having never run, the scene runs")
            check(!BirthdayScene.shouldRun(isBirthday: true, lastRunDay: day, today: day),
                  "and does not run a second time the same day")
            check(!BirthdayScene.shouldRun(isBirthday: false, lastRunDay: nil, today: day),
                  "and never runs on an ordinary day, however long since it last did")
            check(BirthdayScene.shouldRun(isBirthday: true, lastRunDay: "2025-08-27", today: day),
                  "last year's run does not count as this year's")
        }
    }
}

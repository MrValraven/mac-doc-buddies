//
//  PurrTests.swift. [M13] Press-and-hold to pet the cat: what a press of a given length
//  means, and what the purr indicator says while it lasts.
//
//  SPEC §9: none of this can be watched from here, and the one thing that must not break
//  is the interaction the whole app already has: a quick click still opens the prompt
//  menu. That is a decision made from a single number, so it is checked here across the
//  whole range either side of the threshold rather than at the one value it is easy to
//  eyeball.
//

import Foundation
import DockPetCore

enum PurrTests {

    static func run() {
        section("[M13] Purr: the hold threshold")

        do {
            // The two failure modes the number sits between. Below ~0.2 s an ordinary
            // click starts petting the cat (a slow click is a real thing: the tail of
            // human click durations reaches well past 200 ms); at or above 0.5 s the cat
            // ignores a deliberate press for half a second with nothing on screen saying
            // why, on an interaction nobody was told about.
            check(Purr.holdThreshold > 0.2,
                  "the threshold is past the tail of ordinary click durations",
                  detail: "got \(Purr.holdThreshold)")
            check(Purr.holdThreshold < 0.5,
                  "and short enough that the hold does not feel unresponsive",
                  detail: "got \(Purr.holdThreshold)")
        }

        do {
            eq(Purr.press(heldFor: 0), Purr.Press.deciding,
               "the instant of the press decides nothing")
            eq(Purr.press(heldFor: -1), Purr.Press.deciding,
               "and a clock that ran backwards decides nothing either")
            eq(Purr.press(heldFor: Purr.holdThreshold - 0.001), Purr.Press.deciding,
               "a hair under the threshold is still a click in progress")
            eq(Purr.press(heldFor: Purr.holdThreshold), Purr.Press.purring,
               "the threshold itself is a hold")
            eq(Purr.press(heldFor: 30), Purr.Press.purring,
               "and so is half a minute of it")
        }

        section("[M13] Purr: releasing, and the quick click that still opens the menu")

        do {
            // The requirement this feature is most able to break. Swept rather than
            // sampled: every press shorter than the threshold that ends on the cat must
            // reach the menu, or the app has lost its only interaction.
            var menu = 0
            var steps = 0
            var t = 0.0
            while t < Purr.holdThreshold {
                steps += 1
                if Purr.release(after: t, overPet: true) == .menu { menu += 1 }
                t += 0.005
            }
            check(steps > 50, "the sweep actually covered the sub-threshold range",
                  detail: "\(steps) samples")
            eq(menu, steps, "every sub-threshold release over the cat opens the menu")
        }

        do {
            // The other half of the same requirement: once it has become a hold, the menu
            // must not also open when the finger comes up.
            var menus = 0
            var steps = 0
            var t = Purr.holdThreshold
            while t < Purr.holdThreshold + 10 {
                steps += 1
                if Purr.release(after: t, overPet: true) == .menu { menus += 1 }
                if Purr.release(after: t, overPet: false) == .menu { menus += 1 }
                t += 0.01
            }
            check(steps > 500, "the sweep actually covered ten seconds of holding",
                  detail: "\(steps) samples")
            eq(menus, 0, "no release after the threshold ever opens the menu")
        }

        do {
            eq(Purr.release(after: Purr.holdThreshold, overPet: true), Purr.Release.endPurr,
               "a hold released on the cat ends the purr")
            eq(Purr.release(after: Purr.holdThreshold, overPet: false), Purr.Release.endPurr,
               "and so does one released after the pointer left it")
            eq(Purr.release(after: 0.05, overPet: false), Purr.Release.nothing,
               "a quick press dragged off the cat is neither a menu nor a purr")
            eq(Purr.release(after: -1, overPet: true), Purr.Release.menu,
               "a clock that ran backwards is still a click, not a hold")
        }

        section("[M13] Purr: the indicator over time")

        do {
            eq(Purr.indicator(heldFor: 0), nil,
               "nothing is shown while the press is still deciding")
            eq(Purr.indicator(heldFor: Purr.holdThreshold - 0.001), nil,
               "not even a hair before the threshold: a click must leave no trace")
            eq(Purr.indicator(heldFor: Purr.holdThreshold), Purr.glyph,
               "the purr opens with a single glyph, the moment it starts")
        }

        do {
            let start = Purr.holdThreshold
            eq(Purr.indicator(heldFor: start + Purr.beat * 0.5), Purr.glyph,
               "which holds for its whole beat rather than flickering per frame")
            eq(Purr.indicator(heldFor: start + Purr.beat),
               [Purr.glyph, Purr.glyph].joined(separator: " "),
               "the second beat adds a second glyph")
            eq(Purr.indicator(heldFor: start + Purr.beat * 2),
               [Purr.glyph, Purr.glyph, Purr.glyph].joined(separator: " "),
               "the third fills the indicator")
            eq(Purr.indicator(heldFor: start + Purr.beat * 3), Purr.glyph,
               "and the fourth wraps back to one, because a purr is a cycle, not a countdown")
        }

        do {
            // A hold has no upper bound: someone can rest a finger on the cat for a
            // minute. The content must stay inside its own limits for as long as they do,
            // because the bubble is sized from this string.
            var t = Purr.holdThreshold
            var widest = 0
            var blanks = 0
            while t < 120 {
                guard let text = Purr.indicator(heldFor: t) else {
                    blanks += 1
                    t += 0.037
                    continue
                }
                let glyphs = text.components(separatedBy: " ").count
                widest = max(widest, glyphs)
                if glyphs < 1 { blanks += 1 }
                t += 0.037
            }
            eq(blanks, 0, "two minutes of petting never leaves the indicator empty")
            eq(widest, Purr.maximumGlyphs, "and never wider than the cycle it repeats")
        }

        do {
            check(Purr.glyph != "💕",
                  "the purr glyph is not the kiss's heart: contentment, not romance",
                  detail: "got \(Purr.glyph)")
            check(!Purr.glyph.isEmpty, "and it is something rather than nothing")
            check(Purr.beat > 0.15 && Purr.beat < 1.2,
                  "the beat is a purr's rhythm, not a strobe and not a stall",
                  detail: "got \(Purr.beat)")
            check(Purr.maximumGlyphs >= 2,
                  "a cycle needs somewhere to go", detail: "got \(Purr.maximumGlyphs)")
        }
    }
}

//
//  ConfettiTests.swift: [M13] the birthday confetti. Where every piece is, how solid it
//  is, which way round it is, and what colour.
//
//  SPEC §9 again: a burst lasts two and a half seconds on a screen nobody reviewing this
//  can watch, and "it looked festive" is not a check. Everything the fall can get wrong in
//  a way that would never be noticed (a piece that never fades, twenty-four pieces moving
//  as one block, a rectangle that stays axis-aligned and reads as a falling bar chart, a
//  burst that is different every time it runs and so cannot be reproduced from a bug
//  report) is checked here instead.
//

import Foundation
import CoreGraphics
import DockPetCore

enum ConfettiTests {

    /// The metrics every case below is scaled by. Chosen to make the arithmetic legible:
    /// the fall is 200 pt, so a piece is at +100 when it starts and -100 when it lands.
    private static let spread: CGFloat = 60
    private static let fall: CGFloat = 200
    private static let drift: CGFloat = 24
    private static let seed: UInt64 = 4242

    private static func pieces(_ progress: Double, seed: UInt64 = seed) -> [ConfettiDrift.Piece] {
        ConfettiDrift.pieces(progress: progress, seed: seed,
                             spread: spread, fall: fall, drift: drift)
    }

    static func run() {
        section("[M13] ConfettiDrift: the constants the fall is built from")

        do {
            check(ConfettiDrift.count > 0, "there is confetti at all")
            check(ConfettiDrift.duration > 0, "and the burst lasts a measurable time")
            check(ConfettiDrift.stagger * Double(ConfettiDrift.count - 1) < 1,
                  "the last piece launches before the burst ends, rather than never falling",
                  detail: "last launch at \(ConfettiDrift.stagger * Double(ConfettiDrift.count - 1))")
            check(ConfettiDrift.palette.count > 1,
                  "and there is more than one colour, or it is not confetti")
            check(Set(ConfettiDrift.palette).count == ConfettiDrift.palette.count,
                  "no colour is listed twice, since a duplicate silently doubles its odds")
        }

        section("[M13] ConfettiDrift: pieces fall past the pair")

        do {
            eq(pieces(0.5).count, ConfettiDrift.count, "the drift draws every piece, every frame")
        }

        do {
            let start = pieces(0)
            check(start.allSatisfy { $0.offset.y > 0 },
                  "every piece is above the cats on the frame the burst starts")
            eq(start[0].offset.y, fall / 2, "at the top of its own fall")
            check(start.allSatisfy { $0.alpha == 0 },
                  "and nothing is painted yet")
        }

        do {
            let end = pieces(1)
            check(end.allSatisfy { $0.offset.y < 0 },
                  "every piece is below the cats when the burst ends, because confetti falls")
            eq(end[0].offset.y, -fall / 2, "having covered the whole fall it was given")
            check(end.allSatisfy { $0.alpha == 0 },
                  "and nothing is left painted on the Dock afterwards")
        }

        do {
            let early = pieces(0.35)[0]
            let late = pieces(0.75)[0]
            check(late.offset.y < early.offset.y, "a piece falls rather than hovers")
            check(early.offset.y < fall / 2, "having left the top it started at")
        }

        do {
            var monotone = true
            var previous = [CGFloat](repeating: fall, count: ConfettiDrift.count)
            for step in 0...50 {
                let frame = pieces(Double(step) / 50)
                for (index, piece) in frame.enumerated() {
                    if piece.offset.y > previous[index] + 0.001 { monotone = false }
                    previous[index] = piece.offset.y
                }
            }
            check(monotone, "no piece ever goes back up, because confetti does not bounce")
        }

        do {
            var withinFall = true
            var withinWidth = true
            for step in -10...110 {
                for piece in pieces(Double(step) / 100) {
                    if abs(piece.offset.y) > fall / 2 + 0.001 { withinFall = false }
                    if abs(piece.offset.x) > spread + drift + 0.001 { withinWidth = false }
                }
            }
            check(withinFall, "no piece falls further than the fall it was handed")
            check(withinWidth,
                  "and none drifts past the spread it started in plus the drift it was allowed")
        }

        section("[M13] ConfettiDrift: a shower, not a curtain")

        do {
            let mid = pieces(0.5)
            check(Set(mid.map { $0.offset.x }).count > 1,
                  "the pieces are scattered sideways rather than stacked in one column")
            check(mid.contains { $0.offset.x < 0 } && mid.contains { $0.offset.x > 0 },
                  "and they fall either side of the pair, not down one flank of it")
        }

        do {
            let early = pieces(0.05)
            check(early[ConfettiDrift.count - 1].alpha == 0,
                  "the last piece has not launched yet, because they are staggered, not one dump")
            eq(early[ConfettiDrift.count - 1].offset.y, fall / 2,
               "and it is still waiting at the top")
            check(early[0].alpha > 0, "while the first piece is already falling")
        }

        do {
            let mid = pieces(0.5)
            check(Set(mid.map { $0.offset.y }).count > 1,
                  "at any one moment the pieces are at different heights, not one falling block")
        }

        do {
            var everyPieceIsSeen = true
            for index in 0..<ConfettiDrift.count {
                var seen = false
                for step in 0...100 where pieces(Double(step) / 100)[index].alpha > 0 {
                    seen = true
                }
                if !seen { everyPieceIsSeen = false }
            }
            check(everyPieceIsSeen, "every piece is visible at some point in the burst")
        }

        do {
            var alphasSane = true
            var sawFullStrength = false
            for step in 0...100 {
                for piece in pieces(Double(step) / 100) {
                    if piece.alpha < 0 || piece.alpha > 1 { alphasSane = false }
                    if piece.alpha >= 1 { sawFullStrength = true }
                }
            }
            check(alphasSane, "alpha stays inside 0…1 for the whole fall")
            check(sawFullStrength, "and reaches full strength in the middle of it")
        }

        section("[M13] ConfettiDrift: tumbling, so rectangles are not a falling bar chart")

        do {
            let early = pieces(0.3)
            let late = pieces(0.6)
            check(zip(early, late).allSatisfy { $0.rotation != $1.rotation },
                  "every piece turns as it falls")
            check(Set(late.map { $0.rotation }).count > 1,
                  "and they do not all turn together, which would read as one rigid sheet")
        }

        do {
            let start = pieces(0)
            check(Set(start.map { $0.rotation }).count > 1,
                  "they do not even start aligned, since an axis-aligned row is a bar chart")
        }

        section("[M13] ConfettiDrift: colours")

        do {
            let mid = pieces(0.5)
            check(mid.allSatisfy { ConfettiDrift.palette.indices.contains($0.colorIndex) },
                  "every colour index addresses a colour that exists")
            check(Set(mid.map { $0.colorIndex }).count > 1,
                  "and a burst is not twenty-four pieces of the same colour")
        }

        do {
            let a = pieces(0.5)
            let b = pieces(0.9)
            check(zip(a, b).allSatisfy { $0.colorIndex == $1.colorIndex },
                  "a piece keeps its colour for the whole fall rather than flickering")
        }

        section("[M13] ConfettiDrift: a seed reproduces a burst exactly")

        do {
            var identical = true
            for step in 0...40 {
                let progress = Double(step) / 40
                if pieces(progress, seed: 99) != pieces(progress, seed: 99) { identical = false }
            }
            check(identical, "one seed asked twice gives the same burst, frame for frame")
        }

        do {
            check(pieces(0.5, seed: 1) != pieces(0.5, seed: 2),
                  "and two seeds give two different bursts, or the seed does nothing")
        }

        section("[M13] ConfettiDrift: progress from a stalled clock")

        do {
            check(pieces(4) == pieces(1),
                  "a progress past the end is the end, not confetti through the floor")
            check(pieces(-2) == pieces(0),
                  "and a negative one is the start, not confetti above the menu bar")
        }
    }
}

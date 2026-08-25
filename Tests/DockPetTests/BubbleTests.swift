//
//  BubbleTests.swift — assertions for DockPetCore.BubbleGeometry (M10, click-to-interact)
//
//  The bubble hangs above a pet that walks the full width of the Dock, so it spends a lot
//  of its life near a screen edge. Everything worth checking here is about what happens
//  when the pet is somewhere the bubble cannot simply be centred over.
//

import Foundation
import CoreGraphics
import DockPetCore

enum BubbleTests {

    /// A 1512x944 visible frame with the pet on the Dock at the bottom, as in PROBE.md Run 1.
    private static let visible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private static let bubble = CGSize(width: 200, height: 60)

    private static func pet(atX x: CGFloat) -> CGRect {
        CGRect(x: x, y: 0, width: 64, height: 64)
    }

    static func run() {

        section("bubble: placement")

        let middle = BubbleGeometry.frame(size: bubble, above: pet(atX: 700),
                                          within: visible, gap: 6)
        eq(middle.midX, pet(atX: 700).midX, "a bubble in open space is centred over the pet")
        eq(middle.minY, 70, "and sits a gap above the pet's head")
        eq(middle.size.width, bubble.width, "the size it was given is the size it gets")
        eq(middle.size.height, bubble.height, "in both axes")

        section("bubble: screen edges")

        let left = BubbleGeometry.frame(size: bubble, above: pet(atX: 0), within: visible, gap: 6)
        check(left.minX >= visible.minX,
              "a pet at the left edge does not push the bubble off-screen",
              detail: "minX=\(left.minX)")
        check(left.minX >= visible.minX + BubbleGeometry.screenMargin - 0.001,
              "it keeps a margin from the edge rather than touching it")

        let right = BubbleGeometry.frame(size: bubble, above: pet(atX: visible.maxX - 64),
                                         within: visible, gap: 6)
        check(right.maxX <= visible.maxX,
              "and neither does a pet at the right edge", detail: "maxX=\(right.maxX)")
        check(right.maxX <= visible.maxX - BubbleGeometry.screenMargin + 0.001,
              "with the same margin on that side")

        // A bubble wider than the screen has nothing valid to clamp to; it should sit
        // inside the screen rather than being centred half off each side.
        let huge = BubbleGeometry.frame(size: CGSize(width: 4000, height: 60),
                                        above: pet(atX: 700), within: visible, gap: 6)
        eq(huge.minX, visible.minX, "a bubble too wide to fit starts at the screen's edge")

        section("bubble: the top of the screen")

        // A tall pet near the top of a short screen must not put the bubble over the menu bar.
        let tall = CGRect(x: 700, y: 900, width: 64, height: 64)
        let capped = BubbleGeometry.frame(size: bubble, above: tall, within: visible, gap: 6)
        check(capped.maxY <= visible.maxY,
              "the bubble is pushed down rather than drawn over the menu bar",
              detail: "maxY=\(capped.maxY) vs \(visible.maxY)")

        section("bubble: the tail")

        // The tail is what makes the bubble belong to the pet, so it tracks the pet even
        // when the body has been shoved sideways to stay on screen.
        eq(BubbleGeometry.tailCenterX(in: middle, pointingAt: pet(atX: 700)),
           bubble.width / 2, "the tail is centred when the bubble is")

        let tail = BubbleGeometry.tailCenterX(in: left, pointingAt: pet(atX: 0))
        check(tail < bubble.width / 2,
              "a shoved bubble points its tail back towards the pet", detail: "\(tail)")
        check(tail >= BubbleGeometry.tailInset,
              "but never so far that the tail leaves the bubble's own edge", detail: "\(tail)")

        let farTail = BubbleGeometry.tailCenterX(in: right, pointingAt: pet(atX: visible.maxX - 64))
        check(farTail <= bubble.width - BubbleGeometry.tailInset,
              "and the same on the other side", detail: "\(farTail)")

        // A pet that has walked out from under its own bubble entirely.
        let stray = BubbleGeometry.tailCenterX(in: middle, pointingAt: pet(atX: 0))
        check(stray >= BubbleGeometry.tailInset && stray <= bubble.width - BubbleGeometry.tailInset,
              "a pet nowhere near the bubble still gets a tail inside it", detail: "\(stray)")

        section("bubble: how long it stays up")

        let short = BubbleGeometry.readingTime(for: "Hi!")
        let long = BubbleGeometry.readingTime(for: String(repeating: "word ", count: 40))
        check(long > short, "a longer line stays up longer")
        check(short >= 1.5, "even a short line stays up long enough to read",
              detail: "\(short)s")
        check(long <= 12, "and a long one does not camp on the screen", detail: "\(long)s")
        check(BubbleGeometry.readingTime(for: "") >= 1.5,
              "an empty line does not vanish instantly")
    }
}

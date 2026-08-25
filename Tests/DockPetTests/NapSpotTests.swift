//
//  NapSpotTests.swift: the cat naps on a Dock icon. Picking a tile, converting it to a
//  distance along the strip, and the trip out to it.
//
//  SPEC §9. "A cat asleep on the Spotify icon" is a claim about pixels on a screen nobody
//  reviewing this can see, so it is restated here as arithmetic: feed the chosen distance
//  back through `Geometry.petFrame` and assert the rect actually covers the tile. That
//  round trip is the whole feature, and everything else here guards its edges.
//
//  Fixtures are the measured Run 6 numbers from PROBE.md F7 wherever they can be, for the
//  same reason `GeometryTests` uses them: a failure should mean a real disagreement with
//  the machine, not with a number somebody invented.
//

import Foundation
import CoreGraphics
import DockPetCore

// MARK: - Fixtures

private enum Measured {
    static let primaryFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

    /// Run 1: Dock at the bottom, tilesize 54.
    static let dockBottom = ScreenGeometry(
        frame: primaryFrame,
        visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 869))

    /// Run 2: the same screen with the Dock moved to the left edge.
    static let dockLeft = ScreenGeometry(
        frame: primaryFrame,
        visibleFrame: CGRect(x: 80, y: 0, width: 1432, height: 949))

    /// PROBE.md F7, Run 6: 14 dock items spanning `381.9..1130.1`, being 12 tiles at 58 pt
    /// and 2 separators at 26.1 pt, laid out contiguously (12*58 + 2*26.1 = 748.2, which is
    /// exactly the measured union width, so the items leave no gaps between them).
    ///
    /// The separators sit where a real Dock puts them, after the pinned apps and again
    /// before the trash, because they are dock items like any other and the feature is
    /// allowed to nap on one. That is not a bug: a separator is 26 pt of Dock, and a cat
    /// asleep across it still reads as a cat asleep on the Dock.
    static let tileWidths: [CGFloat] =
        Array(repeating: 58, count: 10) + [26.1, 58, 26.1, 58]

    static let tilesBottom: [CGRect] = {
        var x: CGFloat = 381.9
        return tileWidths.map { width in
            defer { x += width }
            return CGRect(x: x, y: 10, width: width, height: 74)
        }
    }()

    /// The union those items produce: what `DockTiles.measure` returns, and what
    /// `Geometry.walkStrip` narrows the strip to.
    static let tileUnion = CGRect(x: 381.9, y: 10, width: 748.2, height: 74)

    /// The same 14 items rotated onto a left-hand Dock: same sizes, stacked upward from the
    /// bottom. Used only to prove the conversion follows the strip's axis.
    static let tilesLeft: [CGRect] = {
        var y: CGFloat = 949 - 748.2
        return tileWidths.map { height in
            defer { y += height }
            return CGRect(x: 10, y: y, width: 74, height: height)
        }
    }()

    static let tileUnionLeft = CGRect(x: 10, y: 949 - 748.2, width: 74, height: 748.2)
}

/// The pet as the app sizes it: a 32 pt sprite at 2x (SPEC §5).
private let petSize = CGSize(width: 50, height: 50)

/// A deliberately oversized cat, used for the clamp cases. At 50 pt wide every tile in the
/// measured Dock is reachable, so the clamp would never fire and the tests that matter most
/// would be the ones never exercised.
private let wideCat = CGSize(width: 100, height: 100)

private func bottomStrip(tiles: CGRect? = Measured.tileUnion) -> WalkStrip {
    guard let strip = Geometry.walkStrip(on: Measured.dockBottom, tiles: tiles) else {
        Harness.bail("fixture: the measured bottom Dock must produce a strip")
    }
    return strip
}

enum NapSpotTests {

    static func run() {
        roundTrip()
        clamping()
        degenerate()
        determinism()
        trip()
        endToEnd()
    }

    // MARK: - The round trip

    private static func roundTrip() {
        section("[M13] NapSpot: a tile rect becomes a distance along the strip")

        let strip = bottomStrip()
        eq(strip.start, 381.9, "fixture: the strip starts at the measured tile union")
        eq(strip.end, 1130.1, "fixture: and ends there too")

        // The claim the whole feature rests on: for every tile in the measured Dock, the
        // distance NapSpot returns puts the pet's frame centred over that tile.
        var allCentred = true
        var allCovered = true
        for tile in Measured.tilesBottom {
            let d = NapSpot.distance(centring: petSize, on: tile, along: strip)
            let frame = Geometry.petFrame(size: petSize, on: strip, distance: d)
            if abs(frame.midX - tile.midX) >= 0.001 { allCentred = false }
            if !tile.intersects(frame) { allCovered = false }
        }
        check(allCentred, "every measured tile: petFrame(distance).midX == tile.midX")
        check(allCovered, "every measured tile: the pet's frame lands on the tile")

        // Spelled out once with real numbers, so a regression says *which* way it drifted
        // rather than only that something moved.
        let seventh = Measured.tilesBottom[6]
        eq(seventh.midX, 381.9 + 6 * 58 + 29, "fixture: tile 6 is centred at 758.9")
        eq(NapSpot.distance(centring: petSize, on: seventh, along: strip),
           758.9 - 25 - 381.9,
           "distance = tile.midX - half the pet - strip.start")

        // A vertical strip converts on the other axis. The app never walks one (SPEC §4b
        // [M6], `.horizontalOnly`), but the geometry is implemented and a nap spot that
        // silently used x on a left-hand Dock would be a trap for whoever turns it on.
        guard let left = Geometry.walkStrip(on: Measured.dockLeft,
                                            policy: .anyEdge,
                                            tiles: Measured.tileUnionLeft) else {
            Harness.bail("fixture: the left Dock must produce a vertical strip")
        }
        var verticalCentred = true
        for tile in Measured.tilesLeft {
            let d = NapSpot.distance(centring: petSize, on: tile, along: left)
            let frame = Geometry.petFrame(size: petSize, on: left, distance: d)
            if abs(frame.midY - tile.midY) >= 0.001 { verticalCentred = false }
        }
        check(verticalCentred, "a vertical strip centres on tile.midY, not midX")
    }

    // MARK: - Clamping to the strip

    private static func clamping() {
        section("[M13] NapSpot: tiles the pet cannot centre on")

        let strip = bottomStrip()
        let maximum = Geometry.maximumDistance(for: wideCat, on: strip)
        eq(maximum, 748.2 - 100, "fixture: a 100 pt cat has 648.2 pt of room")

        // First tile, wide cat: centring it would need distance -21, which is not a place
        // on the strip.
        let first = Measured.tilesBottom[0]
        let near = NapSpot.distance(centring: wideCat, on: first, along: strip)
        eq(near, 0, "a tile at the near end clamps to distance 0, never negative")
        let nearFrame = Geometry.petFrame(size: wideCat, on: strip, distance: near)
        eq(nearFrame.minX, strip.start, "the pet parks against the near end of the strip")
        check(nearFrame.intersects(first),
              "and still lands on the tile it was aiming at, just not centred")

        // Last tile, same cat: centring needs 669.2 against a maximum of 648.2.
        let last = Measured.tilesBottom[Measured.tilesBottom.count - 1]
        let far = NapSpot.distance(centring: wideCat, on: last, along: strip)
        eq(far, maximum, "a tile at the far end clamps to the maximum distance")
        let farFrame = Geometry.petFrame(size: wideCat, on: strip, distance: far)
        eq(farFrame.maxX, strip.end, "the pet parks against the far end of the strip")
        check(farFrame.intersects(last), "and still lands on the last tile")

        // The clamp is NapSpot's own, not something it leaves to petFrame: a caller that
        // hands the distance to `Walker.walk(toward:)` never calls `petFrame` on it.
        check(near >= 0 && far <= maximum,
              "every distance NapSpot returns is inside 0...maximumDistance")
    }

    // MARK: - Nothing to nap on

    private static func degenerate() {
        section("[M13] NapSpot: no tiles, and no room")

        var rng = SplitMix64(seed: 1)
        eq(NapSpot.choose(from: [], petSize: petSize, on: bottomStrip(), using: &rng) == nil,
           true,
           "no tiles at all yields no spot, so the caller falls back to sleeping in place")

        // An ungranted app measures no tiles, so the strip is the [M0] full width. There is
        // nothing to nap *on*, and the answer must still be "nowhere in particular".
        var rng2 = SplitMix64(seed: 1)
        eq(NapSpot.choose(from: [], petSize: petSize,
                          on: bottomStrip(tiles: nil), using: &rng2) == nil,
           true,
           "an unmeasured Dock yields no spot on the full-width strip either")

        // A strip with no walkable room: a cat wider than the Dock's tiles.
        let strip = bottomStrip()
        let hugeCat = CGSize(width: 900, height: 50)
        eq(Geometry.maximumDistance(for: hugeCat, on: strip), 0,
           "fixture: a 900 pt cat has no room on a 748.2 pt strip")
        var rng3 = SplitMix64(seed: 7)
        guard let spot = NapSpot.choose(from: Measured.tilesBottom, petSize: hugeCat,
                                        on: strip, using: &rng3) else {
            Harness.bail("a strip with no room must still yield a spot, at distance 0")
        }
        eq(spot.distance, 0, "with no room to walk, the only distance that exists is 0")

        // A zero-length strip is the same question with the strip degenerate instead of the
        // cat, and it must not divide by anything.
        let empty = WalkStrip(edge: .bottom, baseline: 80, start: 500, end: 500)
        eq(NapSpot.distance(centring: petSize, on: Measured.tilesBottom[3], along: empty), 0,
           "a zero-length strip has exactly one distance, and it is 0")
    }

    // MARK: - Determinism (SPEC §9)

    private static func determinism() {
        section("[M13] NapSpot: the same seed picks the same tile")

        let strip = bottomStrip()

        func firstPick(seed: UInt64) -> Int? {
            var rng = SplitMix64(seed: seed)
            return NapSpot.choose(from: Measured.tilesBottom, petSize: petSize,
                                  on: strip, using: &rng)?.index
        }

        eq(firstPick(seed: 0x5EED), firstPick(seed: 0x5EED),
           "one seed, one set of tiles, the same tile every time")

        // The chosen index has to actually address the tile it came back with, or the
        // verbose log would name one icon while the cat naps on another.
        var rng = SplitMix64(seed: 0x5EED)
        guard let spot = NapSpot.choose(from: Measured.tilesBottom, petSize: petSize,
                                        on: strip, using: &rng) else {
            Harness.bail("the measured Dock must yield a spot")
        }
        eq(spot.tile, Measured.tilesBottom[spot.index], "spot.index addresses spot.tile")
        check(spot.index >= 0 && spot.index < Measured.tilesBottom.count,
              "the index is inside the tile array")

        // Variety is the entire reason this is random rather than configured (see the
        // header of NapSpot.swift). One seed drawing many naps must reach many tiles.
        var stream = SplitMix64(seed: 0xC0FFEE)
        var seen = Set<Int>()
        for _ in 0..<200 {
            if let s = NapSpot.choose(from: Measured.tilesBottom, petSize: petSize,
                                      on: strip, using: &stream) {
                seen.insert(s.index)
            }
        }
        eq(seen.count, Measured.tilesBottom.count,
           "200 naps reach every one of the 14 dock items")
    }

    // MARK: - The trip out to the tile

    private static func trip() {
        section("[M13] NapTrip: walking there, and giving up")

        let strip = bottomStrip()
        let tile = Measured.tilesBottom[9]
        let reachable = NapSpot.distance(centring: petSize, on: tile, along: strip)

        /// A spot the cat is never told it reached, so the ceiling is what ends the trip.
        /// Built from a real tile rather than an invented distance: the trip does not read
        /// the spot's distance at all (it recomputes through `target`), and a made-up number
        /// there would suggest otherwise.
        func farSpot() -> NapSpot.Spot {
            let far = Measured.tilesBottom[13]
            return NapSpot.Spot(index: 13, tile: far,
                                distance: NapSpot.distance(centring: petSize, on: far,
                                                           along: strip))
        }

        do {
            var trip = NapTrip(spot: NapSpot.Spot(index: 9, tile: tile, distance: reachable))
            eq(trip.progress, .travelling, "a fresh trip is under way")
            eq(trip.advance(by: 1, arrived: false), .travelling,
               "a second of walking is not arrival")
            eq(trip.advance(by: 1, arrived: true), .arrived, "arriving ends the trip")
            eq(CGFloat(trip.elapsed), 2, "and the clock stops where it stopped")
            eq(trip.advance(by: 5, arrived: false), .arrived,
               "arrival is a one-way door: later ticks cannot un-arrive it")
            eq(CGFloat(trip.elapsed), 2, "and a finished trip's clock stays put")
        }

        do {
            var trip = NapTrip(spot: farSpot())
            for _ in 0..<(Int(NapTrip.approachCeiling) - 1) {
                eq(trip.advance(by: 1, arrived: false), .travelling,
                   "still walking below the ceiling")
            }
            eq(trip.advance(by: 1, arrived: false), .abandoned,
               "past the ceiling the cat gives up and sleeps where it stands")
            eq(trip.advance(by: 1, arrived: true), .abandoned,
               "and abandoning is a one-way door too")
        }

        do {
            // The same rule `KissRoutine` follows: arrival is tested before the ceiling, so
            // a cat that lands on the tile on the very last tick naps instead of being
            // called off for being slow.
            var trip = NapTrip(spot: farSpot())
            eq(trip.advance(by: NapTrip.approachCeiling, arrived: true), .arrived,
               "arriving on the ceiling tick still counts as arriving")
        }

        do {
            // A stalled process hands back a huge dt. It must not turn one frozen frame
            // into an abandoned nap.
            var trip = NapTrip(spot: farSpot())
            eq(trip.advance(by: 600, arrived: false), .travelling,
               "one stalled tick is one bounded step, not the whole ceiling")
            eq(CGFloat(trip.elapsed), CGFloat(BehaviorMachine.maximumStep),
               "the trip clock clamps a long step like every other clock here")
        }

        do {
            // The target follows the live strip: the Dock re-centres as apps launch
            // (PROBE.md F7, both ends move), and a target fixed at the start of the walk
            // would be measured against a strip that no longer exists.
            let firstTile = Measured.tilesBottom[0]
            let trip = NapTrip(spot: NapSpot.Spot(
                index: 0, tile: firstTile,
                distance: NapSpot.distance(centring: petSize, on: firstTile, along: strip)))
            // 29 pt is the measured shift from launching one app (PROBE.md F7: origin
            // 381.9 -> 352.9), applied to both ends because both ends moved.
            let shifted = WalkStrip(edge: .bottom, baseline: 80,
                                    start: strip.start - 29, end: strip.end + 29)
            eq(trip.target(for: petSize, on: shifted),
               NapSpot.distance(centring: petSize, on: Measured.tilesBottom[0], along: shifted),
               "the target is recomputed against the strip it is handed")
            check(trip.target(for: petSize, on: shifted) != trip.target(for: petSize, on: strip),
                  "so a strip that moved gives a different distance to the same tile")
        }
    }

    // MARK: - The whole thing, walked

    private static func endToEnd() {
        section("[M13] NapSpot: a cat actually walks there and lies down on the icon")

        let strip = bottomStrip()
        var rng = SplitMix64(seed: 0xCA7)
        guard let spot = NapSpot.choose(from: Measured.tilesBottom, petSize: petSize,
                                        on: strip, using: &rng) else {
            Harness.bail("the measured Dock must yield a spot")
        }

        let maximum = Geometry.maximumDistance(for: petSize, on: strip)
        let dt = 1.0 / 12          // the app's 12 fps animation tick (SPEC §6)

        /// Walk a cat from `start` until the trip ends, and report where it stopped.
        func walkThere(from start: CGFloat) -> (NapTrip, Walker) {
            var walker = Walker(distance: start, direction: .forward, speed: 30)
            var trip = NapTrip(spot: spot)
            var ticks = 0
            while trip.progress == .travelling && ticks < 10_000 {
                let arrived = walker.walk(toward: trip.target(for: petSize, on: strip),
                                          by: dt, maxDistance: maximum)
                trip.advance(by: dt, arrived: arrived)
                ticks += 1
            }
            return (trip, walker)
        }

        // Five seconds' walk away: inside the ceiling, and a real 60-tick approach rather
        // than a cat that starts where it is going.
        let near = min(maximum, max(0, spot.distance - 150))
        let (arrivedTrip, arrivedWalker) = walkThere(from: near)
        eq(arrivedTrip.progress, .arrived, "a cat 150 pt away reaches the tile")
        let frame = Geometry.petFrame(size: petSize, on: strip, distance: arrivedWalker.distance)
        eq(frame.midX, spot.tile.midX, "and comes to rest centred on the icon it chose")
        eq(frame.minY, strip.baseline, "still resting on the Dock's top edge")
        check(spot.tile.intersects(frame), "the sleeping cat overlaps the tile")

        // The far end of the same Dock is a twenty-second walk at 30 pt/s, which is more
        // than the ceiling allows. That trade-off is asserted here rather than only
        // described in a doc comment.
        let far = spot.distance > maximum / 2 ? 0 : maximum
        let (abandonedTrip, abandonedWalker) = walkThere(from: far)
        eq(abandonedTrip.progress, .abandoned,
           "a tile at the other end of the Dock is given up on")
        check(abandonedWalker.distance >= 0 && abandonedWalker.distance <= maximum,
              "and the cat that gave up is still standing somewhere on the strip")
        check(abandonedWalker.distance != far,
              "having walked part of the way there before it stopped")
    }
}

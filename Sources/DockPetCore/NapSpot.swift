//
//  NapSpot.swift: [M13] the cat walks to a Dock icon before it goes to sleep.
//
//  SPEC §5, so no AppKit here. The Accessibility read that produces the tile rects lives in
//  `DockPet/DockTiles.swift`, on the other side of the AppKit line. Everything that decides
//  *which* icon and *where along the strip* that icon is lives here, where it can be run
//  against the measured Run 6 tile layout in a test rather than watched on a screen nobody
//  reviewing this can see (SPEC §9).
//
//  What this is for: today the cat falls asleep wherever it happens to be standing. A cat
//  asleep on the Spotify icon is specific in a way that a cat asleep at x=417 is not, and
//  the specificity is the entire feature.
//
//  **Which tile: a random one, every time, and there is deliberately no config key for it.**
//  A "favourite app" setting was considered and rejected twice over. It breaks silently the
//  day that app leaves the Dock, leaving a key that names nothing and a cat that naps on
//  whatever moved into the slot; and it trades away the variety, which is the charm. The
//  randomness is seeded (`SplitMix64`, the same generator `BehaviorMachine` uses) so that a
//  given seed and a given set of tiles always pick the same tile, per SPEC §9.
//
//  **Everything here is strictly optional.** Without the Accessibility grant `DockTiles`
//  measures no tiles, `choose` returns nil, and the caller sleeps the cat where it stands,
//  which is exactly the behaviour that existed before this file. Nothing on this path is
//  load-bearing.
//

import CoreGraphics
import Foundation

/// Where the cat has decided to nap, and how to say that as a distance along the strip.
public enum NapSpot {

    /// One chosen icon: which one, where it is, and how far along the strip the cat must
    /// walk to lie down on it.
    public struct Spot: Equatable {

        /// Index into the tile array it was picked from. Carried so the verbose log can say
        /// *which* icon ("tile 7 of 14") instead of only a distance, which is the one thing
        /// that makes this feature checkable from a log rather than from a screenshot.
        /// Nothing keys off it: the tiles are re-measured every 500 ms and an index is not
        /// a stable identity across two measurements (see `NapTrip`).
        public let index: Int

        /// The tile's rect in AppKit space, frozen at the moment of choosing.
        public let tile: CGRect

        /// Distance along the strip, already clamped into `0...maximumDistance`.
        public let distance: CGFloat

        public init(index: Int, tile: CGRect, distance: CGFloat) {
            self.index = index
            self.tile = tile
            self.distance = distance
        }
    }

    /// The distance along `strip` that centres a pet of `petSize` on `tile`.
    ///
    /// This is the inverse of `Geometry.petFrame(size:on:distance:)`, and writing it as the
    /// exact inverse is the point: `petFrame` places the pet's near edge at `strip.start +
    /// distance`, so centring its midpoint on the tile's midpoint is
    ///
    ///     distance = tile.mid - petSize/2 - strip.start
    ///
    /// on whichever axis the strip runs along. `NapSpotTests` proves the round trip rather
    /// than trusting the algebra: it feeds every distance this returns back through
    /// `petFrame` and asserts the resulting rect is centred on the tile it came from.
    ///
    /// The axis matters. A left or right Dock produces a vertical strip whose free
    /// coordinate is y, and a version of this that always used `midX` would put the cat at
    /// the bottom of a side Dock and look, from a log, like it had worked. The app only ever
    /// walks a bottom Dock (`StripPolicy.horizontalOnly`, SPEC §4b [M6]), so the vertical
    /// case is untriggerable today and is implemented anyway, for the same reason
    /// `Geometry` implements it: the policy is the only thing rejecting it, and a trap laid
    /// for whoever lifts that policy is still a trap.
    ///
    /// **The result is clamped to the strip, never refused.** A tile at the very end of the
    /// Dock can be unreachable by a pet whose frame is wider than the room left beside it:
    /// centring on the first tile of the measured Dock with a 100 pt cat wants distance -21,
    /// which is not a place. Refusing would mean either dropping such tiles from the draw
    /// (so the two ends of the Dock silently stop being nap spots) or handing the caller a
    /// distance that does not exist on the strip. Clamping instead puts the cat as close as
    /// the strip allows, which still lands it on the tile because the overhang is bounded by
    /// half the pet. This is the same choice `Walker.walk(toward:by:maxDistance:)` makes and
    /// for the same stated reason: a target derived from live geometry must degrade to the
    /// nearest reachable point rather than to a place that no longer exists.
    ///
    /// A strip with no walkable room at all (a cat wider than the Dock) has exactly one
    /// distance, 0, and that is what comes back. It is the answer `Walker` already gives in
    /// the same situation: park at the near end rather than inch toward a target that has
    /// nowhere to be.
    public static func distance(centring petSize: CGSize,
                                on tile: CGRect,
                                along strip: WalkStrip) -> CGFloat {
        let centre: CGFloat
        let extent: CGFloat
        switch strip.axis {
        case .horizontal:
            centre = tile.midX
            extent = petSize.width
        case .vertical:
            centre = tile.midY
            extent = petSize.height
        }

        let wanted = centre - extent / 2 - strip.start
        let limit = Geometry.maximumDistance(for: petSize, on: strip)
        return min(max(0, wanted), limit)
    }

    /// Pick a tile to nap on, or nil if there is nothing to nap on.
    ///
    /// `tiles` is `DockTiles.tileFrames(on:)`: the in-band dock-item frames on one screen,
    /// in AppKit space, in Dock order. It is empty exactly when there is no measurement to
    /// work from, which is the normal state of an ungranted app (SPEC §4c: Accessibility is
    /// opt-in) and also what an empty Dock looks like. **Nil is a supported answer, not an
    /// error**: the caller is expected to fall back to sleeping the cat where it stands.
    ///
    /// Separators are dock items and are eligible. Filtering them out would need a rule that
    /// distinguishes them (they have no title), and `PROBE.md` F7 already declined to write
    /// that filter for the union. A cat asleep across a 26 pt separator still reads as a cat
    /// asleep on the Dock, and two of fourteen items is not worth a special case.
    ///
    /// `rng` is taken `inout` rather than owned so the caller can keep one seeded stream for
    /// the whole app, the way `BehaviorMachine` does. Seeding per call from a clock would
    /// make the choice unreproducible and put SPEC §9 out of reach.
    public static func choose(from tiles: [CGRect],
                              petSize: CGSize,
                              on strip: WalkStrip,
                              using rng: inout SplitMix64) -> Spot? {
        guard !tiles.isEmpty else { return nil }

        let index = Int.random(in: 0..<tiles.count, using: &rng)
        let tile = tiles[index]
        return Spot(index: index,
                    tile: tile,
                    distance: distance(centring: petSize, on: tile, along: strip))
    }
}

/// [M13] One walk out to a chosen icon: how long it has been going, and whether it is still
/// worth continuing.
///
/// Shaped like `KissRoutine`, and for the same reasons. The caller owns the walking (it is
/// `Walker.walk(toward:by:maxDistance:)`, which already steers, clamps and reports arrival),
/// reports back how much time passed and whether the cat arrived *this tick*, and gets a
/// verdict. Keeping the two apart is what lets the trip be run to completion in a test with
/// no strip, no Dock and no screen.
public struct NapTrip: Equatable {

    public enum Progress: String, Equatable {
        /// Still walking. The cat should be rendered walking, not sleeping.
        case travelling
        /// Standing on the icon. Now it may actually sleep.
        case arrived
        /// Gave up. The cat sleeps where it stands, which is the behaviour that existed
        /// before this feature and is a perfectly good nap.
        case abandoned
    }

    /// How long the cat is given to reach the icon before the nap is taken where it stands.
    ///
    /// **Yes, there is a ceiling, and it is `KissRoutine.approachCeiling`'s idea reused**,
    /// though not its number. The kiss needs one because a routine with no way to give up
    /// would hold both cats out of their own behaviour machine forever. That specific danger
    /// does not exist here: the behaviour machine keeps running throughout the trip, and the
    /// sleep state expires on its own after its 12 to 30 second dwell whatever this does. So
    /// the ceiling is not a deadlock guard, and copying the kiss's 10 seconds unexamined
    /// would have been cargo cult.
    ///
    /// What it is instead is a promise that the nap actually happens. The measured Dock is
    /// 748 pt wide (`PROBE.md` F7) and the default walk is 30 pt/s, so crossing it takes 25
    /// seconds, which is longer than the *longest* sleep dwell. Without a ceiling, a cat that
    /// drew a tile at the far end would spend its entire nap walking and would never once be
    /// seen asleep on an icon, which is the whole feature not happening. Eight seconds is
    /// two thirds of the *shortest* sleep dwell (12 s), so the cat is always seen asleep for
    /// at least four seconds, and it covers 240 pt, which at the measured 58 pt tile size is
    /// about four icons either side. Against a uniformly placed cat and a uniformly drawn
    /// tile that reaches roughly half the naps; the other half sleep where they stand, which
    /// is still over the Dock because the strip is confined to the tiles (SPEC §4b [M9]).
    ///
    /// Raising it is not free: every extra second is a second of a "sleeping" cat visibly
    /// walking. Making the cat sprint to the spot instead was considered and left to the
    /// caller, since `Walker.speed` is the caller's to set and a nap is not a good enough
    /// reason for this file to have an opinion about how fast a cat moves.
    public static let approachCeiling: TimeInterval = 8

    /// The icon, frozen at the moment it was chosen.
    ///
    /// Frozen rather than re-measured, and this is a real trade-off. `PROBE.md` F7 shows the
    /// Dock re-centres when an app launches: 14 items became 15 and the origin moved 381.9
    /// to 352.9, so **both** ends move. If that happens mid-walk, this rect is stale by the
    /// shift and the cat lands on a neighbouring icon.
    ///
    /// The alternatives are worse. Re-picking each poll makes the cat chase a target that
    /// moves every time it is asked, so it may never arrive. Re-identifying "the same tile"
    /// across two measurements needs an identity the measurement does not carry: an index is
    /// invalidated by any insertion, and titles are read only by `DockTiles.inspect`, are not
    /// unique (two separators, both untitled) and cost a second Accessibility read per item
    /// on a path SPEC §4b insists stays cheap. A tile re-centring by 29 pt during the few
    /// seconds a walk takes is rare, costs one icon of accuracy, and is covered by the
    /// ceiling in the pathological case where the Dock keeps moving.
    public let tile: CGRect

    /// Which tile it was, for the log. See `NapSpot.Spot.index`.
    public let tileIndex: Int

    public private(set) var progress: Progress = .travelling
    public private(set) var elapsed: TimeInterval = 0

    public var isTravelling: Bool { progress == .travelling }

    public init(spot: NapSpot.Spot) {
        self.tile = spot.tile
        self.tileIndex = spot.index
    }

    /// Where the cat should be walking to, measured against the strip as it is right now.
    ///
    /// Recomputed per call rather than stored, exactly as the kiss recomputes its midpoint
    /// every frame: `strip.start` is the left edge of the measured tile union, so it moves
    /// whenever the Dock is resized, re-centred or moved to another screen. A distance
    /// captured when the trip began is measured against a strip that may no longer exist,
    /// and would walk the cat to the wrong place with complete confidence.
    ///
    /// Note that `NapSpot.Spot.distance` is deliberately *not* stored on the trip for this
    /// reason. It is the answer for the strip that was current when the spot was chosen, and
    /// it is only good for that one tick.
    public func target(for petSize: CGSize, on strip: WalkStrip) -> CGFloat {
        NapSpot.distance(centring: petSize, on: tile, along: strip)
    }

    /// Advance the trip's clock and report the verdict.
    ///
    /// `arrived` is what `Walker.walk(toward:by:maxDistance:)` returned for this tick. The
    /// walker is the only thing that can answer it: it knows about the clamped target and
    /// about landing exactly on it rather than oscillating around it, and duplicating that
    /// test here with a tolerance of its own would give two answers that disagree on the
    /// frame where it matters.
    ///
    /// Arrival is tested before the ceiling, the same order `KissRoutine` uses, so a cat that
    /// reaches the icon on the very last tick lies down instead of being called off for
    /// being slow.
    ///
    /// A long step is clamped to `BehaviorMachine.maximumStep` for the reason every clock in
    /// this package clamps one: a stalled or suspended process hands back a huge elapsed
    /// time on the next fire, and burning the whole ceiling inside one frozen frame would
    /// abandon a trip that never got a chance to happen.
    ///
    /// Both endings are one-way doors. Once the cat is asleep on the icon, a later tick that
    /// reports it no longer standing exactly there (the Dock moved a little under it) must
    /// not restart the walk and drag a sleeping cat across the Dock.
    @discardableResult
    public mutating func advance(by dt: TimeInterval, arrived: Bool) -> Progress {
        guard progress == .travelling, dt > 0 else { return progress }

        elapsed += min(dt, BehaviorMachine.maximumStep)

        if arrived {
            progress = .arrived
        } else if elapsed >= Self.approachCeiling {
            progress = .abandoned
        }
        return progress
    }
}

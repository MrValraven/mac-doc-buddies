//
//  Pet.swift — one pet: its window, its view, and everything that decides where it is.
//
//  SPEC §7 M11c. Before this file, AppDelegate held exactly one of each of these. The
//  extraction is what makes a second cat a second element in an array rather than a second
//  copy of every line in AppDelegate.
//
//  What is deliberately *not* here: timers. There is one animation timer and one locator
//  poll for the whole app (§6 [M11]). A pet is driven; it does not drive itself.
//

import AppKit
import DockPetCore

final class Pet {

    /// Position in `AppDelegate`'s array. Used by the verbose log and the self-tests to
    /// say *which* cat, which is the whole difficulty of debugging two of them.
    let index: Int

    var profile: PetProfile

    let window: PetWindow
    let interaction: PetInteraction

    /// Not `let`: a coat or scale change rebuilds the view rather than mutating it, so the
    /// sheets are re-sliced and the alpha masks re-derived from the new art.
    private(set) var view: PetView

    var walker: Walker
    var behavior: BehaviorMachine
    var sequencer: FrameSequencer
    var size: CGSize

    /// [M11] `distance` and `direction` are parameters rather than defaults-only because
    /// a cast has to be **spread along the strip**. Two same-size pets both starting at
    /// distance 0 have byte-identical frames, and `MeetingCoordinator.haveMet` is true for
    /// identical frames — so an unspaced pair launches stacked into what reads as a single
    /// cat and immediately spends the 60 second cooldown on a meeting with itself.
    ///
    /// They also let a rebuilt cast keep standing where it was, instead of every surviving
    /// cat teleporting back to the near end because a *different* cat was added.
    init(index: Int, profile: PetProfile, spriteSet: SpriteSet, size: CGSize, speed: CGFloat,
         distance: CGFloat = 0, direction: Walker.Direction = .forward) {
        self.index = index
        self.profile = profile
        self.size = size
        self.view = PetView(frame: NSRect(origin: .zero, size: size), spriteSet: spriteSet)
        self.window = PetWindow(contentRect: NSRect(origin: .zero, size: size),
                                content: self.view)
        self.interaction = PetInteraction()
        self.walker = Walker(distance: distance, direction: direction, speed: speed)
        // Each pet gets its own seed. Two cats sharing one would idle and sleep in
        // lockstep, which looks like one cat drawn twice.
        self.behavior = BehaviorMachine(seed: UInt64.random(in: UInt64.min...UInt64.max))
        self.sequencer = FrameSequencer(frameCount: 1, fps: 1)
    }

    /// [M6] Swap to a state's sheet and restart its cycle from the top rather than
    /// resuming mid-stride.
    func applyBehaviorState(_ state: PetState, spriteSet: SpriteSet?) {
        let sheet = spriteSet?.sheet(for: state)
        sequencer = FrameSequencer(frameCount: sheet?.metadata.frameCount ?? 1,
                                   fps: sheet?.metadata.fps ?? 1)
        view.state = state
        view.frameIndex = 0
    }

    /// Swap in a new sprite set — a new coat, or the same art at a new scale — keeping the
    /// pet's current state and heading.
    ///
    /// The view is rebuilt rather than repainted: `PetView` slices the sheets and derives
    /// their alpha masks once, at init, and a mask left over from the old art would decide
    /// which clicks belong to the cat using a silhouette that is no longer on screen.
    func applySprites(_ set: SpriteSet, size: CGSize) {
        self.size = size

        let sheet = set.sheet(for: behavior.state)
        sequencer = FrameSequencer(frameCount: sheet.metadata.frameCount, fps: sheet.metadata.fps)

        let rebuilt = PetView(frame: NSRect(origin: .zero, size: size), spriteSet: set)
        rebuilt.state = behavior.state
        rebuilt.facing = walker.direction == .forward ? .right : .left
        rebuilt.frameIndex = 0
        view = rebuilt

        // The sheet may be a different size; resize before swapping so the view is not
        // briefly stretched.
        window.setContentSize(size)
        window.contentView = rebuilt

        // [M10] Re-attach: this is a brand new view, and an interaction still pointing at
        // the old one would leave the cat unclickable with nothing on screen to say why.
        interaction.attach(to: rebuilt, in: window)
    }

    /// [M11] Let a pet go. AppKit retains an ordered-in window, so `deinit` never runs for
    /// a cat that is still on screen — a dropped pet has to be dismissed explicitly or it
    /// stays on the Dock forever, with a live global mouse monitor behind it.
    func teardown() {
        interaction.stopMouseTracking()
        interaction.dismissBubble()
        window.orderOut(nil)
        window.close()
    }

    func position(on strip: WalkStrip) {
        window.setFrame(Geometry.petFrame(size: size, on: strip, distance: walker.distance),
                        display: true)
    }

    /// [M6, amended M11] Whether this pet has nothing to redraw. The app-wide timer
    /// suspends only when this is true for *every* pet.
    func isStationary(spriteSet: SpriteSet?) -> Bool {
        !behavior.state.isMoving && !(spriteSet?.isAnimated(behavior.state) ?? false)
    }

    /// Advance the behaviour clock. Returns both states so the caller can log the change
    /// and swap sheets only when there was one.
    @discardableResult
    func advanceBehavior(by dt: TimeInterval) -> (previous: PetState, current: PetState) {
        let previous = behavior.state
        // [M10] The behaviour clock stops while this pet is talking, so it holds the pose
        // it answered in rather than wandering out from under its own sentence.
        let current = interaction.isTalking ? previous : behavior.advance(by: dt)
        return (previous, current)
    }

    /// One animation frame: move if walking, advance the sheet, keep the bubble with us.
    func advanceAnimation(by dt: TimeInterval, on strip: WalkStrip, spriteSet: SpriteSet?) {
        // [M6] Only walking moves the pet. A sit or sleep animation still plays below.
        if behavior.state.isMoving {
            walker.advance(by: dt, maxDistance: Geometry.maximumDistance(for: size, on: strip))
            // SPEC §5: flip horizontally for the return trip rather than shipping mirrored art.
            view.facing = walker.direction == .forward ? .right : .left
        }
        position(on: strip)

        // The sheet plays at its own fps, independent of the timer's rate.
        sequencer.advance(by: dt)
        view.frameIndex = sequencer.index

        // [M10] Two things move the cat relative to the cursor: the cursor, which the
        // interaction's own mouse monitor catches, and the cat, which is this. The bubble
        // follows for the same reason — the Dock can be resized mid-sentence.
        interaction.updateClickThrough()
        if interaction.isTalking { interaction.positionBubble() }
    }
}

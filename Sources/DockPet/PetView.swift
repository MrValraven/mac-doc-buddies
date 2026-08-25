//
//  PetView.swift — rendering.
//
//  SPEC §5:
//    * nearest-neighbour only — blurry pixel art means this file is wrong
//    * integer scale factors, accounting for backingScaleFactor
//    * horizontal flip for the return trip; one sheet per state, not two per state
//      — the flip applies to the side-on walk sheet only; the stationary sheets are
//        front-on poses and are drawn exactly as authored
//

import AppKit
import CoreGraphics
import DockPetCore

/// Told when the pet itself is clicked. [M10]
///
/// [M13] And when it is *held*. A press on the cat is now two possible gestures and the
/// view cannot know which one it is at the moment the button goes down, so it reports the
/// press as it develops and `Purr` (pure) decides what each stage means. The click
/// callback survives unchanged and still means exactly what it did: open the prompt menu.
protocol PetViewClickDelegate: AnyObject {
    /// `point` is in the view's own coordinates, which is where the menu should open.
    ///
    /// [M13] Now sent on mouse *up* rather than mouse down, because until the button comes
    /// up there is no way to tell a click from the start of a hold. Everything downstream
    /// of it is unchanged.
    func petView(_ view: PetView, wasClickedAt point: NSPoint)

    /// A press landed on the art. Not yet a click and not yet a hold. The point of this
    /// callback is that the delegate can stop the pet's window from going click-through
    /// underneath a press it is in the middle of, which would eat the mouse-up and with it
    /// the menu. See `PetInteraction.updateClickThrough`.
    func petViewPressBegan(_ view: PetView)

    /// The press has been held past `Purr.holdThreshold` with the pointer still on the
    /// cat: start purring.
    func petViewHoldBegan(_ view: PetView)

    /// The press is over, however it ended: button up, pointer slid off the cat, or the
    /// view taken out from under it. Always sent, exactly once per `petViewPressBegan`,
    /// and always before the click callback above, so the delegate never has to unpick the
    /// two orders.
    func petViewPressEnded(_ view: PetView)
}

final class PetView: NSView {

    /// Which way the pet is facing. Sheets are drawn facing right, so `.left` is the
    /// flipped case (SPEC §5: no mirrored duplicate art).
    enum Facing { case right, left }

    private let spriteSet: SpriteSet

    /// Frames per state, sliced once at load. A handful of small images; re-slicing them
    /// 12 times a second for the life of the app would be waste.
    private let framesByState: [PetState: [CGImage]]

    /// [M10] Which pixels of each frame are solid enough to click.
    ///
    /// Built here, once, next to the slicing: the alpha of a frame cannot change without
    /// the frame changing, and reading it per click would mean redrawing the sprite into a
    /// bitmap on the main thread every time the mouse moved over the Dock.
    private let masksByState: [PetState: [AlphaMask]]

    /// How far a click may miss the art and still count, in art pixels.
    ///
    /// The cat is 32 px of art. Its tail and ears are one or two pixels thick, so a
    /// pixel-exact hit test makes them unclickable in practice. Two art pixels is 4 pt at
    /// the default 2x scale — forgiving enough to hit the tail, tight enough that the Dock
    /// icon beside the cat still gets its own clicks.
    static let clickTolerancePx = 2

    weak var clickDelegate: PetViewClickDelegate?

    var state: PetState = .walk {
        didSet { if state != oldValue { needsDisplay = true } }
    }

    var frameIndex: Int = 0 {
        didSet { if frameIndex != oldValue { needsDisplay = true } }
    }

    var facing: Facing = .right {
        didSet { if facing != oldValue { needsDisplay = true } }
    }

    init(frame frameRect: NSRect, spriteSet: SpriteSet) {
        self.spriteSet = spriteSet

        var sliced: [PetState: [CGImage]] = [:]
        for (state, sprite) in spriteSet.sheets {
            sliced[state] = (0..<sprite.metadata.frameCount).compactMap { index in
                sprite.image.cropping(to: sprite.metadata.sourceRectPx(frame: index))
            }
        }
        self.framesByState = sliced

        var masks: [PetState: [AlphaMask]] = [:]
        for (state, frames) in sliced {
            masks[state] = frames.map { AlphaMask(image: $0) ?? AlphaMask(widthPx: 0, heightPx: 0, opaque: []) }
        }
        self.masksByState = masks

        super.init(frame: frameRect)

        // Layer-backed so the magnification filter applies to the composited result too,
        // not only to what draw(_:) puts down.
        wantsLayer = true
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.isOpaque = false

        // [M10] Installed here rather than waiting for AppKit's first layout pass. On a
        // fresh install the pet is hidden until Accessibility is granted (§4c [M9]), so
        // that pass can be minutes away or never — and the cat would be silently
        // unhoverable until something else happened to trigger it.
        updateTrackingAreas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PetView is created in code only")
    }

    /// The window is transparent (SPEC §3); only the sprite's own pixels are opaque.
    override var isOpaque: Bool { false }

    /// How many frames were sliced for a state — checked at startup so a malformed sheet
    /// fails loudly instead of drawing nothing.
    func sliceCount(for state: PetState) -> Int { framesByState[state]?.count ?? 0 }

    /// Which sheet a state actually draws from — its own if it has one, otherwise walk's.
    ///
    /// Both the image and the flip decision hang off this, so a state that falls back to
    /// the walk sheet is also flipped like the walk sheet.
    private var drawnSheet: PetState {
        if let own = framesByState[state], !own.isEmpty { return state }
        return .walk
    }

    /// The image to draw right now.
    ///
    /// A state without its own sheet borrows the walk sheet's first frame, so an idle or
    /// sleeping pet is a still pose rather than a gap.
    private var currentImage: CGImage? {
        guard let frames = framesByState[drawnSheet], !frames.isEmpty else { return nil }
        return frames[((frameIndex % frames.count) + frames.count) % frames.count]
    }

    /// Only the walk sheet is mirrored.
    ///
    /// It is the one drawn in profile, and the only one with a return trip to mirror for.
    /// The stationary sheets are front-on poses: mirroring them would flip the tail curl
    /// for no reason, and would make a stopped pet's pose depend on which way it happened
    /// to be walking a moment earlier.
    private var mirrorsWhenFacingLeft: Bool { drawnSheet == .walk }

    /// The mask matching whatever `currentImage` is about to draw.
    ///
    /// Derived from `drawnSheet` and `frameIndex` exactly as the image is, so the hit test
    /// can never end up checking a different frame from the one on screen.
    private var currentMask: AlphaMask? {
        guard let masks = masksByState[drawnSheet], !masks.isEmpty else { return nil }
        return masks[((frameIndex % masks.count) + masks.count) % masks.count]
    }

    /// Is the cat actually drawn under this point of the view?
    ///
    /// [M10] The window is a rectangle around a mostly-empty sprite, and it floats over the
    /// Dock. This is what keeps the empty part of that rectangle from swallowing clicks
    /// meant for the Dock icon behind it — see AlphaMask, and PetInteraction, which uses
    /// this to decide whether the window should be taking mouse events at all.
    func isOverSprite(_ point: NSPoint) -> Bool {
        guard let mask = currentMask, !mask.isEmpty else { return false }
        return mask.isOpaque(atViewPoint: point,
                             viewSize: bounds.size,
                             mirrored: facing == .left && mirrorsWhenFacingLeft,
                             tolerancePx: Self.clickTolerancePx)
    }

    /// Decline clicks that land on the sprite's transparent margin.
    ///
    /// Belt and braces: PetInteraction already turns the whole window click-through when
    /// the cursor is off the art, but that tracking is driven by mouse-moved events and the
    /// cat moves too. This makes the view itself the final word.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        return isOverSprite(local) ? self : nil
    }

    /// DockPet is an accessory app and its window can never be key (SPEC §3), so without
    /// this the first click on the cat would be swallowed activating the app instead of
    /// opening the menu.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - [M13] Press, or hold

    /// When the live press started, on the monotonic media clock. `nil` when no button is
    /// down on the cat.
    ///
    /// `CACurrentMediaTime` rather than `Date`: it does not jump when the wall clock is
    /// corrected, and a clock correction mid-press would otherwise decide the gesture.
    /// This is the only clock read in the feature, and everything it is read *for* is
    /// decided by `Purr`, which takes the elapsed time as a parameter (SPEC §9).
    private var pressStarted: CFTimeInterval?

    /// Where the press landed, in view coordinates. The menu opens here rather than at
    /// wherever the pointer ended up, so a press that drifts two points still puts the
    /// menu where the user aimed.
    private var pressPoint: NSPoint = .zero

    /// Fires once, at the threshold, and is invalidated the moment it fires or the press
    /// ends. SPEC §6 forbids a repeating steady-state timer, not a one-shot that exists
    /// only while a finger is down, which is the licence `HeartsWindow` runs under.
    private var holdTimer: Timer?

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard isOverSprite(local) else {
            super.mouseDown(with: event)
            return
        }
        beginPress(at: local)
    }

    /// A drag that leaves the art ends the press.
    ///
    /// This is the "pointer left the cat mid-hold" case, and it has to be handled here:
    /// once `mouseDown` is accepted, AppKit delivers the whole drag to this view whether
    /// or not the pointer is still over it, so nothing else will notice. Sliding your hand
    /// off a cat stops petting it, and a press that slides off before the threshold is a
    /// click the user backed out of, and `Purr.release` distinguishes the two.
    override func mouseDragged(with event: NSEvent) {
        guard pressStarted != nil else {
            super.mouseDragged(with: event)
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        if !isOverSprite(local) { endPress(overPet: false) }
    }

    override func mouseUp(with event: NSEvent) {
        guard pressStarted != nil else {
            super.mouseUp(with: event)
            return
        }
        endPress(overPet: isOverSprite(convert(event.locationInWindow, from: nil)))
    }

    /// The view being pulled out from under a live press: a coat or scale change rebuilds
    /// `PetView` (`Pet.applySprites`), and `Pet.teardown` drops the cat entirely.
    ///
    /// Without this the press would stay open on a view that will never see another mouse
    /// event, and its delegate would be left purring for a cat that is no longer on the
    /// Dock. Ended as "not over the pet", so a half-formed press cannot pop a menu up out
    /// of a rebuild.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, pressStarted != nil { endPress(overPet: false) }
    }

    private func beginPress(at point: NSPoint) {
        // Defensive: a mouse-up can go missing if the window stopped taking events
        // mid-press. Closing the stale press before opening a new one keeps the delegate's
        // began/ended pairs matched.
        if pressStarted != nil { endPress(overPet: false) }

        pressStarted = CACurrentMediaTime()
        pressPoint = point
        clickDelegate?.petViewPressBegan(self)

        let timer = Timer(timeInterval: Purr.holdThreshold, repeats: false) { [weak self] _ in
            self?.holdThresholdReached()
        }
        // `.common`, per SPEC §8 trap 3: in `.default` this timer stalls during menu
        // tracking and live resize, and a hold that silently never starts is worse than
        // one that starts late.
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    /// The press has lasted long enough to be a hold, if it is still a press and still
    /// on the cat.
    ///
    /// Both re-checks matter. The cat *walks*: at the default 30 pt/s it covers about 10
    /// points in the threshold, which is enough to step out from under a stationary
    /// pointer near the edge of the sprite. And the button may already be up: the window
    /// can be turned click-through by something else mid-press, and a lost mouse-up must
    /// not leave a cat purring at nobody.
    private func holdThresholdReached() {
        holdTimer = nil
        guard pressStarted != nil else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0, cursorIsOverSprite else {
            endPress(overPet: false)
            return
        }
        clickDelegate?.petViewHoldBegan(self)
    }

    /// Is the pointer over solid art *right now*, wherever it has got to?
    ///
    /// Read from `NSEvent.mouseLocation` rather than from an event, because the moment
    /// this is asked is a timer firing, not a mouse event arriving.
    private var cursorIsOverSprite: Bool {
        guard let window = window else { return false }
        let local = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return isOverSprite(local)
    }

    /// Close the press and act on what it turned out to be.
    ///
    /// The ordering is deliberate: the delegate hears the press ended *before* the menu is
    /// opened. `NSMenu.popUp` runs a modal tracking loop that does not return until the
    /// menu is dismissed, so a delegate told afterwards would spend the whole life of the
    /// menu believing a finger was still on the cat.
    private func endPress(overPet: Bool) {
        guard let started = pressStarted else { return }
        holdTimer?.invalidate()
        holdTimer = nil
        pressStarted = nil

        let outcome = Purr.release(after: CACurrentMediaTime() - started, overPet: overPet)
        clickDelegate?.petViewPressEnded(self)

        switch outcome {
        case .menu:
            clickDelegate?.petView(self, wasClickedAt: pressPoint)
        case .endPurr, .nothing:
            // `petViewPressEnded` above is what takes a purr down; there is nothing else
            // a press that was not a click has to do.
            break
        }
    }

    /// The current frame's clickable region, drawn as text.
    ///
    /// [M10] SPEC §9: a hit test that is wrong by a row is invisible on screen — the cat
    /// still looks right, it just stops taking clicks where you aim them. Printing the
    /// mask is the only way to check it against the art without seeing either.
    /// `#` is art, `+` is empty space a click still counts (the tolerance), `.` is
    /// click-through.
    func silhouetteDescription() -> String {
        guard let mask = currentMask, !mask.isEmpty else { return "(no mask)" }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return "(no bounds)" }

        var lines: [String] = []
        for rowPx in 0..<mask.heightPx {
            // Sample the middle of each art pixel, in view coordinates: y counts up from
            // the bottom, so the top row of art is the last one along that axis.
            let y = size.height * (CGFloat(mask.heightPx - rowPx) - 0.5) / CGFloat(mask.heightPx)
            var line = ""
            for columnPx in 0..<mask.widthPx {
                let x = size.width * (CGFloat(columnPx) + 0.5) / CGFloat(mask.widthPx)
                let point = NSPoint(x: x, y: y)
                if mask.isOpaque(atViewPoint: point, viewSize: size,
                                 mirrored: facing == .left && mirrorsWhenFacingLeft,
                                 tolerancePx: 0) {
                    line += "#"
                } else if isOverSprite(point) {
                    line += "+"
                } else {
                    line += "."
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// A point in this view where a click falls through to whatever is underneath, or
    /// `nil` when the current frame fills its whole rectangle.
    ///
    /// [M10] For `--interaction-test`, which cannot assume anything about the art it finds:
    /// the shipped cat leaves its corners empty, but the generated placeholder sheet is a
    /// solid block with no corners to fall through, and a self-test that passes or fails on
    /// which sheet happened to load is worse than no self-test.
    func clickThroughSample() -> NSPoint? {
        guard let mask = currentMask, !mask.isEmpty,
              bounds.width > 0, bounds.height > 0 else { return nil }
        for rowPx in 0..<mask.heightPx {
            let y = bounds.height * (CGFloat(mask.heightPx - rowPx) - 0.5) / CGFloat(mask.heightPx)
            for columnPx in 0..<mask.widthPx {
                let x = bounds.width * (CGFloat(columnPx) + 0.5) / CGFloat(mask.widthPx)
                let point = NSPoint(x: x, y: y)
                if !isOverSprite(point) { return point }
            }
        }
        return nil
    }

    // MARK: - [M10] The cursor

    /// Which cursor belongs over this point of the view.
    ///
    /// The cursor is the only thing that tells anyone the cat can be clicked at all — there
    /// is no button, no hover highlight and no tooltip on a 64 pt sprite. It follows
    /// exactly the same mask the click does, because a pointing hand over a spot that does
    /// not take clicks is a worse lie than no cursor change at all.
    func cursor(at point: NSPoint) -> NSCursor {
        isOverSprite(point) ? .pointingHand : .arrow
    }

    /// Kept so `--interaction-test` can check the options rather than trust that the area
    /// was installed with the right ones — `.activeAlways` in particular is the difference
    /// between this working and doing nothing at all.
    private(set) var cursorTrackingArea: NSTrackingArea?

    /// Install the tracking area that drives `cursorUpdate(with:)`.
    ///
    /// `NSCursor.set()` on its own does not survive the mouse moving: the system resets the
    /// cursor on every move, from the cursor rects of the window under the pointer. A
    /// tracking area is the sanctioned way to own the cursor over a view, and
    /// `.activeAlways` is what makes it work here — the pet's window can never be key
    /// (SPEC §3) and DockPet is an accessory app that is never active, so every other
    /// activation mode would leave the cursor alone forever.
    ///
    /// The area is the whole frame, which is larger than the cat. That is not a problem:
    /// the window only accepts mouse events while the cursor is over solid art
    /// (PetInteraction), so no cursor update is ever delivered for the transparent margin.
    /// `cursor(at:)` re-checks the mask anyway rather than relying on that.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = cursorTrackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.cursorUpdate, .mouseEnteredAndExited,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    /// Hand the cursor back on the way out.
    ///
    /// The pet walks, so the cat can leave the cursor rather than the other way round. A
    /// pointing hand stranded over the Dock after the cat has wandered off would be the
    /// app lying about something it no longer owns.
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext,
              let image = currentImage else { return }

        // SPEC §5: nearest-neighbour, and no antialiasing along the sprite's edges either.
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)

        ctx.saveGState()
        if facing == .left && mirrorsWhenFacingLeft {
            // Mirror about the view's vertical centre line. Applied to the context rather
            // than to the image so there is still only one copy of each sheet in memory.
            ctx.translateBy(x: bounds.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
        }
        ctx.draw(image, in: bounds)
        ctx.restoreGState()
    }
}

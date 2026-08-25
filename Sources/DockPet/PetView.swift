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
protocol PetViewClickDelegate: AnyObject {
    /// `point` is in the view's own coordinates, which is where the menu should open.
    func petView(_ view: PetView, wasClickedAt point: NSPoint)
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

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        guard isOverSprite(local) else {
            super.mouseDown(with: event)
            return
        }
        clickDelegate?.petView(self, wasClickedAt: local)
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

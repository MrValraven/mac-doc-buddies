//
//  ConfettiWindow.swift: [M13] the confetti that falls over the pair on the birthday.
//
//  A window of its own for the same reasons `HeartsWindow` is one. The pet's frame is the
//  sprite's frame and every position check in the app is written against it, so padding a
//  pet window out to hold something decorative would break those checks; and this belongs
//  to the *pair* rather than to either cat, so there is no pet window it could live in.
//
//  Where each piece is, how solid it is, which way round it is and what colour it is at a
//  given moment is `ConfettiDrift`'s job: pure, seeded and tested. This file draws what it
//  is told and owns the clock that asks.
//

import AppKit
import DockPetCore

/// A borderless, click-through window holding one burst of confetti.
///
/// Shares PetWindow's rules (never key, never in the window cycle, per SPEC §3) and the
/// bubble's extra one: it never takes clicks at all. Every flag in `init` is load-bearing
/// and is set for the reason given beside it.
///
/// **It runs its own timer, and that is deliberate.** It is the same argument
/// `HeartsWindow` makes, and it applies here more strongly. The app-wide animation timer
/// suspends when every pet is stationary (SPEC §6), and confetti falls over a pair that is
/// standing still being congratulated, so the one moment this window exists is exactly the
/// moment that timer is entitled to stop. A short-lived timer that invalidates itself after
/// `ConfettiDrift.duration` adds no steady-state wakeups, which is what §6 is protecting:
/// once the burst is over there is nothing left running, not even a suspended timer.
final class ConfettiWindow: NSWindow {

    /// Redraws per second while the confetti is up. The app's own art runs at 12 fps and is
    /// deliberately steppy on purpose; the confetti is not pixel art from a sheet, and at
    /// 12 fps a tumbling rectangle strobes, because a piece can turn far enough between
    /// frames that the eye reads it as jumping rather than spinning. The hearts took their
    /// own 24 fps for the same kind of reason, for a second and a half; this takes it for
    /// two and a half.
    private static let fps: Double = 24

    private let confettiView: ConfettiView
    private var timer: Timer?
    private var started: CFTimeInterval = 0

    /// Fires when the burst ends, by either route, and is cleared as it fires so that it
    /// can only ever fire once. Held here rather than captured by the timer because
    /// `dismiss()` must be able to run it too (see `finish()`).
    private var onFinish: (() -> Void)?

    /// Put confetti over the pair.
    ///
    /// `pair` is the union of the two pets' frames in screen points; the pieces start above
    /// the cats' heads, fall past them, and fade out around their feet.
    ///
    /// `seed` picks the burst. Any value will do and none is better than another, but the
    /// same value always gives the same twenty-four pieces in the same columns tumbling the
    /// same way, which is what makes a report of "one piece flickers at the left edge"
    /// something that can be reproduced rather than waited for.
    init(over pair: NSRect, scale: Int, seed: UInt64) {
        let unit = CGFloat(max(1, scale))

        // The piece is 4x2 art pixels, a shape read at the same scale as the cats, so the
        // confetti is the same size of "pixel" as everything else on the strip. Its height
        // comes from Core, which owns the proportion for the reason given there.
        let pieceWidth = unit * 4
        let pieceHeight = pieceWidth * ConfettiDrift.pieceAspect

        // Wider than the pair by a couple of art pixels: confetti that lands exactly on the
        // two cats and nowhere else reads as a targeted effect rather than as weather.
        let spread = pair.width / 2 + unit * 6

        // The fall clears the pair at both ends. It starts twelve points (at 2x) above the
        // heads and ends the same distance below the feet, so no piece is ever first seen
        // already overlapping a cat, and none is still at full strength when it reaches the
        // bottom edge of the Dock.
        let overshoot = unit * 12
        let fall = pair.height + overshoot * 2

        let drift = unit * 6

        let metrics = ConfettiView.Metrics(pieceWidth: pieceWidth, pieceHeight: pieceHeight,
                                           spread: spread, fall: fall, drift: drift)

        // The trap `HeartsWindow` names, with one more term in it. A piece never leaves
        // `spread + drift` of the centre horizontally or `fall / 2` of it vertically, but
        // it is also *rotating*, and a rectangle turned 45° reaches half its own diagonal
        // from its centre in every direction, further than either of its sides would
        // suggest. Sizing to the sides instead of the diagonal clips the corners off the
        // pieces at the edges of the burst, which is the visible form of getting this
        // wrong, and it only shows on the handful of pieces furthest out.
        let diagonal = hypot(pieceWidth, pieceHeight)
        let width = (spread + drift) * 2 + diagonal
        let height = fall + diagonal

        // Centred on the pair, because the fall is symmetric about the pair's own centre,
        // which is the point `ConfettiDrift` measures every offset from.
        let frame = NSRect(x: pair.midX - width / 2, y: pair.midY - height / 2,
                           width: width, height: height)

        self.confettiView = ConfettiView(frame: NSRect(origin: .zero, size: frame.size),
                                         metrics: metrics, seed: seed)

        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)

        // Above the cats, like the bubble and the hearts: confetti drawn behind a head
        // reads as a glitch rather than as something falling in front of them.
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isRestorable = false
        isReleasedWhenClosed = false
        contentView = confettiView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show the confetti and run it to the ground.
    ///
    /// `onFinish` fires exactly once, whether the burst ran out or `dismiss()` cut it
    /// short, so the caller has exactly one place to drop its reference to this window.
    /// Calling `start` again on a window that has finished is not supported: it has already
    /// been `close`d, and the caller should make a new one.
    func start(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        started = CACurrentMediaTime()
        orderFront(nil)

        let timer = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            guard let self else { return }
            let progress = (CACurrentMediaTime() - self.started) / ConfettiDrift.duration
            self.confettiView.progress = progress
            if progress >= 1 { self.finish() }
        }
        // `.common`, for the reason SPEC §8 lists third: a timer in `.default` stalls
        // during menu tracking and live resize, and confetti frozen in mid-air over two
        // cats outlasts the birthday it was celebrating.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Take the confetti down now: the end of the fall, a torn-down cast, or a quit.
    ///
    /// Safe to call at any point, including from inside `onFinish` and including twice.
    /// The second call has nothing left to invalidate and no closure left to run.
    func dismiss() {
        finish()
    }

    /// The single exit. Both routes out of a burst come through here, and the closure is
    /// taken out of the property *before* it is called, so a handler that calls `dismiss()`
    /// (which the tear-down path does, since it cannot know whether the burst is already
    /// over) cannot re-enter this and fire itself a second time.
    private func finish() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
        close()

        let handler = onFinish
        onFinish = nil
        handler?()
    }

    /// Keep the confetti over a pair that has moved. The Dock can be resized mid-burst,
    /// and the pair can be walked off by a locator poll that finds a different strip.
    func reposition(over pair: NSRect) {
        setFrameOrigin(NSPoint(x: pair.midX - frame.width / 2,
                               y: pair.midY - frame.height / 2))
    }
}

/// Draws `ConfettiDrift`'s pieces. Holds no timing and no geometry of its own: it is handed
/// a progress and asks Core where everything is.
final class ConfettiView: NSView {

    /// The lengths the drift is scaled by, in points, all derived from the sprite scale so
    /// the confetti stays in proportion to the cats at 2x and 3x alike.
    struct Metrics {
        let pieceWidth: CGFloat
        let pieceHeight: CGFloat
        let spread: CGFloat
        let fall: CGFloat
        let drift: CGFloat
    }

    let metrics: Metrics

    /// Which burst this is. Fixed at construction: re-rolling it per frame would give
    /// twenty-four pieces that teleport between columns twenty-four times a second.
    private let seed: UInt64

    /// 0…1 across the burst. Clamped by `ConfettiDrift` rather than here, so there is one
    /// place that decides what a progress past the end means.
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, metrics: Metrics, seed: UInt64) {
        self.metrics = metrics
        self.seed = seed
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let pieces = ConfettiDrift.pieces(progress: progress, seed: seed,
                                          spread: metrics.spread, fall: metrics.fall,
                                          drift: metrics.drift)

        // The point every offset is measured from: the middle of the window, which is where
        // the pair's own centre is (see `ConfettiWindow.init`).
        let origin = CGPoint(x: bounds.midX, y: bounds.midY)

        // The piece, centred on the origin of whatever transform is in force, so the
        // rotation below turns it about its own middle rather than swinging it about a
        // corner, which at this size would read as the piece orbiting a point beside it.
        let rect = CGRect(x: -metrics.pieceWidth / 2, y: -metrics.pieceHeight / 2,
                          width: metrics.pieceWidth, height: metrics.pieceHeight)

        for piece in pieces where piece.alpha > 0 {
            let ink = ConfettiDrift.palette[piece.colorIndex]

            context.saveGState()
            context.translateBy(x: origin.x + piece.offset.x, y: origin.y + piece.offset.y)
            context.rotate(by: piece.rotation)
            // The fade is applied to the fill colour rather than to the context, because
            // unlike the hearts' emoji this is a flat colour we own outright: one solid
            // rectangle, with no glyph carrying colours of its own to be tinted around.
            context.setFillColor(red: CGFloat(ink.red) / 255,
                                 green: CGFloat(ink.green) / 255,
                                 blue: CGFloat(ink.blue) / 255,
                                 alpha: piece.alpha)
            context.fill(rect)
            context.restoreGState()
        }
    }
}

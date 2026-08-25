//
//  HeartsWindow.swift — [M12] the hearts that rise over two cats mid-kiss.
//
//  A window of its own for the same reason the speech bubble is one (see BubbleWindow):
//  the pet's frame is the sprite's frame, every position check in the app is written
//  against it, and padding it out to hold something purely decorative would break those
//  checks. This window belongs to the *pair*, not to either cat, which is the other reason
//  it cannot live in a pet window.
//
//  Where each heart is and how solid it is at a given moment is `HeartDrift`'s job — pure
//  and tested. This file draws what it is told and owns the clock that asks.
//

import AppKit
import DockPetCore

/// A borderless, click-through window holding the hearts for one kiss.
///
/// Shares PetWindow's rules — never key, never in the window cycle (SPEC §3) — and the
/// bubble's extra one: it never takes clicks at all.
///
/// **It runs its own timer, and that is deliberate.** The app-wide animation timer
/// suspends when every pet is stationary (SPEC §6), and during the kiss both cats are
/// sitting — so the one moment the hearts exist is exactly the moment that timer is
/// entitled to stop. A short-lived timer that invalidates itself after
/// `HeartDrift.duration` adds no steady-state wakeups, which is what §6 is protecting.
final class HeartsWindow: NSWindow {

    /// Not the plain red heart: at 16 pt over a dark Dock, the two-tone sparkle reads as
    /// affection where the flat one reads as a notification badge.
    static let glyph = "💕"

    /// Redraws per second while the hearts are up. The app's own art runs at 12 fps and is
    /// deliberately steppy; the hearts are not pixel art, and at 12 fps a smooth fade
    /// visibly staircases, so they get their own — for a second and a half.
    private static let fps: Double = 24

    private let heartsView: HeartsView
    private var timer: Timer?
    private var started: CFTimeInterval = 0

    /// Put hearts over the pair.
    ///
    /// `pair` is the union of the two pets' frames in screen points; the hearts start
    /// between the cats, at the height of their heads, and rise from there.
    init(over pair: NSRect, scale: Int) {
        let unit = CGFloat(max(1, scale))
        let metrics = HeartsView.Metrics(glyphSize: unit * 9, spread: unit * 11, rise: unit * 22)

        // Wide enough for a heart that has drifted the full spread either way, tall enough
        // for one that has risen the whole way, with the glyph's own size on top of both —
        // a clipped heart at the top of the arc is the visible form of getting this wrong.
        let width = metrics.spread * 2 + metrics.glyphSize * 2
        let height = metrics.rise + metrics.glyphSize * 2

        let frame = NSRect(x: pair.midX - width / 2, y: pair.maxY - metrics.glyphSize,
                           width: width, height: height)

        self.heartsView = HeartsView(frame: NSRect(origin: .zero, size: frame.size),
                                     metrics: metrics)

        super.init(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)

        // Above the cats, like the bubble: hearts drawn behind a head read as a glitch.
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isRestorable = false
        isReleasedWhenClosed = false
        contentView = heartsView
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Show the hearts and run them to the end of their arc.
    ///
    /// `onFinish` fires once, whether the hearts ran out or `dismiss()` cut them short, so
    /// the caller has exactly one place to drop its reference.
    func start(onFinish: @escaping () -> Void) {
        started = CACurrentMediaTime()
        orderFront(nil)

        let timer = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            guard let self else { return }
            let progress = (CACurrentMediaTime() - self.started) / HeartDrift.duration
            self.heartsView.progress = progress
            if progress >= 1 {
                self.dismiss()
                onFinish()
            }
        }
        // `.common`, for the reason SPEC §8 lists third: a timer in `.default` stalls
        // during menu tracking and live resize, and hearts frozen mid-air outlast the kiss
        // that explains them.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Take the hearts down now — the end of the arc, a torn-down cast, or a quit.
    func dismiss() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
        close()
    }

    /// Keep the hearts over a pair that has moved. The Dock can be resized mid-kiss.
    func reposition(over pair: NSRect) {
        setFrameOrigin(NSPoint(x: pair.midX - frame.width / 2,
                               y: pair.maxY - heartsView.metrics.glyphSize))
    }
}

/// Draws `HeartDrift`'s hearts. Holds no timing of its own — it is handed a progress.
final class HeartsView: NSView {

    /// The three lengths the drift is scaled by, in points, derived from the sprite scale
    /// so the hearts stay in proportion to the cats at 2x and 3x alike.
    struct Metrics {
        let glyphSize: CGFloat
        let spread: CGFloat
        let rise: CGFloat
    }

    let metrics: Metrics

    /// 0…1 across the kiss. Clamped by `HeartDrift` rather than here, so there is one
    /// place that decides what a progress past the end means.
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    init(frame: NSRect, metrics: Metrics) {
        self.metrics = metrics
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let font = NSFont.systemFont(ofSize: metrics.glyphSize)
        let text = NSAttributedString(string: HeartsWindow.glyph, attributes: [.font: font])
        let size = text.size()
        let hearts = HeartDrift.hearts(progress: progress,
                                       spread: metrics.spread, rise: metrics.rise)

        // The origin every heart drifts from: the middle of the window, at the bottom,
        // which is where the two cats' heads are.
        let origin = NSPoint(x: bounds.midX, y: bounds.minY + metrics.glyphSize / 2)

        for heart in hearts where heart.alpha > 0 {
            // The fade is applied to the context rather than to a foreground colour: a
            // colour emoji carries its own colours and ignores `.foregroundColor` — alpha
            // included — so tinting the string would have drawn four hearts at full
            // strength that pop out of existence at the top of the arc.
            context.saveGState()
            context.setAlpha(heart.alpha)
            text.draw(at: NSPoint(x: origin.x + heart.offset.x - size.width / 2,
                                  y: origin.y + heart.offset.y - size.height / 2))
            context.restoreGState()
        }
    }
}

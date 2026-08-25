//
//  BubbleWindow.swift — the speech bubble the pet answers in.
//
//  [M10] A window of its own rather than a bigger pet window. The pet's frame is the
//  sprite's frame: Geometry.petFrame derives it from the sheet metadata and rests it
//  exactly on the Dock's edge, and every position check in the app is written against
//  that. Padding it out to hold text would put a large transparent margin around the cat,
//  move its origin off the Dock edge, and break those checks for a purely cosmetic reason.
//
//  Where the bubble goes and how long it stays are BubbleGeometry's job (pure, tested).
//  This file only draws it.
//

import AppKit
import DockPetCore

/// A borderless, click-through window holding one line of speech.
///
/// Shares PetWindow's rules — never key, never in the window cycle, never above the menu
/// bar (SPEC §3) — and adds one of its own: it never takes clicks at all. The pet is the
/// thing you click; the bubble is only ever a reply.
final class BubbleWindow: NSWindow {

    init(content: NSView) {
        super.init(contentRect: content.bounds, styleMask: .borderless,
                   backing: .buffered, defer: false)

        // The same level as the pet. Ordered in after the pet window, so it draws above the
        // cat rather than behind its ears.
        level = .statusBar

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isRestorable = false
        isReleasedWhenClosed = false
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws the bubble: a hard-cornered body with a wedge tail pointing down at the pet.
///
/// Deliberately not an NSPopover or a rounded native bubble. Next to nearest-neighbour
/// pixel art, a smooth antialiased popover reads as a different app's UI sitting on top of
/// the cat. Everything here is drawn with antialiasing off, which is also what gives the
/// tail its stepped diagonal for free — the same staircase the sprite's own edges have.
final class BubbleView: NSView {

    /// The sprite's outline ink (`makesprite.swift`'s `Ink.outline`), so the bubble is
    /// bounded by the same warm near-black the cat is.
    private static let ink = NSColor(srgbRed: 0x2B / 255, green: 0x20 / 255,
                                     blue: 0x18 / 255, alpha: 1)
    private static let paper = NSColor(srgbRed: 0.98, green: 0.975, blue: 0.96, alpha: 1)

    /// Text padding inside the body, in points.
    private static let padding = NSSize(width: 10, height: 7)

    /// Widest the bubble is allowed to get before the text wraps. Roughly a comfortable
    /// line length; wider than this and a long encouragement becomes a banner.
    private static let maximumTextWidth: CGFloat = 240

    private let text: String
    private let unit: CGFloat          // one art pixel, in points — the border thickness
    private let tailHeight: CGFloat

    /// Where the tail meets the body, in this view's coordinates. Set by the controller
    /// each time the bubble is placed, because the pet moves and the body may have been
    /// shoved sideways to stay on screen.
    var tailCenterX: CGFloat = 0 {
        didSet { if tailCenterX != oldValue { needsDisplay = true } }
    }

    private static func font(scale: Int) -> NSFont {
        // Grows a little with the cat, but not linearly: at 4x a proportional font would be
        // a headline. Weight rather than size is what keeps it legible over the Dock.
        NSFont.systemFont(ofSize: scale >= 3 ? 13 : 12, weight: .medium)
    }

    private var attributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: Self.font(scale: Int(unit)),
            .foregroundColor: Self.ink,
            .paragraphStyle: paragraph,
        ]
    }

    /// The window size this text needs, tail included.
    static func size(for text: String, scale: Int) -> NSSize {
        let unit = CGFloat(max(1, scale))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font(scale: scale),
            .paragraphStyle: paragraph,
        ]

        let bounds = (text as NSString).boundingRect(
            with: NSSize(width: maximumTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes)

        // Rounded up to whole points: a fractional width would put the border on a half
        // pixel and undo the crispness the rest of this file is for.
        let bodyWidth = ceil(bounds.width) + padding.width * 2 + unit * 2
        let bodyHeight = ceil(bounds.height) + padding.height * 2 + unit * 2
        return NSSize(width: max(bodyWidth, unit * 20),
                      height: bodyHeight + tailHeight(unit: unit))
    }

    private static func tailHeight(unit: CGFloat) -> CGFloat { unit * 4 }

    init(text: String, scale: Int) {
        self.text = text
        self.unit = CGFloat(max(1, scale))
        self.tailHeight = Self.tailHeight(unit: CGFloat(max(1, scale)))
        super.init(frame: NSRect(origin: .zero, size: Self.size(for: text, scale: scale)))
        wantsLayer = true
        layer?.isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("BubbleView is created in code only")
    }

    override var isOpaque: Bool { false }

    /// The bubble is a reply, never a target: clicks fall straight through to whatever is
    /// underneath, which is usually the Dock.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setShouldAntialias(false)
        ctx.interpolationQuality = .none

        // The stroke straddles the path, so the path is inset by half a border width to
        // keep the whole outline inside the window.
        let half = unit / 2
        let bodyBottom = tailHeight + half
        let left = half, right = bounds.width - half, top = bounds.height - half

        // The tail is a wedge hanging off the bottom of the body. Its base is clamped to
        // the body's width so a bubble shoved against a screen edge cannot grow a tail
        // that starts outside itself.
        let tailBase = unit * 5
        let tip = min(max(left + unit, tailCenterX), right - unit)
        let tailLeft = max(left, tip - tailBase / 2)
        let tailRight = min(right, tip + tailBase / 2)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: bodyBottom))
        path.addLine(to: CGPoint(x: tailLeft, y: bodyBottom))
        path.addLine(to: CGPoint(x: tip, y: half))          // the point, aimed at the cat
        path.addLine(to: CGPoint(x: tailRight, y: bodyBottom))
        path.addLine(to: CGPoint(x: right, y: bodyBottom))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: left, y: top))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColor(Self.paper.cgColor)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(Self.ink.cgColor)
        ctx.setLineWidth(unit)
        ctx.setLineJoin(.miter)
        ctx.strokePath()

        // Text is the one thing drawn with antialiasing on: hinted glyphs at 12 pt are
        // unreadable without it, and nobody expects the words themselves to be pixel art.
        ctx.setShouldAntialias(true)
        let body = NSRect(x: unit + Self.padding.width,
                          y: tailHeight + unit + Self.padding.height,
                          width: bounds.width - (unit + Self.padding.width) * 2,
                          height: bounds.height - tailHeight - (unit + Self.padding.height) * 2)
        (text as NSString).draw(with: body,
                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes)
    }
}

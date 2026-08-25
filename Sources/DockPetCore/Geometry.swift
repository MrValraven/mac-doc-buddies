//
//  Geometry.swift — coordinate conversion and strip layout. Pure functions only.
//
//  SPEC §8 trap 1: write the conversions once, test them, never inline them.
//  This file deliberately imports only CoreGraphics — no AppKit — so it can be exercised
//  by the test harness without a window server, and so the rules here stay independent
//  of live screen state.
//

import CoreGraphics

/// Which edge of a screen the Dock occupies.
///
/// The top edge is never a candidate: that inset is the menu bar, and macOS does not
/// place the Dock at the top.
public enum DockEdge: String, Equatable {
    case bottom, left, right
}

/// A screen reduced to the two rects that matter, so strip layout can be tested against
/// the values recorded in `PROBE.md` without needing an `NSScreen`.
public struct ScreenGeometry: Equatable {
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(frame: CGRect, visibleFrame: CGRect) {
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    /// Insets from `frame` to `visibleFrame`, in AppKit (bottom-left origin) space.
    public var bottomInset: CGFloat { visibleFrame.minY - frame.minY }
    public var topInset: CGFloat { frame.maxY - visibleFrame.maxY }
    public var leftInset: CGFloat { visibleFrame.minX - frame.minX }
    public var rightInset: CGFloat { frame.maxX - visibleFrame.maxX }
}

/// The line the pet walks along.
///
/// `baseline` is the fixed coordinate of the Dock's inner edge — a y value for a bottom
/// Dock, an x value for a side Dock. `start`/`end` bound the free coordinate.
public struct WalkStrip: Equatable {
    public enum Axis: Equatable { case horizontal, vertical }

    public let edge: DockEdge
    public let baseline: CGFloat
    public let start: CGFloat
    public let end: CGFloat

    public var axis: Axis { edge == .bottom ? .horizontal : .vertical }
    public var length: CGFloat { end - start }

    public init(edge: DockEdge, baseline: CGFloat, start: CGFloat, end: CGFloat) {
        self.edge = edge
        self.baseline = baseline
        self.start = start
        self.end = end
    }
}

/// Which Dock edges the pet is willing to walk along.
public struct StripPolicy: Equatable {
    public let allowedEdges: Set<DockEdge>

    public init(allowedEdges: Set<DockEdge>) { self.allowedEdges = allowedEdges }

    public func allows(_ edge: DockEdge) -> Bool { allowedEdges.contains(edge) }

    /// [M6] The app's policy: a bottom Dock only.
    public static let horizontalOnly = StripPolicy(allowedEdges: [.bottom])

    /// Every edge, including the vertical strips a side Dock produces.
    public static let anyEdge = StripPolicy(allowedEdges: [.bottom, .left, .right])
}

public enum Geometry {

    /// Smallest inset treated as a Dock rather than measurement noise.
    ///
    /// Measured Dock insets are large: 80 pt at tilesize 54, 125 pt at tilesize 128
    /// (`PROBE.md` Runs 1 and 5). A Dock-less screen reads exactly 0. 4 pt sits far below
    /// anything real and far above zero.
    public static let minimumDockInset: CGFloat = 4

    // MARK: - Coordinate conversion

    /// Convert a CoreGraphics global rect (top-left origin, y down) to AppKit
    /// (bottom-left origin, y up).
    ///
    /// Both spaces are anchored on the primary screen — the one whose `frame.origin` is
    /// `.zero`. Never pass `screens[0]`; it is not necessarily the primary.
    public static func flipCGToAppKit(_ rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryFrame.maxY - (rect.origin.y + rect.height),
               width: rect.width,
               height: rect.height)
    }

    /// Inverse of `flipCGToAppKit`. The transform is its own inverse, but naming both
    /// directions keeps call sites honest about which space they are in.
    public static func flipAppKitToCG(_ rect: CGRect, primaryFrame: CGRect) -> CGRect {
        flipCGToAppKit(rect, primaryFrame: primaryFrame)
    }

    // MARK: - Dock edge

    /// Which edge, if any, this screen's Dock occupies.
    ///
    /// Returns `nil` when no edge is inset enough to be a Dock — which is the normal
    /// answer for a secondary display (`PROBE.md` Run 1: zero bottom inset on screen 1).
    public static func dockEdge(of screen: ScreenGeometry) -> DockEdge? {
        let candidates: [(DockEdge, CGFloat)] = [
            (.bottom, screen.bottomInset),
            (.left,   screen.leftInset),
            (.right,  screen.rightInset),
        ]
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 >= minimumDockInset else {
            return nil
        }
        return best.0
    }

    // MARK: - Strip

    /// The walkable strip for a screen, or `nil` if this screen has no strip the pet is
    /// willing to walk.
    ///
    /// SPEC §4b [M8]: the strip spans the Dock's tiles when `tiles` carries a measurement,
    /// and the full extent of `visibleFrame` when it does not.
    ///
    /// `tiles` is the Dock's tile bounds in AppKit space. Only its extent along the
    /// strip's free axis is used — the fixed axis always comes from `visibleFrame`, which
    /// `PROBE.md` F1 shows is the one trustworthy source for the Dock's inner edge.
    /// Passing `nil` is the [M0] behaviour, so a caller that cannot measure the tiles
    /// still gets a usable strip rather than nothing.
    ///
    /// [M6] `policy` decides which Dock edges count. The app uses `.horizontalOnly`: a
    /// side Dock produces a vertical strip, and a dog walking up a wall looks broken. The
    /// vertical cases are still implemented and tested — the geometry is correct and the
    /// policy is the only thing rejecting them.
    public static func walkStrip(on screen: ScreenGeometry,
                                 policy: StripPolicy = .horizontalOnly,
                                 tiles: CGRect? = nil) -> WalkStrip? {
        guard let edge = dockEdge(of: screen), policy.allows(edge) else { return nil }
        let vf = screen.visibleFrame
        switch edge {
        case .bottom:
            let (start, end) = confine(vf.minX, vf.maxX, to: tiles.map { ($0.minX, $0.maxX) })
            return WalkStrip(edge: .bottom, baseline: vf.minY, start: start, end: end)
        case .left:
            let (start, end) = confine(vf.minY, vf.maxY, to: tiles.map { ($0.minY, $0.maxY) })
            return WalkStrip(edge: .left, baseline: vf.minX, start: start, end: end)
        case .right:
            let (start, end) = confine(vf.minY, vf.maxY, to: tiles.map { ($0.minY, $0.maxY) })
            return WalkStrip(edge: .right, baseline: vf.maxX, start: start, end: end)
        }
    }

    /// Narrow `[full.start, full.end]` to the measured tile span, clipped to the screen.
    ///
    /// Falls back to the full span whenever the measurement cannot be believed — an empty
    /// rect (what a failed Accessibility read degrades to) or a span that does not overlap
    /// this screen at all (the Dock is on another display). A pet walking too far is a
    /// cosmetic miss; a pet parked off-screen is an invisible app.
    private static func confine(_ fullStart: CGFloat, _ fullEnd: CGFloat,
                                to measured: (CGFloat, CGFloat)?) -> (CGFloat, CGFloat) {
        guard let measured = measured else { return (fullStart, fullEnd) }
        let low = min(measured.0, measured.1)
        let high = max(measured.0, measured.1)
        let start = max(fullStart, low)
        let end = min(fullEnd, high)
        guard end > start else { return (fullStart, fullEnd) }
        return (start, end)
    }

    /// How far along the strip the pet may travel before it would overhang the far end.
    public static func maximumDistance(for size: CGSize, on strip: WalkStrip) -> CGFloat {
        let extent = strip.axis == .horizontal ? size.width : size.height
        return max(0, strip.length - extent)
    }

    /// Place a pet of `size` at `distance` along `strip`, resting against the Dock.
    ///
    /// `distance` is clamped, so a caller that walks past the end gets a pet parked at the
    /// end rather than one hanging off the screen.
    public static func petFrame(size: CGSize, on strip: WalkStrip, distance: CGFloat) -> CGRect {
        let d = min(max(0, distance), maximumDistance(for: size, on: strip))
        switch strip.edge {
        case .bottom:
            // Bottom edge of the pet sits exactly on the Dock's top edge.
            return CGRect(x: strip.start + d, y: strip.baseline, width: size.width, height: size.height)
        case .left:
            // Left edge of the pet sits exactly on the Dock's right edge.
            return CGRect(x: strip.baseline, y: strip.start + d, width: size.width, height: size.height)
        case .right:
            // Right edge of the pet sits exactly on the Dock's left edge, so the pet
            // extends leftwards away from the Dock.
            return CGRect(x: strip.baseline - size.width, y: strip.start + d, width: size.width, height: size.height)
        }
    }
}

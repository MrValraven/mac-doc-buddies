//
//  GeometryTests.swift — assertions for DockPetCore.Geometry
//
//  Wherever possible the fixtures below are the *measured* values from PROBE.md rather
//  than invented ones, so a regression here means a real disagreement with the machine.
//

import Foundation
import CoreGraphics
import DockPetCore

// MARK: - Fixtures, measured on the target machine (see PROBE.md)

private enum Measured {
    /// Built-in Retina, primary, origin (0,0). Run 1: Dock at bottom, tilesize 54.
    static let primaryFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let dockBottom = ScreenGeometry(
        frame: primaryFrame,
        visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 869))

    /// Run 2: same screen, Dock moved to the left.
    static let dockLeft = ScreenGeometry(
        frame: primaryFrame,
        visibleFrame: CGRect(x: 80, y: 0, width: 1432, height: 949))

    /// Run 5: Dock at bottom with tilesize 128 — a taller Dock.
    static let dockBottomLarge = ScreenGeometry(
        frame: primaryFrame,
        visibleFrame: CGRect(x: 0, y: 125, width: 1512, height: 824))

    /// Screen 1: external 27G2G4, no Dock, menu bar only. Note the negative AppKit y.
    static let secondaryNoDock = ScreenGeometry(
        frame: CGRect(x: 1512, y: -98, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1512, y: -98, width: 1920, height: 1050))

    /// Dock-owned layer-20 window as reported by CGWindowListCopyWindowInfo (Run 1).
    static let dockWindowCG = CGRect(x: 0, y: 0, width: 1512, height: 982)

    /// Dock tile bounds from the Accessibility API, in AppKit space. Run 6: tilesize 54,
    /// 14 items (12 tiles at 58 pt and 2 separators at 26 pt). The Dock is centred, so
    /// this is less than half the 1512 pt screen — which is the point of confining it.
    static let dockTilesAppKit = CGRect(x: 381.9, y: 10, width: 748.2, height: 74)

    /// Run 6 again, one second after launching Calculator: a 15th item, and the whole
    /// Dock re-centred. The pet has to follow both, not just the width.
    static let dockTilesPlusOne = CGRect(x: 352.9, y: 10, width: 806.2, height: 74)

    /// Desktop-wallpaper window for screen 1, in CG space (Run 1, window #46071).
    static let secondaryWallpaperCG = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
}

private let petSize = CGSize(width: 50, height: 50)

// MARK: - Tests

enum GeometryTests {
    static func run() {
        section("coordinate conversion (SPEC §8 trap 1)")

        // A hypothetical Dock strip 80 pt tall along the bottom of the primary screen.
        eq(Geometry.flipCGToAppKit(CGRect(x: 0, y: 902, width: 1512, height: 80),
                                   primaryFrame: Measured.primaryFrame),
           CGRect(x: 0, y: 0, width: 1512, height: 80),
           "bottom strip: CG y=902 h=80 -> AppKit y=0")

        // The real, measured Dock window covers the whole primary screen.
        eq(Geometry.flipCGToAppKit(Measured.dockWindowCG, primaryFrame: Measured.primaryFrame),
           Measured.primaryFrame,
           "measured Dock window flips onto the primary frame exactly")

        // Round trip against measured data: screen 1's wallpaper window in CG space must
        // flip onto screen 1's AppKit frame. This is the negative-y case that silently
        // breaks naive conversions.
        eq(Geometry.flipCGToAppKit(Measured.secondaryWallpaperCG, primaryFrame: Measured.primaryFrame),
           Measured.secondaryNoDock.frame,
           "measured screen-1 wallpaper window (CG y=0) -> AppKit y=-98")

        // ...and back again.
        eq(Geometry.flipAppKitToCG(Measured.secondaryNoDock.frame, primaryFrame: Measured.primaryFrame),
           Measured.secondaryWallpaperCG,
           "and back: AppKit y=-98 -> CG y=0")

        // A screen mounted *above* the primary: positive AppKit y, negative CG y.
        let aboveAppKit = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        let aboveCG = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        eq(Geometry.flipCGToAppKit(aboveCG, primaryFrame: Measured.primaryFrame), aboveAppKit,
           "screen above primary: CG y=-1080 -> AppKit y=982")
        eq(Geometry.flipAppKitToCG(aboveAppKit, primaryFrame: Measured.primaryFrame), aboveCG,
           "screen above primary round-trips")

        // The transform must be an involution for any rect.
        let arbitrary = CGRect(x: -37.5, y: 411.25, width: 13, height: 7.5)
        eq(Geometry.flipAppKitToCG(Geometry.flipCGToAppKit(arbitrary, primaryFrame: Measured.primaryFrame),
                                   primaryFrame: Measured.primaryFrame),
           arbitrary, "flip is its own inverse")

        section("dock edge detection")

        eq(Geometry.dockEdge(of: Measured.dockBottom), .bottom, "measured bottom Dock -> .bottom")
        eq(Geometry.dockEdge(of: Measured.dockLeft), .left, "measured left Dock -> .left")
        eq(Geometry.dockEdge(of: Measured.dockBottomLarge), .bottom, "tilesize 128 -> still .bottom")
        eq(Geometry.dockEdge(of: Measured.secondaryNoDock), nil,
           "measured Dock-less second screen -> nil")

        // Mirror of the measured left-Dock case; Dock on the right was not captured live.
        let dockRight = ScreenGeometry(frame: Measured.primaryFrame,
                                       visibleFrame: CGRect(x: 0, y: 0, width: 1432, height: 949))
        eq(Geometry.dockEdge(of: dockRight), .right, "right Dock -> .right")

        // A screen with only a menu bar inset must never read as a Dock.
        let menuBarOnly = ScreenGeometry(frame: Measured.primaryFrame,
                                         visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 949))
        eq(Geometry.dockEdge(of: menuBarOnly), nil, "menu-bar-only inset is not a Dock")

        section("walk strip")

        guard let bottomStrip = Geometry.walkStrip(on: Measured.dockBottom) else {
            Harness.bail("no strip for measured bottom Dock")
        }
        eq(bottomStrip.baseline, 80, "bottom strip baseline is visibleFrame.minY")
        eq(bottomStrip.start, 0, "bottom strip starts at visibleFrame.minX")
        eq(bottomStrip.end, 1512, "bottom strip ends at visibleFrame.maxX")
        eq(bottomStrip.length, 1512, "bottom strip spans the full screen width")
        check(bottomStrip.axis == .horizontal, "bottom strip is horizontal")

        guard let largeStrip = Geometry.walkStrip(on: Measured.dockBottomLarge) else {
            Harness.bail("no strip for tilesize 128")
        }
        eq(largeStrip.baseline, 125, "taller Dock raises the baseline to 125")

        // .anyEdge: these assertions are about the geometry being correct, not about the
        // app's [M6] policy of refusing to walk vertically. ConfigTests covers the policy.
        guard let leftStrip = Geometry.walkStrip(on: Measured.dockLeft, policy: .anyEdge) else {
            Harness.bail("no strip for measured left Dock")
        }
        eq(leftStrip.baseline, 80, "left strip baseline is visibleFrame.minX")
        eq(leftStrip.start, 0, "left strip starts at visibleFrame.minY")
        eq(leftStrip.end, 949, "left strip ends at visibleFrame.maxY")
        check(leftStrip.axis == .vertical, "left strip is vertical")

        check(Geometry.walkStrip(on: Measured.secondaryNoDock, policy: .anyEdge) == nil,
              "no strip on the Dock-less screen, under any policy")

        section("pet placement")

        let atStart = Geometry.petFrame(size: petSize, on: bottomStrip, distance: 0)
        eq(atStart, CGRect(x: 0, y: 80, width: 50, height: 50),
           "M2: 50x50 at the left end, bottom edge exactly on the Dock's top edge")
        eq(atStart.minY, Measured.dockBottom.visibleFrame.minY,
           "pet.minY == visibleFrame.minY (this is the M2 acceptance criterion)")

        eq(Geometry.maximumDistance(for: petSize, on: bottomStrip), 1462,
           "max travel is strip length minus pet width")
        eq(Geometry.petFrame(size: petSize, on: bottomStrip, distance: 1462).maxX, 1512,
           "at max distance the pet's right edge touches the strip end")

        // Clamping: walking past either end parks the pet, never overhangs.
        eq(Geometry.petFrame(size: petSize, on: bottomStrip, distance: 99999),
           CGRect(x: 1462, y: 80, width: 50, height: 50), "overshoot clamps to the far end")
        eq(Geometry.petFrame(size: petSize, on: bottomStrip, distance: -500),
           CGRect(x: 0, y: 80, width: 50, height: 50), "undershoot clamps to the near end")

        // Side Docks: the pet rests against the Dock's inner edge, not on top of it.
        eq(Geometry.petFrame(size: petSize, on: leftStrip, distance: 0),
           CGRect(x: 80, y: 0, width: 50, height: 50),
           "left Dock: pet's left edge on the Dock's right edge")

        guard let rightStrip = Geometry.walkStrip(on: dockRight, policy: .anyEdge) else {
            Harness.bail("no strip for right Dock")
        }
        eq(Geometry.petFrame(size: petSize, on: rightStrip, distance: 0),
           CGRect(x: 1382, y: 0, width: 50, height: 50),
           "right Dock: pet sits left of the Dock, maxX on the Dock's left edge")
        eq(Geometry.petFrame(size: petSize, on: rightStrip, distance: 0).maxX, rightStrip.baseline,
           "right Dock: pet.maxX == visibleFrame.maxX")

        section("strip confined to the Dock's tiles (SPEC §4b [M8])")

        // With no measurement, behaviour is unchanged: the full visibleFrame width.
        guard let unconfined = Geometry.walkStrip(on: Measured.dockBottom, tiles: nil) else {
            Harness.bail("no strip for bottom Dock")
        }
        eq(unconfined.start, 0, "tiles=nil keeps the old full-width start")
        eq(unconfined.end, 1512, "tiles=nil keeps the old full-width end")

        // With a measurement, the strip spans the tiles only.
        guard let confined = Geometry.walkStrip(on: Measured.dockBottom,
                                                tiles: Measured.dockTilesAppKit) else {
            Harness.bail("no strip for a tile-confined bottom Dock")
        }
        eq(confined.start, 381.9, "confined strip starts at Finder's left edge")
        eq(confined.end, 1130.1, "confined strip ends at Trash's right edge")
        eq(confined.baseline, 80, "confining does not disturb the baseline")
        eq(confined.length, 748.2, "confined strip is the tile width, not the screen width")

        // The tile rect's own y is ignored: the baseline comes from visibleFrame, which
        // PROBE.md F1 shows is the trustworthy source for the Dock's top edge.
        eq(confined.baseline, Measured.dockBottom.visibleFrame.minY,
           "baseline comes from visibleFrame, not from the tile rect's y")

        // The pet must actually stand over the tiles.
        eq(Geometry.petFrame(size: petSize, on: confined, distance: 0),
           CGRect(x: 381.9, y: 80, width: 50, height: 50), "pet starts on the leftmost tile")
        eq(Geometry.petFrame(size: petSize, on: confined, distance: 99999),
           CGRect(x: 1080.1, y: 80, width: 50, height: 50),
           "pet stops at the rightmost tile, not the screen edge")

        // Run 6: opening one app widens the Dock *and* re-centres it. Both ends move, and
        // the strip has to follow both — tracking width alone would drift the pet left.
        guard let grown = Geometry.walkStrip(on: Measured.dockBottom,
                                             tiles: Measured.dockTilesPlusOne) else {
            Harness.bail("no strip for the grown Dock")
        }
        eq(grown.start, 352.9, "a new dock item moves the left end outward")
        eq(grown.end, 1159.1, "a new dock item moves the right end outward")
        eq(grown.length, 806.2, "one 58 pt tile widens the strip by 58 pt")

        // A tile rect wider than the screen is clipped to the screen, never beyond it.
        guard let clipped = Geometry.walkStrip(
            on: Measured.dockBottom,
            tiles: CGRect(x: -200, y: 0, width: 2000, height: 80)) else {
            Harness.bail("no strip for an oversized tile rect")
        }
        eq(clipped.start, 0, "tile rect off the left edge clips to visibleFrame.minX")
        eq(clipped.end, 1512, "tile rect off the right edge clips to visibleFrame.maxX")

        // A tile rect that does not overlap the screen is not a measurement we can trust;
        // fall back to the full width rather than parking the pet off-screen.
        guard let disjoint = Geometry.walkStrip(
            on: Measured.dockBottom,
            tiles: CGRect(x: 5000, y: 0, width: 200, height: 80)) else {
            Harness.bail("no strip for a disjoint tile rect")
        }
        eq(disjoint.start, 0, "tile rect off this screen falls back to full width (start)")
        eq(disjoint.end, 1512, "tile rect off this screen falls back to full width (end)")

        // An empty rect is what a failed AX read degrades to; it must not strand the pet.
        guard let empty = Geometry.walkStrip(on: Measured.dockBottom, tiles: .zero) else {
            Harness.bail("no strip for an empty tile rect")
        }
        eq(empty.length, 1512, "an empty tile rect falls back to full width")

        // [M6] A side Dock is still rejected by policy, measurement or not.
        check(Geometry.walkStrip(on: Measured.dockLeft, tiles: Measured.dockTilesAppKit) == nil,
              "a side Dock stays rejected under .horizontalOnly even with tiles")

        // A vertical strip confines along y, not x.
        guard let leftConfined = Geometry.walkStrip(
            on: Measured.dockLeft, policy: .anyEdge,
            tiles: CGRect(x: 0, y: 300, width: 80, height: 400)) else {
            Harness.bail("no strip for a confined left Dock")
        }
        eq(leftConfined.start, 300, "left Dock confines along y (start)")
        eq(leftConfined.end, 700, "left Dock confines along y (end)")
        eq(leftConfined.baseline, 80, "left Dock baseline is still the inner edge")

        section("degenerate cases")

        // A strip shorter than the pet must not produce a negative travel range.
        let tiny = WalkStrip(edge: .bottom, baseline: 10, start: 0, end: 20)
        eq(Geometry.maximumDistance(for: petSize, on: tiny), 0,
           "strip shorter than the pet yields zero travel, not negative")
        eq(Geometry.petFrame(size: petSize, on: tiny, distance: 10),
           CGRect(x: 0, y: 10, width: 50, height: 50), "pet parks at the start on a tiny strip")

    }
}

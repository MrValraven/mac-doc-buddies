//
//  DockLocator.swift — finds the walkable strip.
//
//  Two independent questions, per SPEC §4:
//    * where is the Dock's inner edge?   -> NSScreen.visibleFrame  (§4a)
//    * is the Dock actually on screen?   -> the window list        (§4b [M0])
//
//  The second question exists because visibleFrame cannot answer it: on macOS 26.5 the
//  Dock's space is NOT reclaimed when autohide is on (PROBE.md F4), so visibleFrame looks
//  identical whether the Dock is visible or hidden.
//

import AppKit
import CoreGraphics
import DockPetCore

/// Where the pet should stand right now.
struct DockLocation {
    let screen: NSScreen
    let strip: WalkStrip
    /// [M8] The Dock's measured tile bounds, or nil when Accessibility is not granted and
    /// the strip is therefore the full `visibleFrame` width. Carried so the 12 fps
    /// animation tick can rebuild the same strip without repeating the AX read.
    let tiles: CGRect?
}

/// Why no location could be produced — surfaced in `--verbose` output so a wrong position
/// is always traceable to a reason.
enum DockAbsence: String {
    case dockNotOnScreen = "Dock window not on screen (autohidden, or vanished)"
    case noScreenHasDock = "no screen reports a Dock-sized inset"
    case noScreens = "no screens attached"
    /// [M6] A Dock exists, but on a side edge. The pet walks horizontally only.
    case dockNotAtBottom = "Dock is on a side edge; the pet only walks along a bottom Dock"
    /// [M6] config.json pins the pet to a display that has no Dock, or is not attached.
    case pinnedScreenUnavailable = "the screen pinned in config.json has no Dock right now"
    /// [M9] The pet is always confined to the Dock's tiles, and measuring them needs
    /// Accessibility. Without it there is nowhere legitimate to stand, so the pet waits.
    case accessibilityNotGranted = "waiting for Accessibility — needed to find the Dock's icons"
    /// [M9] Accessibility is granted but the tiles could not be read this poll.
    case tilesUnmeasurable = "Accessibility is granted but the Dock's icons could not be measured"
}

enum LocatorResult {
    case located(DockLocation)
    case absent(DockAbsence)
}

struct DockLocator {

    /// [M6] `localizedName` from config.json, or nil to follow the Dock automatically.
    var pinnedScreenName: String?

    /// [M8] The last good tile measurement, and the screen it was taken on.
    ///
    /// Kept so one transient Accessibility read failure does not snap the pet from the
    /// Dock to the full screen width and back within a single poll. Dropped whenever the
    /// Dock goes absent or moves display, so it can never outlive the layout it describes.
    private var cachedTiles: (screen: CGDirectDisplayID, rect: CGRect)?

    /// Is the Dock on screen right now?
    ///
    /// PROBE.md F5: the Dock-owned layer-20 window is present in the on-screen window list
    /// while the Dock is visible, and absent whenever autohide is on — confirmed against a
    /// control that toggled autohide back off and saw it return.
    ///
    /// The layer test is not optional. The Dock process also owns the desktop wallpaper
    /// windows (layer -2147483624, one per display, always on screen); without the layer
    /// filter those would read as a permanently-present Dock.
    ///
    /// Reads owner name and layer only — no titles, no bounds, no capture — so this needs
    /// no permission and no coordinate conversion (SPEC §4c).
    static func isDockOnScreen() -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            // Treat an unreadable window list as "cannot locate" rather than guessing.
            return false
        }
        return windows.contains { window in
            (window[kCGWindowOwnerName as String] as? String) == "Dock"
                && (window[kCGWindowLayer as String] as? Int) == dockWindowLayer
        }
    }

    /// The Dock's window level. Measured as 20 in every PROBE.md configuration.
    private static let dockWindowLayer = 20

    /// Read a live `NSScreen` into the pure form `Geometry` works with.
    static func geometry(of screen: NSScreen) -> ScreenGeometry {
        ScreenGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// Locate the strip, or explain why there isn't one.
    ///
    /// Screen selection: the Dock lives on exactly one display, and only that display
    /// reports a Dock-sized inset — PROBE.md Run 1 measured 80 pt on the built-in and
    /// exactly 0 on the external. Where more than one somehow qualifies, the larger inset
    /// wins, then the primary screen, so the choice is deterministic rather than
    /// dependent on enumeration order.
    mutating func locate() -> LocatorResult {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { cachedTiles = nil; return .absent(.noScreens) }

        // Presence first: it is the cheaper check and the one that fails most often.
        guard Self.isDockOnScreen() else { cachedTiles = nil; return .absent(.dockNotOnScreen) }

        // [M6] A pinned screen narrows the search to exactly that display.
        let searchable: [NSScreen]
        if let pinned = pinnedScreenName {
            searchable = screens.filter { $0.localizedName == pinned }
            if searchable.isEmpty { return .absent(.pinnedScreenUnavailable) }
        } else {
            searchable = screens
        }

        // Distinguish "no Dock anywhere" from "Dock is on a side edge", so the log says
        // which it is rather than leaving you guessing why the pet vanished.
        let anyDockEdge = searchable.contains { Geometry.dockEdge(of: Self.geometry(of: $0)) != nil }

        let candidates: [(screen: NSScreen, strip: WalkStrip, inset: CGFloat)] = searchable.compactMap { screen in
            let geo = Self.geometry(of: screen)
            // SPEC §4b [M6]: horizontal strips only.
            guard let strip = Geometry.walkStrip(on: geo, policy: .horizontalOnly) else { return nil }
            let inset: CGFloat
            switch strip.edge {
            case .bottom: inset = geo.bottomInset
            case .left:   inset = geo.leftInset
            case .right:  inset = geo.rightInset
            }
            return (screen, strip, inset)
        }

        guard !candidates.isEmpty else {
            cachedTiles = nil
            if pinnedScreenName != nil { return .absent(.pinnedScreenUnavailable) }
            return .absent(anyDockEdge ? .dockNotAtBottom : .noScreenHasDock)
        }

        let chosen = candidates.max { a, b in
            if abs(a.inset - b.inset) > 0.001 { return a.inset < b.inset }
            // Tie-break: prefer the primary screen (frame.origin == .zero).
            return (a.screen.frame.origin == .zero ? 1 : 0) < (b.screen.frame.origin == .zero ? 1 : 0)
        }!

        // [M9] The pet is *always* confined to the tiles, so a measurement is no longer an
        // optional upgrade — it is a precondition. Without one there is nowhere legitimate
        // to stand, and the pet waits rather than falling back to the full screen width.
        guard DockTiles.isTrusted else { return .absent(.accessibilityNotGranted) }

        // Measured only now that the screen is settled, and only on this 500 ms poll —
        // never on the 12 fps tick, which reuses what is stored here.
        guard let tiles = tiles(on: chosen.screen) else { return .absent(.tilesUnmeasurable) }

        guard let strip = Geometry.walkStrip(on: Self.geometry(of: chosen.screen),
                                             policy: .horizontalOnly,
                                             tiles: tiles) else {
            return .absent(.tilesUnmeasurable)
        }

        return .located(DockLocation(screen: chosen.screen, strip: strip, tiles: tiles))
    }

    /// A fresh tile measurement, or the last good one for this same display.
    private mutating func tiles(on screen: NSScreen) -> CGRect? {
        let id = Self.displayID(of: screen)
        if let measured = DockTiles.measure(on: screen) {
            if let id = id { cachedTiles = (id, measured) }
            return measured
        }
        // A read that failed on a *different* display tells us nothing about this one.
        guard let cached = cachedTiles, let id = id, cached.screen == id else {
            cachedTiles = nil
            return nil
        }
        return cached.rect
    }

    /// A screen's stable identity across polls. `NSScreen` instances are recreated on every
    /// display reconfiguration, so the object cannot be compared directly.
    private static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

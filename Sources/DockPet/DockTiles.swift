//
//  DockTiles.swift — the Dock's horizontal extent, via the Accessibility API.
//
//  SPEC §4b [M8]. The window list cannot answer this: PROBE.md F2 shows the Dock's only
//  layer-20 window covers the entire screen, so its rect carries no horizontal
//  information. The Accessibility API is the one remaining route to the tiles, and it is
//  the reason §4c's "no TCC" rule is now scoped to *presence* rather than to everything.
//
//  This is a strictly optional upgrade. Without the grant every call here returns nil,
//  `Geometry.walkStrip(tiles: nil)` produces the [M0] full-width strip, and the app
//  behaves exactly as it did before. Nothing on this path is load-bearing.
//

import AppKit
import ApplicationServices
import DockPetCore

/// Reads the Dock's tile bounds, when the user has granted Accessibility.
enum DockTiles {

    /// Has the user granted Accessibility to this app?
    ///
    /// Never prompts. SPEC §4c: launching must not throw a TCC dialog at anyone who
    /// only wanted a cat on their Dock.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask for the grant, showing the system dialog that deep-links to System Settings.
    ///
    /// Only ever called from an explicit menu click. Returns the trust state *before* the
    /// dialog is answered — the grant lands asynchronously, and the 500 ms poll picks it
    /// up on its own once it does.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Everything one Accessibility read of the Dock produces, before anybody decides what
    /// to do with it: the dock items, the band that filters them, and the primary frame
    /// their coordinates flip against.
    ///
    /// Factored out because `measure`, `tileFrames` and `inspect` were all doing the same
    /// four guards and the same tree walk, and the two that existed first had already
    /// drifted apart in how they spelled the guards. Three copies of a walk this fiddly is
    /// three places for the band filter to be forgotten.
    ///
    /// Returning nil is the "no measurement" answer and it must keep meaning exactly what
    /// it meant before: no grant (the normal state, since SPEC §4c makes Accessibility
    /// opt-in), no Dock process, no Dock inset on this screen, or no primary screen. Every
    /// caller degrades on nil, so nothing here is load-bearing.
    private static func survey(on screen: NSScreen)
        -> (items: [AXUIElement], band: CGRect, primaryFrame: CGRect)? {
        guard isTrusted else { return nil }
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        guard let band = band(of: screen) else { return nil }
        guard let primaryFrame = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
        else { return nil }

        let items = dockItems(under: AXUIElementCreateApplication(dock.processIdentifier),
                              depth: 0)
        return (items, band, primaryFrame)
    }

    /// The frame of every in-band dock item on `screen`, in AppKit coordinates and in Dock
    /// order, or nil if the Dock cannot be measured right now.
    ///
    /// Items are kept only if they sit inside the Dock's own band, the strip between
    /// `frame` and `visibleFrame` on the Dock's edge. That filter is what excludes an open
    /// stack's popup, whose items float above the Dock and would otherwise stretch the
    /// measurement across half the screen.
    ///
    /// Nil and `[]` are different answers and both are normal. Nil means there was no
    /// measurement to be had, which is what an ungranted app gets every time. An empty
    /// array means the Dock was read successfully and nothing survived the band filter,
    /// which is what an empty Dock looks like. `measure` collapses both to nil because a
    /// union of nothing is nothing; [M13] `NapSpot` wants the individual frames, which is
    /// why they are exposed rather than only their union.
    static func tileFrames(on screen: NSScreen) -> [CGRect]? {
        guard let survey = survey(on: screen) else { return nil }

        return survey.items.compactMap { item in
            guard let cg = frame(of: item) else { return nil }
            let appKit = Geometry.flipCGToAppKit(cg, primaryFrame: survey.primaryFrame)
            guard !appKit.isEmpty, appKit.intersects(survey.band) else { return nil }
            return appKit
        }
    }

    /// The Dock's tile bounds on `screen`, in AppKit coordinates, or nil if they cannot
    /// be measured right now.
    ///
    /// Returns the union of the individual dock-item frames rather than the enclosing
    /// `AXList` rect: the list element is padded well beyond the tiles it holds, and the
    /// union is the only value that tracks what is actually drawn.
    static func measure(on screen: NSScreen) -> CGRect? {
        guard let frames = tileFrames(on: screen), let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }

    /// One dock item, for `--dock-bounds` to print. Diagnostics only: `measure` and
    /// `tileFrames` need nothing but the frames.
    struct Item {
        let title: String
        let frame: CGRect
        let inBand: Bool
    }

    /// Every dock item with its frame and whether the band filter kept it.
    ///
    /// Deliberately not built on `tileFrames`: this one reports the items the filter
    /// *rejected* too, which is the only way `--dock-bounds` can show that a stack popup
    /// was correctly thrown away rather than never seen.
    static func inspect(on screen: NSScreen) -> [Item] {
        guard let survey = survey(on: screen) else { return [] }

        return survey.items.map { item in
            let cg = frame(of: item) ?? .zero
            let appKit = Geometry.flipCGToAppKit(cg, primaryFrame: survey.primaryFrame)
            return Item(title: (copy(item, kAXTitleAttribute) as? String) ?? "(untitled)",
                        frame: appKit,
                        inBand: !appKit.isEmpty && appKit.intersects(survey.band))
        }
    }

    /// The strip of `screen` the Dock occupies — everything between `frame` and
    /// `visibleFrame` on the Dock's edge. Nil when this screen has no Dock inset.
    private static func band(of screen: NSScreen) -> CGRect? {
        let geo = DockLocator.geometry(of: screen)
        guard let edge = Geometry.dockEdge(of: geo) else { return nil }
        let f = geo.frame, vf = geo.visibleFrame
        switch edge {
        case .bottom: return CGRect(x: f.minX, y: f.minY, width: f.width, height: vf.minY - f.minY)
        case .left:   return CGRect(x: f.minX, y: f.minY, width: vf.minX - f.minX, height: f.height)
        case .right:  return CGRect(x: vf.maxX, y: f.minY, width: f.maxX - vf.maxX, height: f.height)
        }
    }

    /// Every `AXDockItem` in the Dock's element tree.
    ///
    /// Walked rather than reached by a fixed path: the Dock's tree has changed shape
    /// across releases (one list, or a list per section), and a hardcoded index would
    /// break silently on the next one. Depth 3 covers every arrangement seen so far and
    /// bounds the recursion.
    private static func dockItems(under element: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth < 3 else { return [] }
        guard let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return children.flatMap { child -> [AXUIElement] in
            if (copy(child, kAXRoleAttribute) as? String) == (kAXDockItemRole as String) {
                return [child]
            }
            return dockItems(under: child, depth: depth + 1)
        }
    }

    /// An element's frame in CoreGraphics space (top-left origin), or nil if unreadable.
    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = copy(element, kAXPositionAttribute),
              let sizeValue = copy(element, kAXSizeAttribute) else { return nil }
        // CFTypeRef is only an AXValue if the attribute is the kind we asked for; a Dock
        // that returns something else should yield no measurement, not a crash.
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }
}

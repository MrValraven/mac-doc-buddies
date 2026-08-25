#!/usr/bin/env swift
//
//  dockprobe.swift — standalone diagnostic for DockPet (SPEC.md M0)
//
//  Run with:   swift dockprobe.swift
//  Options:    --all    also dump every on-screen window, not just Dock-level ones
//
//  Not part of the app target. No permissions required: we only read window
//  owner names and bounds, never titles and never pixels.
//

import Foundation
import AppKit
import CoreGraphics

// A window-server connection is needed for NSScreen. Touching NSApplication.shared
// establishes it without starting a run loop or showing anything.
_ = NSApplication.shared

let showAll = CommandLine.arguments.contains("--all")
let deep = CommandLine.arguments.contains("--deep")

// MARK: - Formatting helpers

func n(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

func rectString(_ r: CGRect) -> String {
    "x=\(n(r.origin.x)) y=\(n(r.origin.y)) w=\(n(r.width)) h=\(n(r.height))"
}

func rule(_ title: String) {
    print("")
    print("=== \(title) " + String(repeating: "=", count: max(0, 60 - title.count)))
}

// MARK: - Coordinate conversion (the candidate for Geometry.swift)

/// The screen whose frame origin is (0,0). Do NOT assume screens[0].
let primaryScreen = NSScreen.screens.first { $0.frame.origin == .zero }

/// CoreGraphics global coords are top-left-origin, y down.
/// AppKit coords are bottom-left-origin, y up, anchored on the primary screen.
func flipCGToAppKit(_ r: CGRect, primaryFrame: CGRect) -> CGRect {
    CGRect(x: r.origin.x,
           y: primaryFrame.maxY - (r.origin.y + r.height),
           width: r.width,
           height: r.height)
}

// MARK: - Header

let df = DateFormatter()
df.dateFormat = "yyyy-MM-dd HH:mm:ss"

rule("DOCKPROBE")
print("date            : \(df.string(from: Date()))")
print("os              : \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("host            : \(ProcessInfo.processInfo.hostName)")
print("low power mode  : \(ProcessInfo.processInfo.isLowPowerModeEnabled)")

// MARK: - Dock preferences (so each pasted run is self-labelling)

rule("DOCK PREFERENCES (com.apple.dock)")
if let d = UserDefaults(suiteName: "com.apple.dock") {
    let orientation = d.string(forKey: "orientation") ?? "bottom (default)"
    let autohide = d.object(forKey: "autohide") as? Bool
    let magnification = d.object(forKey: "magnification") as? Bool
    let tilesize = d.object(forKey: "tilesize") as? Double
    let largesize = d.object(forKey: "largesize") as? Double
    print("orientation     : \(orientation)")
    print("autohide        : \(autohide.map(String.init(describing:)) ?? "unset (false)")")
    print("magnification   : \(magnification.map(String.init(describing:)) ?? "unset (false)")")
    print("tilesize        : \(tilesize.map { n(CGFloat($0)) } ?? "unset")")
    print("largesize       : \(largesize.map { n(CGFloat($0)) } ?? "unset")")
} else {
    print("could not open com.apple.dock defaults")
}

// MARK: - Screens

rule("SCREENS (\(NSScreen.screens.count))")
if primaryScreen == nil {
    print("!! WARNING: no screen has frame.origin == (0,0). Coordinate flipping is unsafe.")
}
for (i, s) in NSScreen.screens.enumerated() {
    let isPrimary = (s.frame.origin == .zero)
    print("")
    print("screen[\(i)]\(isPrimary ? "  <-- PRIMARY (origin 0,0)" : "")")
    print("  name              : \(s.localizedName)")
    print("  frame             : \(rectString(s.frame))")
    print("  visibleFrame      : \(rectString(s.visibleFrame))")
    print("  backingScaleFactor: \(n(s.backingScaleFactor))")
    // The §4a assumption: with the Dock at the bottom, visibleFrame.minY is its top edge.
    let insetBottom = s.visibleFrame.minY - s.frame.minY
    let insetTop    = s.frame.maxY - s.visibleFrame.maxY
    let insetLeft   = s.visibleFrame.minX - s.frame.minX
    let insetRight  = s.frame.maxX - s.visibleFrame.maxX
    print("  insets (frame -> visibleFrame): bottom=\(n(insetBottom)) top=\(n(insetTop)) left=\(n(insetLeft)) right=\(n(insetRight))")
}

// MARK: - Window list

guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                           kCGNullWindowID) as? [[String: Any]] else {
    rule("WINDOW LIST")
    print("!! CGWindowListCopyWindowInfo returned nil. Cannot probe further.")
    exit(1)
}

struct WindowInfo {
    let number: Int
    let owner: String
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let onscreen: Bool
    let bounds: CGRect
    var area: CGFloat { bounds.width * bounds.height }
}

let windows: [WindowInfo] = raw.compactMap { dict in
    guard let boundsDict = dict[kCGWindowBounds as String] as? NSDictionary,
          let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
    return WindowInfo(
        number: dict[kCGWindowNumber as String] as? Int ?? -1,
        owner: dict[kCGWindowOwnerName as String] as? String ?? "<unknown>",
        pid: pid_t(dict[kCGWindowOwnerPID as String] as? Int ?? 0),
        layer: dict[kCGWindowLayer as String] as? Int ?? .min,
        alpha: dict[kCGWindowAlpha as String] as? Double ?? -1,
        onscreen: dict[kCGWindowIsOnscreen as String] as? Bool ?? false,
        bounds: bounds
    )
}

func describe(_ w: WindowInfo, indent: String = "  ") {
    print("\(indent)#\(w.number)  owner=\"\(w.owner)\" pid=\(w.pid) layer=\(w.layer) alpha=\(String(format: "%.2f", w.alpha)) onscreen=\(w.onscreen)")
    print("\(indent)   CG   (top-left origin): \(rectString(w.bounds))   area=\(n(w.area))")
    if let p = primaryScreen {
        let ak = flipCGToAppKit(w.bounds, primaryFrame: p.frame)
        print("\(indent)   AppKit (bottom-left) : \(rectString(ak))   maxY=\(n(ak.maxY))")
        for (i, s) in NSScreen.screens.enumerated() {
            let dy = ak.maxY - s.visibleFrame.minY
            let dx0 = ak.minX - s.visibleFrame.minX
            let dx1 = ak.maxX - s.visibleFrame.maxX
            print("\(indent)   vs screen[\(i)].visibleFrame: (win.maxY - vf.minY)=\(n(dy))  (win.minX - vf.minX)=\(n(dx0))  (win.maxX - vf.maxX)=\(n(dx1))")
        }
    }
}

// Owner census — verifies SPEC §8 trap 7 (macOS 26 reshuffled window ownership).
rule("OWNER CENSUS (on-screen windows)")
var census: [String: Int] = [:]
for w in windows { census[w.owner, default: 0] += 1 }
for (owner, count) in census.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }) {
    print(String(format: "  %4d  %@", count, owner))
}

// Windows owned by the Dock process.
let dockWindows = windows.filter { $0.owner == "Dock" }
rule("WINDOWS OWNED BY \"Dock\" (\(dockWindows.count))")
if dockWindows.isEmpty {
    print("  none — the owner-name assumption does NOT hold in this configuration.")
} else {
    for w in dockWindows.sorted(by: { $0.area > $1.area }) {
        print("")
        describe(w)
    }
    if let biggest = dockWindows.max(by: { $0.area < $1.area }) {
        print("")
        print("  --> largest-area Dock window is #\(biggest.number), \(rectString(biggest.bounds))")
    }
}

// Anything sitting at the Dock's window level, regardless of owner.
let dockLevel = windows.filter { $0.layer == 20 }
rule("WINDOWS AT LAYER 20 (Dock level), ANY OWNER (\(dockLevel.count))")
if dockLevel.isEmpty {
    print("  none")
} else {
    for w in dockLevel.sorted(by: { $0.area > $1.area }) {
        print("")
        describe(w)
    }
}

if showAll {
    rule("ALL ON-SCREEN WINDOWS (\(windows.count))")
    for w in windows.sorted(by: { $0.layer == $1.layer ? $0.area > $1.area : $0.layer > $1.layer }) {
        print(String(format: "  layer=%4d alpha=%.2f area=%9.0f  %-28@  %@",
                     w.layer, w.alpha, Double(w.area), w.owner as NSString,
                     rectString(w.bounds) as NSString))
    }
}

// MARK: - Deep probe: does ANY option set reveal per-tile Dock windows?

if deep {
    rule("DEEP PROBE — Dock windows under different CGWindowList option sets")

    let optionSets: [(String, CGWindowListOption)] = [
        (".optionOnScreenOnly + .excludeDesktopElements", [.optionOnScreenOnly, .excludeDesktopElements]),
        (".optionOnScreenOnly", [.optionOnScreenOnly]),
        (".optionAll", [.optionAll]),
        (".optionAll + .excludeDesktopElements", [.optionAll, .excludeDesktopElements]),
    ]

    for (label, opts) in optionSets {
        print("")
        print("--- \(label)")
        guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            print("    returned nil")
            continue
        }
        let dockOnes = arr.filter { ($0[kCGWindowOwnerName as String] as? String) == "Dock" }
        print("    total windows=\(arr.count)  Dock-owned=\(dockOnes.count)")
        for d in dockOnes {
            let num = d[kCGWindowNumber as String] as? Int ?? -1
            let layer = d[kCGWindowLayer as String] as? Int ?? .min
            let alpha = d[kCGWindowAlpha as String] as? Double ?? -1
            let onscreen = d[kCGWindowIsOnscreen as String] as? Bool ?? false
            var boundsDesc = "<no bounds>"
            if let bd = d[kCGWindowBounds as String] as? NSDictionary,
               let r = CGRect(dictionaryRepresentation: bd) {
                boundsDesc = rectString(r)
            }
            print("    #\(num) layer=\(layer) alpha=\(String(format: "%.2f", alpha)) onscreen=\(onscreen)  \(boundsDesc)")
        }
    }
}

rule("END")
print("")

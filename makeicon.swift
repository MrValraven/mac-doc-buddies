#!/usr/bin/env swift
//
//  makeicon.swift — generates Resources/AppIcon.icns (a cat).
//
//  Standalone, like dockprobe.swift; not part of the app target. bundle.sh runs it
//  automatically when Resources/AppIcon.icns is missing, so a fresh checkout still builds
//  a bundle with an icon.
//
//  Run manually with:  swift makeicon.swift
//

import AppKit
import Foundation

_ = NSApplication.shared

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
let icns = resources.appendingPathComponent("AppIcon.icns")

/// Apple's icon grid: the rounded shape occupies 824 of a 1024 canvas, leaving padding for
/// the shadow the system draws. Corner radius is ~22.37% of the shape's side.
let shapeRatio: CGFloat = 824.0 / 1024.0
let cornerRatio: CGFloat = 0.2237
/// The cat sits at a bit over half the shape's width, which keeps it legible at 16 px.
let glyphRatio: CGFloat = 0.58

func renderIcon(pixels: Int) -> NSBitmapImageRep {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: pixels * 4, bitsPerPixel: 32)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // Rounded-square backdrop with a soft vertical gradient.
    let shapeSide = size * shapeRatio
    let inset = (size - shapeSide) / 2
    let shapeRect = CGRect(x: inset, y: inset, width: shapeSide, height: shapeSide)
    let path = NSBezierPath(roundedRect: shapeRect,
                            xRadius: shapeSide * cornerRatio,
                            yRadius: shapeSide * cornerRatio)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.40, blue: 0.72, alpha: 1.0),   // top
        NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.36, alpha: 1.0),   // bottom
    ])!
    gradient.draw(in: path, angle: -90)

    // The cat, in white, centred on the shape.
    let glyphSide = shapeSide * glyphRatio
    let config = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let cat = NSImage(systemSymbolName: "cat.fill", accessibilityDescription: "DockPet")?
        .withSymbolConfiguration(config) {
        let s = cat.size
        // Nudged up very slightly: the glyph's visual mass sits low because of the tail.
        let rect = CGRect(x: shapeRect.midX - s.width / 2,
                          y: shapeRect.midY - s.height / 2 + shapeSide * 0.02,
                          width: s.width, height: s.height)
        cat.draw(in: rect)
    } else {
        FileHandle.standardError.write(Data("error: cat.fill symbol unavailable\n".utf8))
        exit(1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// The sizes iconutil expects in an .iconset.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

for variant in variants {
    let rep = renderIcon(pixels: variant.pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("error: could not encode \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}
print("rendered \(variants.count) sizes into \(iconset.lastPathComponent)")

// Hand off to iconutil for the .icns container.
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["--convert", "icns", "--output", icns.path, iconset.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("error: iconutil failed (\(task.terminationStatus))\n".utf8))
    exit(1)
}

// The .iconset is a build intermediate; only the .icns needs to survive.
try? fileManager.removeItem(at: iconset)

let bytes = ((try? fileManager.attributesOfItem(atPath: icns.path))?[.size] as? Int) ?? 0
print("wrote \(icns.path) (\(bytes) bytes)")

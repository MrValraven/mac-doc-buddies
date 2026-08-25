//
//  SpriteLoader.swift — finds, validates and (if necessary) generates the sprite sheet.
//
//  SPEC §5. Search order:
//
//    1. the app bundle's Resources/sprites/    — the shipped cat, copied in by bundle.sh
//    2. ~/Library/Application Support/DockPet/sprites/  — the generated placeholder
//    3. generate the placeholder into (2), then load it
//
//  The placeholder is written to Application Support rather than into the bundle because
//  bundle.sh rebuilds Contents/Resources from scratch on every run; a file written there
//  would vanish on the next build.
//

import AppKit
import CoreGraphics
import DockPetCore

struct LoadedSprite {
    let image: CGImage
    let metadata: SpriteMetadata
    /// Where it came from, for the launch log.
    let origin: String
}

/// [M6] Every state's artwork. `walk` is required; the rest are optional and fall back to
/// a frozen frame of the walk sheet.
struct SpriteSet {
    let sheets: [PetState: LoadedSprite]

    var walk: LoadedSprite { sheets[.walk]! }

    /// The sheet to draw for a state, falling back to the walk sheet.
    func sheet(for state: PetState) -> LoadedSprite { sheets[state] ?? walk }

    /// Whether this state has artwork of its own, as opposed to borrowing walk's.
    func hasOwnSheet(for state: PetState) -> Bool { sheets[state] != nil }

    /// Only animate when there is more than one frame to show. A single-frame sheet — or a
    /// state falling back to a frozen walk frame — has nothing to animate, so the timer
    /// stays suspended (SPEC §6).
    func isAnimated(_ state: PetState) -> Bool {
        guard let own = sheets[state] else { return false }
        return own.metadata.frameCount > 1
    }
}

enum SpriteLoader {

    /// File stem per state: cat_walk.png/.json, cat_idle.png/.json, and so on.
    static func sheetName(for state: PetState) -> String { "cat_\(state.rawValue)" }

    static let sheetName = sheetName(for: .walk)

    /// ~/Library/Application Support/DockPet/sprites/
    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DockPet/sprites", isDirectory: true)
    }

    /// [M6] Load every state's sheet. `walk` is required and is generated as a placeholder
    /// on first launch; the others are loaded only if present.
    ///
    /// All sheets must share `frameWidth` and `frameHeight`. Differing canvas sizes would
    /// resize the window mid-behaviour and change how far the pet may walk; padding the
    /// smaller pose to a common canvas is the standard fix and keeps the geometry stable.
    static func loadSet(palette: CatPalette = .default) throws -> (set: SpriteSet, notes: [String]) {
        var sheets: [PetState: LoadedSprite] = [:]
        var notes: [String] = []

        let walk = try load(palette: palette)
        sheets[.walk] = walk

        for state in PetState.allCases where state != .walk {
            guard let sprite = loadOptional(state: state, palette: palette) else {
                notes.append("\(state.rawValue): no sheet, using a frozen walk frame")
                continue
            }
            let m = sprite.metadata
            guard m.frameWidth == walk.metadata.frameWidth,
                  m.frameHeight == walk.metadata.frameHeight else {
                notes.append("\(state.rawValue): IGNORED — \(m.frameWidth)x\(m.frameHeight) px does not match walk's \(walk.metadata.frameWidth)x\(walk.metadata.frameHeight) px")
                continue
            }
            sheets[state] = sprite
            notes.append("\(state.rawValue): \(m.frameCount) frames at \(m.fps) fps (\(sprite.origin))")
        }

        return (SpriteSet(sheets: sheets), notes)
    }

    /// An optional per-state sheet: bundle first, then Application Support. Absent is a
    /// normal outcome, not an error.
    private static func loadOptional(state: PetState, palette: CatPalette) -> LoadedSprite? {
        let name = sheetName(for: state)
        if let png = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "sprites"),
           let json = Bundle.main.url(forResource: name, withExtension: "json", subdirectory: "sprites"),
           let sprite = try? loadSheet(png: png, json: json, origin: "app bundle", palette: palette) {
            return sprite
        }
        let dir = supportDirectory
        let png = dir.appendingPathComponent("\(name).png")
        let json = dir.appendingPathComponent("\(name).json")
        guard FileManager.default.fileExists(atPath: png.path),
              FileManager.default.fileExists(atPath: json.path) else { return nil }
        return try? loadSheet(png: png, json: json, origin: "application support", palette: palette)
    }

    /// Load the walk sheet, generating a placeholder the first time if no art exists yet.
    static func load(palette: CatPalette = .default) throws -> LoadedSprite {
        if let bundled = bundledURLs(), let sprite = try? loadSheet(png: bundled.png, json: bundled.json,
                                                                   origin: "app bundle",
                                                                   palette: palette) {
            return sprite
        }

        let dir = supportDirectory
        let png = dir.appendingPathComponent("\(sheetName).png")
        let json = dir.appendingPathComponent("\(sheetName).json")

        if FileManager.default.fileExists(atPath: png.path),
           FileManager.default.fileExists(atPath: json.path),
           let sprite = try? loadSheet(png: png, json: json, origin: "application support",
                                      palette: palette) {
            return sprite
        }

        try PlaceholderSheet.write(png: png, json: json)
        return try loadSheet(png: png, json: json, origin: "generated placeholder", palette: palette)
    }

    private static func bundledURLs() -> (png: URL, json: URL)? {
        guard let png = Bundle.main.url(forResource: sheetName, withExtension: "png",
                                        subdirectory: "sprites"),
              let json = Bundle.main.url(forResource: sheetName, withExtension: "json",
                                         subdirectory: "sprites")
        else { return nil }
        return (png, json)
    }

    private static func loadSheet(png: URL, json: URL, origin: String,
                                  palette: CatPalette) throws -> LoadedSprite {
        let data = try Data(contentsOf: json)
        let metadata = try JSONDecoder().decode(SpriteMetadata.self, from: data)

        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw LoaderError.unreadableImage(png.path)
        }

        // SPEC §5: the sidecar is authoritative, but it must agree with the actual file.
        // Validated before recolouring, so a malformed sheet still fails on its real
        // problem rather than on a swap that was never going to work.
        try metadata.validate(againstSheetWidthPx: image.width, heightPx: image.height)

        return LoadedSprite(image: SpriteRecolor.apply(palette, to: image),
                            metadata: metadata, origin: origin)
    }

    enum LoaderError: Error, CustomStringConvertible {
        case unreadableImage(String)
        case encodingFailed(String)

        var description: String {
            switch self {
            case .unreadableImage(let p): return "could not decode PNG at \(p)"
            case .encodingFailed(let p): return "could not encode PNG at \(p)"
            }
        }
    }
}

/// The stand-in sheet, generated on first launch so the whole pipeline — decode, validate,
/// slice, scale, flip — runs before any real art exists (SPEC §5).
enum PlaceholderSheet {

    static let metadata = SpriteMetadata(frameWidth: 32, frameHeight: 32, frameCount: 8, fps: 10)

    static func write(png pngURL: URL, json jsonURL: URL) throws {
        try FileManager.default.createDirectory(at: pngURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let widthPx = metadata.sheetWidthPx
        let heightPx = metadata.frameHeight

        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: widthPx, pixelsHigh: heightPx,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: widthPx * 4, bitsPerPixel: 32) else {
            throw SpriteLoader.LoaderError.encodingFailed(pngURL.path)
        }

        // Draw pixel-exactly: no antialiasing, no interpolation, integer rects only.
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw SpriteLoader.LoaderError.encodingFailed(pngURL.path)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.shouldAntialias = false
        ctx.cgContext.interpolationQuality = .none
        ctx.cgContext.clear(CGRect(x: 0, y: 0, width: widthPx, height: heightPx))

        for frame in 0..<metadata.frameCount {
            draw(frame: frame, into: ctx.cgContext)
        }

        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw SpriteLoader.LoaderError.encodingFailed(pngURL.path)
        }
        try data.write(to: pngURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: jsonURL)
    }

    /// One frame: a cycling-colour body (SPEC §5) plus two asymmetric markers.
    ///
    /// The spec asks for "a solid rectangle with a cycling colour". The markers are an
    /// addition: a solid rectangle is symmetric, so it cannot show whether the sheet was
    /// drawn upside down or whether the horizontal flip actually happened. The head marker
    /// makes orientation and flip checkable from the rendered pixels, which is the only way
    /// to verify this milestone without seeing the screen (SPEC §9).
    ///
    /// The context here is y-up (Quartz default), so `y = height - n` is the top.
    private static func draw(frame: Int, into ctx: CGContext) {
        let w = CGFloat(metadata.frameWidth)
        let h = CGFloat(metadata.frameHeight)
        let originX = CGFloat(frame * metadata.frameWidth)

        // Body: inset by 2 px, hue cycling once across the whole sheet.
        let hue = CGFloat(frame) / CGFloat(metadata.frameCount)
        let body = NSColor(calibratedHue: hue, saturation: 0.75, brightness: 0.9, alpha: 1.0)
        ctx.setFillColor(body.cgColor)
        ctx.fill(CGRect(x: originX + 2, y: 2, width: w - 4, height: h - 4))

        // Head marker: white, 6x6, top-LEFT of the frame. Flipping moves it to the right.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: originX + 3, y: h - 9, width: 6, height: 6))

        // Foot marker: black, 4x4, sliding along the bottom so successive frames differ.
        let footX = originX + 3 + CGFloat(frame) * ((w - 10) / CGFloat(metadata.frameCount))
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: footX.rounded(.down), y: 3, width: 4, height: 4))
    }
}

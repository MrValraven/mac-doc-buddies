//
//  RenderTest.swift — renders the sprite offscreen and checks the resulting pixels.
//
//  SPEC §9: "You cannot see my screen. Anything positional must be verifiable from
//  --verbose output or a unit test." Drawing is the one part of M4 that is purely visual,
//  so this renders PetView into a bitmap and inspects it, turning "does it look right"
//  into assertions that either pass or fail.
//
//  Run with:  DockPet.app/Contents/MacOS/DockPet --render-test
//

import AppKit
import CoreGraphics
import DockPetCore

enum RenderTest {

    private struct Pixel: Hashable {
        let r: UInt8, g: UInt8, b: UInt8, a: UInt8
        var isTransparent: Bool { a < 8 }
        var isWhitish: Bool { a > 200 && r > 200 && g > 200 && b > 200 }
        var description: String { "rgba(\(r),\(g),\(b),\(a))" }
    }

    private static var failures = 0
    private static var checks = 0

    private static func check(_ passed: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        checks += 1
        if passed {
            print("  ok    \(what)")
        } else {
            failures += 1
            let d = detail()
            print("  FAIL  \(what)\(d.isEmpty ? "" : " — \(d)")")
        }
    }

    /// Read one pixel, normalising whatever channel order the cached rep happens to use.
    private static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Pixel {
        guard let data = rep.bitmapData,
              x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else {
            return Pixel(r: 0, g: 0, b: 0, a: 0)
        }
        let bpp = rep.bitsPerPixel / 8
        let offset = y * rep.bytesPerRow + x * bpp
        let c0 = data[offset], c1 = data[offset + 1], c2 = data[offset + 2]
        let c3 = bpp > 3 ? data[offset + 3] : 255

        if rep.bitmapFormat.contains(.alphaFirst) {
            return Pixel(r: c1, g: c2, b: c3, a: c0)
        }
        return Pixel(r: c0, g: c1, b: c2, a: c3)
    }

    private static func render(_ view: PetView, frame: Int, facing: PetView.Facing,
                               state: PetState = .walk) -> NSBitmapImageRep? {
        view.state = state
        view.frameIndex = frame
        view.facing = facing
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Whether two renders of the same size differ anywhere.
    private static func differs(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide where pixel(a, x, y) != pixel(b, x, y) { return true }
        }
        return false
    }

    /// The bottom-most row carrying any ink, or -1 for an empty render.
    private static func bottomInkRow(_ rep: NSBitmapImageRep) -> Int {
        for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1)
        where (0..<rep.pixelsWide).contains(where: { !pixel(rep, $0, y).isTransparent }) {
            return y
        }
        return -1
    }

    private static func distinctColours(_ rep: NSBitmapImageRep) -> Set<Pixel> {
        var seen = Set<Pixel>()
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                seen.insert(pixel(rep, x, y))
            }
        }
        return seen
    }


    /// How many pixels in an RGBA8 buffer are exactly this opaque colour.
    private static func count(_ rgb: CatPalette.RGB, in rgba: [UInt8]) -> Int {
        var found = 0, i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] == 255 && rgba[i] == rgb.red
                && rgba[i + 1] == rgb.green && rgba[i + 2] == rgb.blue { found += 1 }
            i += 4
        }
        return found
    }

    private static func opaqueCount(_ rgba: [UInt8]) -> Int {
        var found = 0, i = 3
        while i < rgba.count { if rgba[i] == 255 { found += 1 }; i += 4 }
        return found
    }

    /// Recolouring, checked against the sheet that actually ships rather than against a
    /// buffer we built ourselves.
    ///
    /// CatPaletteTests already proves the swap on a synthetic buffer. What it cannot prove
    /// is that the art is drawn in the colours the palette table claims — if makesprite's
    /// inks ever drift, the swap would match nothing and every coat would silently come out
    /// orange. That is what the first check here is for.
    private static func checkRecolouring() {
        print("\ncoat recolouring")

        guard let base = try? SpriteLoader.load(palette: .base),
              let baseBytes = SpriteRecolor.rgbaBytes(of: base.image) else {
            check(false, "the base sheet could be decoded to RGBA"); return
        }

        let orangeCoat = CatPalette.base.coat
        let baseCoatPixels = count(orangeCoat, in: baseBytes)
        check(baseCoatPixels > 0,
              "the shipped sheet is drawn in the base palette, so a coat swap has something to match",
              "found no pixels of #E8954A — makesprite.swift's Ink values have drifted from CatPalette.base")

        let outline = CatPalette.RGB(hex: 0x2B2018)
        let baseOutlinePixels = count(outline, in: baseBytes)

        let grey = CatPalette.grey
        guard let greyBytes = SpriteRecolor.rgbaBytes(of: SpriteRecolor.apply(grey, to: base.image)) else {
            check(false, "the recoloured sheet could be decoded to RGBA"); return
        }

        check(count(orangeCoat, in: greyBytes) == 0,
              "no orange coat pixel survives a swap to grey",
              "\(count(orangeCoat, in: greyBytes)) pixels were left behind")
        check(count(grey.coat, in: greyBytes) == baseCoatPixels,
              "and each one became a grey coat pixel",
              "expected \(baseCoatPixels), got \(count(grey.coat, in: greyBytes))")
        check(count(outline, in: greyBytes) == baseOutlinePixels,
              "the outline is untouched, so the cat keeps its edges",
              "\(baseOutlinePixels) -> \(count(outline, in: greyBytes))")
        check(opaqueCount(greyBytes) == opaqueCount(baseBytes),
              "no pixel is erased or added — only recoloured",
              "\(opaqueCount(baseBytes)) -> \(opaqueCount(greyBytes))")

        guard let identityBytes = SpriteRecolor.rgbaBytes(of: SpriteRecolor.apply(.base, to: base.image))
        else { check(false, "the identity recolour could be decoded"); return }
        check(identityBytes == baseBytes, "choosing the base coat leaves the sheet byte-for-byte unchanged")

        // --- the bicolour split the art is responsible for ---
        //
        // The `olive` coat is specified as roughly 60% coloured to 40% white, and that
        // ratio lives in makesprite.swift's belly region, not in CatPalette. A palette can
        // recolour a region but never resize one, so if someone shrinks the belly back
        // towards its original 13% there is nothing in the colour tests that would notice
        // — the cat would just quietly stop being bicolour. This is the check that notices.
        //
        // Counted over body pixels only: the outline is not a coat colour, and including
        // it would make the split depend on how much perimeter a pose happens to have.
        let bellyPixels = count(CatPalette.base.belly, in: baseBytes)
        let stripePixels = count(CatPalette.base.stripe, in: baseBytes)
        let farLimbPixels = count(CatPalette.base.farLimb, in: baseBytes)
        let coloured = baseCoatPixels + stripePixels + farLimbPixels
        let body = coloured + bellyPixels
        if body > 0 {
            let whiteShare = Double(bellyPixels) / Double(body) * 100
            check((34.0...46.0).contains(whiteShare),
                  "the sheet is a bicolour cat — white is 34-46% of the body",
                  String(format: "white is %.1f%% (%d of %d body px)", whiteShare, bellyPixels, body))
        } else {
            check(false, "the sheet has body pixels to measure")
        }

        // Every coat must land somewhere visible, or the popup would offer a no-op.
        for palette in CatPalette.all where !palette.isIdentity {
            guard let bytes = SpriteRecolor.rgbaBytes(of: SpriteRecolor.apply(palette, to: base.image))
            else { check(false, "\(palette.id) recolours"); continue }
            check(count(palette.coat, in: bytes) == baseCoatPixels,
                  "\(palette.id) reaches every coat pixel in the real sheet",
                  "expected \(baseCoatPixels), got \(count(palette.coat, in: bytes))")
        }
    }

    static func run(spriteSet: SpriteSet, scale: Int) -> Never {
        let sprite = spriteSet.walk
        let m = sprite.metadata
        print("RenderTest — \(sprite.origin), \(m.frameCount) frames of \(m.frameWidth)x\(m.frameHeight) px at \(scale)x")

        let size = m.pointSize(scale: scale)
        let view = PetView(frame: NSRect(origin: .zero, size: size), spriteSet: spriteSet)

        check(view.sliceCount(for: .walk) == m.frameCount, "walk sheet sliced into \(m.frameCount) frames",
              "got \(view.sliceCount(for: .walk))")

        guard let right = render(view, frame: 0, facing: .right) else {
            print("  FAIL  could not render"); exit(1)
        }

        print("\nrendered \(right.pixelsWide)x\(right.pixelsHigh) px")
        let px = CGFloat(right.pixelsWide) / CGFloat(m.frameWidth)   // rendered px per art px

        // --- orientation ------------------------------------------------------------
        // The sprite must reach the bottom of its frame, because the window's bottom edge
        // is what rests on the Dock. Art that floats — or a sheet decoded upside down —
        // would leave the pet hovering above the Dock, and this is the M2 acceptance
        // criterion restated in terms of the artwork.
        var lowestOpaqueRow = -1
        var highestOpaqueRow = right.pixelsHigh
        for y in 0..<right.pixelsHigh {
            let rowHasInk = (0..<right.pixelsWide).contains { !pixel(right, $0, y).isTransparent }
            if rowHasInk {
                lowestOpaqueRow = max(lowestOpaqueRow, y)
                highestOpaqueRow = min(highestOpaqueRow, y)
            }
        }
        let scaleFactor = right.pixelsHigh / m.frameHeight
        check(lowestOpaqueRow >= right.pixelsHigh - scaleFactor,
              "the sprite reaches the bottom of the frame, so the pet stands on the Dock",
              "lowest opaque row is \(lowestOpaqueRow) of \(right.pixelsHigh)")
        check(highestOpaqueRow > 0,
              "and does not run off the top of the frame",
              "highest opaque row is \(highestOpaqueRow)")

        // The placeholder carries a white marker at the frame's top-left specifically so
        // orientation and flip can be checked; real art has no such guarantee.
        let isPlaceholder = sprite.origin == "generated placeholder"
        let markerX = Int(6 * px), markerY = Int(6 * px)
        if isPlaceholder {
            let head = pixel(right, markerX, markerY)
            check(head.isWhitish, "placeholder head marker is at the TOP-LEFT when facing right",
                  "pixel at (\(markerX),\(markerY)) is \(head.description)")
        }

        // --- horizontal flip (SPEC §5) ---------------------------------------------
        guard let left = render(view, frame: 0, facing: .left) else {
            print("  FAIL  could not render flipped"); exit(1)
        }
        if isPlaceholder {
            let mirroredX = right.pixelsWide - 1 - markerX
            check(pixel(left, mirroredX, markerY).isWhitish,
                  "placeholder head marker moves to the TOP-RIGHT when facing left")
            check(!pixel(left, markerX, markerY).isWhitish,
                  "and is no longer on the left after flipping")
        }

        // Generic and art-independent: flipping is only meaningful if the sprite is
        // asymmetric. Symmetric art would pass the mirror test below trivially.
        var asymmetric = false
        for y in 0..<right.pixelsHigh where !asymmetric {
            for x in 0..<right.pixelsWide where pixel(right, x, y) != pixel(right, right.pixelsWide - 1 - x, y) {
                asymmetric = true; break
            }
        }
        check(asymmetric, "the sprite is horizontally asymmetric, so the flip is visible")

        // The flip must mirror, not merely shift: row-reversing one must equal the other.
        var mirrorMismatches = 0
        for y in 0..<right.pixelsHigh {
            for x in 0..<right.pixelsWide where pixel(right, x, y) != pixel(left, right.pixelsWide - 1 - x, y) {
                mirrorMismatches += 1
            }
        }
        check(mirrorMismatches == 0, "flipped render is an exact mirror of the unflipped one",
              "\(mirrorMismatches) of \(right.pixelsWide * right.pixelsHigh) pixels differ")

        // --- nearest-neighbour (SPEC §5) -------------------------------------------
        // Nearest-neighbour maps every destination pixel to exactly one source pixel, so it
        // cannot introduce a colour the source does not already contain — the distinct
        // colour count is preserved. Interpolation blends neighbours and the count balloons.
        //
        // Compared against the source sheet rather than a fixed number, so this keeps
        // working when the art changes. (Counts, not the colours themselves: the rendered
        // values are colour-space converted, so 0xE8954A comes back as 0xE0823A.)
        let renderedColours = distinctColours(right)
        var sourceColourCount = 0
        if let frame0 = sprite.image.cropping(to: m.sourceRectPx(frame: 0)) {
            sourceColourCount = distinctColours(NSBitmapImageRep(cgImage: frame0)).count
        }
        check(sourceColourCount > 0, "could read the source frame's colours")
        check(renderedColours.count <= sourceColourCount,
              "scaling introduced no blended colours (nearest-neighbour)",
              "source has \(sourceColourCount) colours, render has \(renderedColours.count)")

        // --- transparency (SPEC §5) ------------------------------------------------
        let corner = pixel(right, 0, 0)
        check(corner.isTransparent, "sprite background is transparent, not filled",
              "corner pixel is \(corner.description)")

        // --- frames actually differ -------------------------------------------------
        var differingPairs = 0
        var previous: NSBitmapImageRep? = nil
        for index in 0..<m.frameCount {
            guard let rep = render(view, frame: index, facing: .right) else { continue }
            if let prev = previous {
                let differs = (0..<rep.pixelsHigh).contains { y in
                    (0..<rep.pixelsWide).contains { x in pixel(rep, x, y) != pixel(prev, x, y) }
                }
                if differs { differingPairs += 1 }
            }
            previous = rep
        }
        check(differingPairs == m.frameCount - 1, "all \(m.frameCount) frames render differently",
              "\(differingPairs) of \(m.frameCount - 1) consecutive pairs differ")

        // --- per-state sheets (M6) --------------------------------------------------
        for state in PetState.allCases {
            let hasOwn = spriteSet.hasOwnSheet(for: state)
            guard let rep = render(view, frame: 0, facing: .right, state: state) else {
                check(false, "\(state.rawValue) renders"); continue
            }
            let blank = distinctColours(rep).allSatisfy { $0.isTransparent }
            check(!blank, "\(state.rawValue) draws something (\(hasOwn ? "own sheet" : "walk fallback"))",
                  "every pixel is transparent")

            if !hasOwn {
                // A state with no sheet must show the walk sheet's first frame, not a gap.
                guard let walkFrame0 = render(view, frame: 0, facing: .right, state: .walk) else { continue }
                var identical = true
                for y in 0..<rep.pixelsHigh where identical {
                    for x in 0..<rep.pixelsWide where pixel(rep, x, y) != pixel(walkFrame0, x, y) {
                        identical = false; break
                    }
                }
                check(identical, "\(state.rawValue) falls back to the walk sheet's first frame")
            }
        }

        // --- stopped states face the viewer -----------------------------------------
        // A cat that stops walking turns towards you instead of freezing mid-stride, so
        // every stationary state carries its own front-on sheet. Those sheets are drawn
        // exactly as authored: mirroring a front pose would flip its tail curl for no
        // reason, and only the side-on walk sheet has a return trip to mirror for.
        for state in PetState.allCases where !state.isMoving {
            check(spriteSet.hasOwnSheet(for: state),
                  "\(state.rawValue) has a front-facing sheet of its own")

            guard let front = render(view, frame: 0, facing: .right, state: state),
                  let walkFrame0 = render(view, frame: 0, facing: .right, state: .walk) else {
                check(false, "\(state.rawValue) renders"); continue
            }

            check(differs(front, walkFrame0),
                  "\(state.rawValue) draws its own pose rather than the side-on walk frame")

            let bottom = bottomInkRow(front)
            check(bottom >= front.pixelsHigh - scaleFactor,
                  "\(state.rawValue) reaches the bottom of the frame, so it rests on the Dock",
                  "lowest opaque row is \(bottom) of \(front.pixelsHigh)")

            guard let flipped = render(view, frame: 0, facing: .left, state: state) else {
                check(false, "\(state.rawValue) renders flipped"); continue
            }
            check(!differs(front, flipped),
                  "\(state.rawValue) draws the same whichever way the pet last walked")

            // The poses are stills on purpose: SPEC §6 suspends the 12 fps timer for a
            // stationary state with nothing to animate, so a front-facing pet costs no
            // more power than the frozen walk frame it replaced. Adding a frame to one of
            // these sheets is a deliberate act, and this is where it shows up.
            check(!spriteSet.isAnimated(state),
                  "\(state.rawValue) is a still pose, so the animation timer stays suspended")
        }

        // --- integer scaling --------------------------------------------------------
        for screen in NSScreen.screens {
            let crisp = m.isCrisp(scale: scale, backingScaleFactor: screen.backingScaleFactor)
            check(crisp, "\(Int(m.devicePixelsPerArtPixel(scale: scale, backingScaleFactor: screen.backingScaleFactor))) whole device px per art px on \"\(screen.localizedName)\"")
        }

        checkRecolouring()

        print("")
        if failures > 0 {
            print("\(failures) of \(checks) checks FAILED")
            exit(1)
        }
        print("all \(checks) checks passed")
        exit(0)
    }
}

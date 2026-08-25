//
//  CatPalette.swift — the coat colour presets. Pure: colour tables and a pixel remap, no
//  image decoding and no file IO.
//
//  The art is drawn from eight flat colours (see makesprite.swift's `Ink`), so a coat
//  choice is an exact-match palette swap rather than a hue rotation or a second sheet:
//  every pixel that is exactly the orange coat becomes exactly the grey coat, and anything
//  that matches nothing is left alone. That keeps the 1 px outline crisp, keeps hand-drawn
//  art the user drops in from being mangled, and costs one pass over 8k pixels at load.
//
//  `outline` is deliberately not a palette entry: a warm near-black reads correctly behind
//  every coat here, and varying it made the light coats look unfinished.
//

import Foundation

public struct CatPalette: Equatable {

    /// A fully opaque colour. Alpha is never part of a palette entry — the art is either
    /// solid or transparent, and the transparent pixels are not recoloured.
    public struct RGB: Equatable, Hashable {
        public let red: UInt8
        public let green: UInt8
        public let blue: UInt8

        public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// Written as 0xRRGGBB, which is how the values are read off the art.
        public init(hex: UInt32) {
            self.init(UInt8((hex >> 16) & 0xFF), UInt8((hex >> 8) & 0xFF), UInt8(hex & 0xFF))
        }
    }

    /// Stable identifier, as written in config.json.
    public let id: String
    /// Shown in the Settings popup.
    public let displayName: String

    public let coat: RGB       // main body
    public let stripe: RGB     // tabby banding
    public let belly: RGB      // chest, underside and muzzle
    public let farLimb: RGB    // the off-side legs, shaded for depth
    public let pink: RGB       // nose, inner ear, paw pads
    public let eye: RGB

    public init(id: String, displayName: String, coat: RGB, stripe: RGB, belly: RGB,
                farLimb: RGB, pink: RGB, eye: RGB) {
        self.id = id
        self.displayName = displayName
        self.coat = coat
        self.stripe = stripe
        self.belly = belly
        self.farLimb = farLimb
        self.pink = pink
        self.eye = eye
    }

    // MARK: - The presets

    /// Orange tabby: the coat the sheet is actually drawn in, and therefore both the
    /// default and the palette every other coat is mapped *from*.
    public static let orange = CatPalette(
        id: "orange", displayName: "Orange tabby",
        coat: RGB(hex: 0xE8954A), stripe: RGB(hex: 0xC46B26), belly: RGB(hex: 0xF7DCB4),
        farLimb: RGB(hex: 0xB86324), pink: RGB(hex: 0xE890A0), eye: RGB(hex: 0x3E6B35))

    public static let grey = CatPalette(
        id: "grey", displayName: "Grey tabby",
        coat: RGB(hex: 0x9AA0A6), stripe: RGB(hex: 0x6B7076), belly: RGB(hex: 0xE6E8EA),
        farLimb: RGB(hex: 0x71767C), pink: RGB(hex: 0xE890A0), eye: RGB(hex: 0x3E6B35))

    public static let black = CatPalette(
        id: "black", displayName: "Black",
        coat: RGB(hex: 0x3A3540), stripe: RGB(hex: 0x2A262F), belly: RGB(hex: 0x56505C),
        farLimb: RGB(hex: 0x2E2A34), pink: RGB(hex: 0xC77E8E), eye: RGB(hex: 0xD9A441))

    public static let white = CatPalette(
        id: "white", displayName: "White",
        coat: RGB(hex: 0xF2EDE6), stripe: RGB(hex: 0xD8CFC2), belly: RGB(hex: 0xFFFFFF),
        farLimb: RGB(hex: 0xD5CEC3), pink: RGB(hex: 0xE890A0), eye: RGB(hex: 0x5B8FC7))

    /// Black coat, white chest and underside — the belly entry is already the chest and
    /// muzzle, so the tuxedo falls out of the existing regions without new art.
    public static let tuxedo = CatPalette(
        id: "tuxedo", displayName: "Tuxedo",
        coat: RGB(hex: 0x33303A), stripe: RGB(hex: 0x26232B), belly: RGB(hex: 0xFFFFFF),
        farLimb: RGB(hex: 0x27242D), pink: RGB(hex: 0xE8A0AE), eye: RGB(hex: 0xD9A441))

    /// The loosest fit of the six: real points cover the face, ears, legs and tail, while
    /// the sheet only has a stripe region to darken. It reads as a Siamese at 32 px, but
    /// it is an approximation rather than a faithful colourpoint.
    public static let siamese = CatPalette(
        id: "siamese", displayName: "Siamese",
        coat: RGB(hex: 0xE9DCC2), stripe: RGB(hex: 0x8A6A4E), belly: RGB(hex: 0xFBF3E4),
        farLimb: RGB(hex: 0xC0A886), pink: RGB(hex: 0xE8A0AE), eye: RGB(hex: 0x5B8FC7))

    /// Popup order. Fixed rather than sorted, so the list never reshuffles.
    public static let all: [CatPalette] = [orange, grey, black, white, tuxedo, siamese]

    public static let `default` = orange

    /// The palette the shipped art is drawn in — what every swap maps away from.
    public static let base = orange

    /// Resolve an id from config.json. Lenient about case and stray whitespace, because
    /// the file is meant to be hand-edited.
    public static func named(_ id: String) -> CatPalette? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return all.first { $0.id == key }
    }

    /// Whether this coat is the one the art already uses, in which case recolouring is a
    /// no-op worth skipping entirely.
    public var isIdentity: Bool { self ~= CatPalette.base }


    // MARK: - Recolouring

    /// The six ink substitutions this coat performs, as (find, replace) pairs.
    ///
    /// `outline` is absent on purpose (see the file header), and so is the transparent
    /// background: neither is a coat colour.
    private var substitutions: [(from: RGB, to: RGB)] {
        let base = CatPalette.base
        return [(base.coat, coat), (base.stripe, stripe), (base.belly, belly),
                (base.farLimb, farLimb), (base.pink, pink), (base.eye, eye)]
    }

    /// Swap this coat's colours into an 8-bit RGBA buffer, in place.
    ///
    /// Only fully opaque pixels whose RGB matches a base ink exactly are touched. Two
    /// consequences, both wanted:
    ///
    ///  * a sheet the user drew themselves, in colours this palette has never heard of,
    ///    comes back unchanged rather than half-recoloured;
    ///  * an antialiased edge pixel is left alone, since replacing its colour but not its
    ///    blend would leave a fringe of the old coat around the new one.
    ///
    /// Each pixel takes at most one substitution, so a coat that maps one base ink onto
    /// another base ink's value cannot cascade.
    public func recolor(rgba: inout [UInt8]) {
        guard !isIdentity else { return }
        let map = substitutions

        var i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] == 255 {
                for (from, to) in map
                where rgba[i] == from.red && rgba[i + 1] == from.green && rgba[i + 2] == from.blue {
                    rgba[i] = to.red
                    rgba[i + 1] = to.green
                    rgba[i + 2] = to.blue
                    break
                }
            }
            i += 4
        }
    }

    /// Equal in colour, ignoring the id and display name.
    private static func ~= (a: CatPalette, b: CatPalette) -> Bool {
        a.coat == b.coat && a.stripe == b.stripe && a.belly == b.belly
            && a.farLimb == b.farLimb && a.pink == b.pink && a.eye == b.eye
    }
}

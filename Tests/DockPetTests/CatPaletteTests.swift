//
//  CatPaletteTests.swift — assertions for DockPetCore.CatPalette (coat colour presets)
//

import Foundation
import CoreGraphics
import DockPetCore

enum CatPaletteTests {

    static func run() {

        section("cat palette: the catalogue")

        check(CatPalette.all.count == 6, "six coats are offered",
              detail: "got \(CatPalette.all.count)")

        let ids = CatPalette.all.map(\.id)
        check(ids == ["orange", "grey", "black", "white", "tuxedo", "siamese"],
              "in a fixed order, so the popup never reshuffles between launches",
              detail: "got \(ids)")
        check(Set(ids).count == ids.count, "with no duplicate ids")

        check(CatPalette.all.allSatisfy { !$0.displayName.isEmpty },
              "every coat has a name to show in the popup")

        check(CatPalette.default.id == "orange",
              "orange tabby is the default — it is the coat the art is actually drawn in",
              detail: "got \(CatPalette.default.id)")
        check(CatPalette.all.first == CatPalette.default,
              "and it is the first item in the popup")

        section("cat palette: lookup")

        check(CatPalette.named("grey")?.id == "grey", "a known id resolves")
        check(CatPalette.named("chartreuse") == nil, "an unknown id resolves to nil")
        check(CatPalette.named("") == nil, "an empty id resolves to nil")

        // config.json is hand-editable, so "Grey" and " grey " are things a user will type.
        check(CatPalette.named("Grey")?.id == "grey", "lookup ignores case")
        check(CatPalette.named("  grey  ")?.id == "grey", "lookup ignores surrounding space")

        section("cat palette: the base palette matches the art")

        // If makesprite.swift's Ink values ever drift from these, the recolour would
        // silently match nothing and every coat would come out orange. This is the check
        // that catches that, so it asserts the literal bytes rather than deriving them.
        let base = CatPalette.base
        check(base == CatPalette.default, "the base palette IS the orange preset")
        eqRGB(base.coat,    (0xE8, 0x95, 0x4A), "base coat is makesprite's Ink.coat")
        eqRGB(base.stripe,  (0xC4, 0x6B, 0x26), "base stripe is makesprite's Ink.stripe")
        eqRGB(base.belly,   (0xF7, 0xDC, 0xB4), "base belly is makesprite's Ink.belly")
        eqRGB(base.farLimb, (0xB8, 0x63, 0x24), "base farLimb is makesprite's Ink.farLimb")
        eqRGB(base.pink,    (0xE8, 0x90, 0xA0), "base pink is makesprite's Ink.pink")
        eqRGB(base.eye,     (0x3E, 0x6B, 0x35), "base eye is makesprite's Ink.eye")

        section("cat palette: the coats are actually different")

        let coats = CatPalette.all.map(\.coat)
        check(Set(coats).count == coats.count,
              "no two coats share a colour — a duplicate would be a popup entry that does nothing")

        for palette in CatPalette.all where palette.id != "orange" {
            check(!palette.isIdentity, "\(palette.id) changes something")
        }
        check(CatPalette.default.isIdentity,
              "orange is the identity palette, so choosing it costs no work")

        section("cat palette: recolouring pixels")

        // One pixel of every ink the art uses, plus two the art does not: an unknown
        // colour and a fully transparent pixel.
        func sample() -> [UInt8] {
            var px: [UInt8] = []
            for rgb in [base.coat, base.stripe, base.belly, base.farLimb, base.pink, base.eye] {
                px += [rgb.red, rgb.green, rgb.blue, 255]
            }
            px += [0x2B, 0x20, 0x18, 255]   // the outline, which no palette owns
            px += [0x12, 0x34, 0x56, 255]   // a colour from art we did not draw
            px += [0, 0, 0, 0]              // transparent
            return px
        }

        func pixel(_ buffer: [UInt8], _ index: Int) -> [UInt8] {
            Array(buffer[(index * 4)..<(index * 4 + 4)])
        }

        var identity = sample()
        CatPalette.default.recolor(rgba: &identity)
        check(identity == sample(), "the orange palette leaves every pixel untouched")

        let grey = CatPalette.named("grey")!
        var swapped = sample()
        grey.recolor(rgba: &swapped)

        check(pixel(swapped, 0) == [grey.coat.red, grey.coat.green, grey.coat.blue, 255],
              "a coat pixel becomes the new coat colour", detail: "got \(pixel(swapped, 0))")
        check(pixel(swapped, 1) == [grey.stripe.red, grey.stripe.green, grey.stripe.blue, 255],
              "a stripe pixel becomes the new stripe colour")
        check(pixel(swapped, 2) == [grey.belly.red, grey.belly.green, grey.belly.blue, 255],
              "a belly pixel becomes the new belly colour")
        check(pixel(swapped, 3) == [grey.farLimb.red, grey.farLimb.green, grey.farLimb.blue, 255],
              "a far-limb pixel becomes the new far-limb colour")
        check(pixel(swapped, 4) == [grey.pink.red, grey.pink.green, grey.pink.blue, 255],
              "a nose pixel becomes the new pink")
        check(pixel(swapped, 5) == [grey.eye.red, grey.eye.green, grey.eye.blue, 255],
              "an eye pixel becomes the new eye colour")

        check(pixel(swapped, 6) == [0x2B, 0x20, 0x18, 255],
              "the outline survives — it is not a palette entry")
        check(pixel(swapped, 7) == [0x12, 0x34, 0x56, 255],
              "a colour the base palette does not contain passes through unchanged, so "
              + "hand-supplied art degrades to 'not recoloured' rather than to nonsense")
        check(pixel(swapped, 8) == [0, 0, 0, 0],
              "a transparent pixel stays transparent")

        // A partially transparent pixel would be an antialiased edge — the art has none,
        // and recolouring one would leave a fringe of the old coat behind.
        var edge: [UInt8] = [base.coat.red, base.coat.green, base.coat.blue, 128]
        grey.recolor(rgba: &edge)
        check(edge == [base.coat.red, base.coat.green, base.coat.blue, 128],
              "a semi-transparent pixel is left alone", detail: "got \(edge)")

        var empty: [UInt8] = []
        grey.recolor(rgba: &empty)
        check(empty.isEmpty, "an empty buffer is handled without crashing")

        // Every preset must move all four *coat* inks — coat, stripe, belly and far limb.
        // Missing one leaves an orange patch on an otherwise grey cat, which is the most
        // likely way to get a palette wrong.
        let coatInks = ["coat", "stripe", "belly", "farLimb"]
        for palette in CatPalette.all where !palette.isIdentity {
            var buffer = sample()
            palette.recolor(rgba: &buffer)
            let untouched = (0..<4).filter { pixel(buffer, $0) == pixel(sample(), $0) }
            check(untouched.isEmpty,
                  "\(palette.id) leaves no coat region orange",
                  detail: "\(untouched.map { coatInks[$0] }) came back unchanged")
        }

        // The nose and the eyes are a different matter: a grey tabby really does have a
        // pink nose and green eyes, so sharing orange's values there is correct, not a
        // forgotten entry. Only the coats have to differ.
        check(CatPalette.named("grey")!.pink == base.pink,
              "grey keeps the pink nose on purpose")
        check(CatPalette.named("black")!.eye != base.eye,
              "black gets its own eye colour")
    }

    private static func eqRGB(_ got: CatPalette.RGB, _ want: (UInt8, UInt8, UInt8),
                              _ what: String, file: String = #fileID, line: UInt = #line) {
        Harness.check(got.red == want.0 && got.green == want.1 && got.blue == want.2, what,
                      detail: String(format: "expected #%02X%02X%02X, got #%02X%02X%02X",
                                     want.0, want.1, want.2, got.red, got.green, got.blue),
                      file: file, line: line)
    }
}

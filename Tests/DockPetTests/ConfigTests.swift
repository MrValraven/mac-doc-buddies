//
//  ConfigTests.swift — assertions for DockPetCore.PetConfig and Geometry.StripPolicy (M6)
//

import Foundation
import CoreGraphics
import DockPetCore

enum ConfigTests {

    private static func decode(_ json: String) -> PetConfig? {
        try? JSONDecoder().decode(PetConfig.self, from: Data(json.utf8))
    }

    static func run() {

        section("config: the user's name (M10)")

        check(PetConfig.default.userName == nil,
              "no name is configured by default — the app falls back to the account name")
        eq(decode(#"{"userName":"Tiago"}"#)?.userName, "Tiago", "a name decodes")
        eq(decode("{}")?.userName, nil, "a config without a name gets none")

        // A name is typed into a text field, so it arrives with whatever the user typed.
        let padded = PetConfig(userName: "  Tiago  ").validated()
        eq(padded.config.userName, "Tiago", "a name is trimmed rather than rejected")
        check(padded.corrections.isEmpty, "and trimming is silent — it is not a correction")

        let blank = PetConfig(userName: "   ").validated()
        eq(blank.config.userName, nil, "a name of only spaces becomes no name")

        let long = PetConfig(userName: String(repeating: "a", count: 200)).validated()
        check((long.config.userName?.count ?? 0) <= 32,
              "an absurdly long name is cut down, so the bubble cannot grow off-screen",
              detail: "\(long.config.userName?.count ?? 0) characters")
        check(long.corrections.contains { $0.field == "userName" },
              "and that truncation is reported, not silent")

        section("config: parsing")

        let full = decode(#"{"speed":45,"scale":3,"screen":"Built-in Retina Display"}"#)
        check(full?.speed == 45 && full?.scale == 3 && full?.screen == "Built-in Retina Display",
              "a complete config decodes", detail: "\(String(describing: full))")

        // A hand-edited file will often set only one key.
        let partial = decode(#"{"speed":60}"#)
        check(partial?.speed == 60, "a partial config decodes the key it has")
        check(partial?.scale == PetConfig.default.scale,
              "and falls back to the default for the keys it lacks",
              detail: "scale=\(String(describing: partial?.scale))")
        check(partial?.screen == nil, "screen defaults to auto when absent")

        check(decode("{}") == PetConfig.default, "an empty object is the default config")

        check(PetConfig.default.menuBarIcon,
              "the menu bar icon defaults ON — it is the only way to see the app is running")
        check(decode(#"{"menuBarIcon":false}"#)?.menuBarIcon == false,
              "the menu bar icon can be turned off")
        check(decode(#"{"speed":30}"#)?.menuBarIcon == true,
              "a config that omits menuBarIcon still gets the icon")

        // [M8] Confinement is on by default: a pet crossing empty desktop is the bug this
        // setting exists to fix, so the fix should not need opting into.
        check(decode("{}") == PetConfig.default, "an empty object is the default config")

        check(PetConfig.default.menuBarIcon,
              "the menu bar icon defaults ON — it is the only way to see the app is running")
        check(decode(#"{"menuBarIcon":false}"#)?.menuBarIcon == false,
              "the menu bar icon can be turned off")
        check(decode(#"{"speed":30}"#)?.menuBarIcon == true,
              "a config that omits menuBarIcon still gets the icon")

        // [M9] confineToDock was removed — the pet is always confined to the Dock's tiles.
        // An older config file still carrying the key must be accepted and the key ignored,
        // not rejected outright.
        check(decode(#"{"speed":40,"confineToDock":false}"#)?.speed == 40,
              "a config still carrying the old confineToDock key is accepted and ignored")
        check(decode("not json") == nil, "malformed JSON fails to decode rather than half-parsing")

        do {
            let data = try JSONEncoder().encode(PetConfig.default)
            check((try? JSONDecoder().decode(PetConfig.self, from: data)) == PetConfig.default,
                  "the default config round-trips through JSON")
        } catch {
            check(false, "default config encodes", detail: "\(error)")
        }

        section("config: validation clamps rather than refusing to launch")

        let zeroSpeed = PetConfig(speed: 0, scale: 2).validated()
        eq(CGFloat(zeroSpeed.config.speed), CGFloat(PetConfig.default.speed),
           "speed 0 falls back to the default")
        check(zeroSpeed.corrections.contains { $0.field == "speed" }, "and says so")

        let negativeSpeed = PetConfig(speed: -30, scale: 2).validated()
        eq(CGFloat(negativeSpeed.config.speed), CGFloat(PetConfig.default.speed),
           "a negative speed falls back to the default")

        let nanSpeed = PetConfig(speed: .nan, scale: 2).validated()
        check(nanSpeed.config.speed.isFinite, "NaN speed is replaced with a finite value")

        let hugeSpeed = PetConfig(speed: 100_000, scale: 2).validated()
        eq(CGFloat(hugeSpeed.config.speed), 500, "an absurd speed is clamped to 500")

        let zeroScale = PetConfig(speed: 30, scale: 0).validated()
        check(zeroScale.config.scale == PetConfig.default.scale,
              "scale 0 falls back to the default — SPEC §5 needs an integer >= 1")

        let negScale = PetConfig(speed: 30, scale: -2).validated()
        check(negScale.config.scale >= 1, "a negative scale is rejected")

        let hugeScale = PetConfig(speed: 30, scale: 99).validated()
        check(hugeScale.config.scale == 8, "an absurd scale is clamped to 8")

        let blankScreen = PetConfig(speed: 30, scale: 2, screen: "   ").validated()
        check(blankScreen.config.screen == nil, "a blank screen name means auto")

        let good = PetConfig(speed: 30, scale: 2, screen: "27G2G4").validated()
        check(good.corrections.isEmpty, "a sane config produces no corrections")
        check(good.config.screen == "27G2G4", "and keeps the pinned screen")

        section("config: coat colour")

        check(PetConfig.default.color == "orange",
              "the coat defaults to orange — the colour the art is drawn in",
              detail: "got \(PetConfig.default.color)")
        check(PetConfig.default.palette == CatPalette.orange,
              "and resolves to the orange palette")

        check(decode(#"{"color":"grey"}"#)?.color == "grey", "a coat can be chosen in the file")
        check(decode(#"{"color":"grey"}"#)?.palette == CatPalette.grey,
              "and resolves to that palette")
        check(decode(#"{"speed":40}"#)?.color == "orange",
              "a config that omits the coat still gets orange")

        // Every id offered in the popup must survive a write/read cycle, or picking a coat
        // would not stick across a relaunch.
        for palette in CatPalette.all {
            let written = PetConfig(color: palette.id)
            guard let data = try? JSONEncoder().encode(written),
                  let back = try? JSONDecoder().decode(PetConfig.self, from: data) else {
                check(false, "\(palette.id) round-trips through config.json")
                continue
            }
            check(back.color == palette.id && back.palette == palette,
                  "\(palette.id) round-trips through config.json", detail: "got \(back.color)")
        }

        let badColor = PetConfig(color: "chartreuse").validated()
        check(badColor.config.color == "orange",
              "an unknown coat falls back to orange rather than to an invisible cat",
              detail: "got \(badColor.config.color)")
        check(badColor.corrections.contains { $0.field == "color" }, "and says so in the log")
        check(badColor.config.palette == CatPalette.orange, "and resolves to a real palette")

        // config.json is hand-edited, so accept what a person would plausibly type and
        // normalise it, rather than treating it as a typo.
        let messyColor = PetConfig(color: "  Grey  ").validated()
        check(messyColor.config.color == "grey",
              "a coat typed with odd case or spacing is normalised, not rejected",
              detail: "got \(messyColor.config.color)")
        check(messyColor.corrections.isEmpty, "and that is not reported as a correction")

        check(PetConfig(color: "tuxedo").validated().corrections.isEmpty,
              "a valid coat produces no corrections")

        section("strip policy: horizontal only (M6)")

        let bottom = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                    visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 869))
        let left = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                  visibleFrame: CGRect(x: 80, y: 0, width: 1432, height: 949))
        let right = ScreenGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                   visibleFrame: CGRect(x: 0, y: 0, width: 1432, height: 949))

        check(Geometry.walkStrip(on: bottom, policy: .horizontalOnly) != nil,
              "a bottom Dock still produces a strip")
        check(Geometry.walkStrip(on: left, policy: .horizontalOnly) == nil,
              "a left Dock produces no strip — the pet walks horizontally only")
        check(Geometry.walkStrip(on: right, policy: .horizontalOnly) == nil,
              "a right Dock produces no strip either")

        // The vertical geometry is still correct; only the policy rejects it.
        check(Geometry.walkStrip(on: left, policy: .anyEdge)?.edge == .left,
              "the vertical strip is still computed correctly under .anyEdge")
        check(Geometry.walkStrip(on: right, policy: .anyEdge)?.axis == .vertical,
              "and is still vertical")

        check(Geometry.walkStrip(on: bottom) != nil,
              "the default policy is horizontal-only, so a bottom Dock works unqualified")
        check(Geometry.walkStrip(on: left) == nil,
              "and a side Dock is rejected without having to name the policy")

        check(StripPolicy.horizontalOnly.allows(.bottom), "horizontalOnly allows bottom")
        check(!StripPolicy.horizontalOnly.allows(.left), "horizontalOnly rejects left")
        check(!StripPolicy.horizontalOnly.allows(.right), "horizontalOnly rejects right")

        section("[M11] launchAtLogin")

        do {
            let json = Data(#"{"speed": 30}"#.utf8)
            let parsed = try! JSONDecoder().decode(PetConfig.self, from: json)
            eq(parsed.launchAtLogin, true, "absent launchAtLogin defaults to true")
        }

        do {
            let json = Data(#"{"launchAtLogin": false}"#.utf8)
            let parsed = try! JSONDecoder().decode(PetConfig.self, from: json)
            eq(parsed.launchAtLogin, false, "launchAtLogin round-trips false")
        }
    }
}

//
//  Config.swift — user settings. Pure: parsing and validation only, no file IO.
//
//  SPEC §7 M6: ~/Library/Application Support/DockPet/config.json for speed, scale and
//  screen.
//

import CoreGraphics
import Foundation

public struct PetConfig: Codable, Equatable {

    /// Walking speed in points per second.
    public var speed: Double

    /// Integer sprite scale. SPEC §5 allows 2x, 3x — never a fraction.
    public var scale: Int

    /// `localizedName` of the display to pin the pet to, or `nil` to follow the Dock.
    public var screen: String?

    /// Show the status item in the menu bar. The app is otherwise invisible, so this
    /// defaults on: without it there is no way to tell DockPet is running or to quit it
    /// short of `killall`.
    public var menuBarIcon: Bool

    /// Coat colour, as a `CatPalette` id. Stored as the id rather than as the colours
    /// themselves so that a tweak to a preset reaches everyone who picked it, instead of
    /// freezing whatever the palette looked like on the day they chose it.
    public var color: String

    /// What the pet calls you when you click it and ask it to say hello.
    ///
    /// [M10] `nil` means "not configured", not "no name" — the app fills it in from the
    /// macOS account name at launch, so a greeting works without anyone opening Settings.
    /// A user who genuinely wants no name gets one by clearing the field, which validates
    /// back to `nil`; the phrasebook renders every line without a name cleanly.
    public var userName: String?

    /// [M11] Register the app as a login item. Defaults on: a pet that does not survive a
    /// reboot is gone within the week, and the app is invisible enough that nobody would
    /// think to relaunch it by hand.
    public var launchAtLogin: Bool

    /// [M11] Every cat on the Dock, capped at two.
    ///
    /// `color` and `userName` above are pet 0's, kept in sync by `validated()`. That
    /// redundancy is deliberate: every existing call site reads `config.color` meaning
    /// "the cat's coat", and rewriting all of them to `config.pets[0].color` would be a
    /// large diff whose only effect is to make an existing config.json stop working.
    public var pets: [PetProfile]

    /// [M11] `"MM-DD"`, or `nil`. On a matching day the greeting pool becomes the birthday
    /// pool.
    public var birthday: String?

    /// [M11] One line, said on the first click of the day and then not again until the
    /// date changes. `nil` means the pet has nothing extra to say.
    public var dedication: String?

    /// [M12] Whether two cats may kiss — both the occasional one that happens on its own
    /// when they meet, and the *Kiss* item in the click menu.
    ///
    /// One flag for both on purpose. Two switches would mean explaining which of them a
    /// user who "turned kissing off" had actually turned off, and a menu item that still
    /// works after you switched the feature off is a bug report waiting to be filed.
    ///
    /// Defaults on: with one cat it has nothing to govern, and someone who has gone to the
    /// trouble of adding a second cat is not looking for less from them.
    public var kisses: Bool

    /// The chosen coat, falling back to the default rather than to nothing. `validated()`
    /// has already replaced an unknown id by the time a config is in use; this fallback is
    /// for the un-validated case, where an invisible cat would be the worse answer.
    public var palette: CatPalette { CatPalette.named(color) ?? .default }

    public static let `default` = PetConfig(speed: 30, scale: 2, screen: nil, menuBarIcon: true,
                                            color: CatPalette.default.id)

    // [M9] There is no confinement setting. The pet is always confined to the Dock's
    // tiles; the only variable is whether Accessibility has been granted yet.
    public init(speed: Double = 30, scale: Int = 2, screen: String? = nil,
                menuBarIcon: Bool = true, color: String = CatPalette.default.id,
                userName: String? = nil, launchAtLogin: Bool = true,
                pets: [PetProfile] = [], birthday: String? = nil, dedication: String? = nil,
                kisses: Bool = true) {
        self.speed = speed
        self.scale = scale
        self.screen = screen
        self.menuBarIcon = menuBarIcon
        self.color = color
        self.userName = userName
        self.launchAtLogin = launchAtLogin
        self.pets = pets
        self.birthday = birthday
        self.dedication = dedication
        self.kisses = kisses
    }

    /// Missing keys fall back to the defaults, so a partial config file is valid and a
    /// user can write just `{"speed": 60}`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? PetConfig.default.speed
        self.scale = try c.decodeIfPresent(Int.self, forKey: .scale) ?? PetConfig.default.scale
        self.screen = try c.decodeIfPresent(String.self, forKey: .screen)
        self.menuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .menuBarIcon)
            ?? PetConfig.default.menuBarIcon
        self.color = try c.decodeIfPresent(String.self, forKey: .color) ?? PetConfig.default.color
        self.userName = try c.decodeIfPresent(String.self, forKey: .userName)
        self.launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
            ?? PetConfig.default.launchAtLogin
        self.pets = try c.decodeIfPresent([PetProfile].self, forKey: .pets) ?? []
        self.birthday = try c.decodeIfPresent(String.self, forKey: .birthday)
        self.dedication = try c.decodeIfPresent(String.self, forKey: .dedication)
        self.kisses = try c.decodeIfPresent(Bool.self, forKey: .kisses) ?? PetConfig.default.kisses
    }

    /// Longest name that still fits in a speech bubble beside a Dock-sized cat.
    public static let maximumNameLength = 32

    /// [M11] Two. §8.5 forbids a plugin system; this is a second hardcoded cat, and a
    /// third is a feature request rather than a config change.
    public static let maximumPets = 2

    /// [M11] Longer than this and the bubble stops fitting beside a Dock-sized cat.
    /// `BubbleGeometry` clamps the bubble to the screen, but a paragraph in a speech
    /// bubble is not what anyone means by a dedication.
    public static let maximumDedicationLength = 120

    /// What was wrong with a value, and what was used instead.
    public struct Correction: Equatable {
        public let field: String
        public let given: String
        public let used: String
    }

    /// Clamp nonsense into something usable rather than refusing to launch.
    ///
    /// A config file is hand-edited; a typo should cost you a log line, not your pet. Each
    /// correction is returned so the launch log can say exactly what was ignored.
    public func validated() -> (config: PetConfig, corrections: [Correction]) {
        var out = self
        var corrections: [Correction] = []

        if !(speed > 0) || !speed.isFinite {
            corrections.append(Correction(field: "speed", given: "\(speed)",
                                          used: "\(PetConfig.default.speed)"))
            out.speed = PetConfig.default.speed
        } else if speed > 500 {
            // Faster than this and the pet crosses a 1512 pt Dock in under three seconds.
            corrections.append(Correction(field: "speed", given: "\(speed)", used: "500.0"))
            out.speed = 500
        }

        if scale < 1 {
            corrections.append(Correction(field: "scale", given: "\(scale)",
                                          used: "\(PetConfig.default.scale)"))
            out.scale = PetConfig.default.scale
        } else if scale > 8 {
            corrections.append(Correction(field: "scale", given: "\(scale)", used: "8"))
            out.scale = 8
        }

        // A coat id is matched leniently, so "Grey" and " grey " are normalised to the
        // canonical id in silence. Only a name that matches no coat at all is a correction.
        if let palette = CatPalette.named(color) {
            out.color = palette.id
        } else {
            corrections.append(Correction(field: "color", given: "\"\(color)\"",
                                          used: PetConfig.default.color))
            out.color = PetConfig.default.color
        }

        // [M10] The name is typed into a text field and pasted into a speech bubble, so
        // it is tidied rather than trusted. Trimming is silent — it is what the user
        // meant. Truncation is not: a name long enough to push the bubble off-screen is
        // worth a line in the log saying what happened to it.
        if let name = userName {
            let tidy = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if tidy.isEmpty {
                out.userName = nil
            } else if tidy.count > Self.maximumNameLength {
                let cut = String(tidy.prefix(Self.maximumNameLength))
                corrections.append(Correction(field: "userName", given: "\"\(tidy)\"",
                                              used: "\"\(cut)\""))
                out.userName = cut
            } else {
                out.userName = tidy
            }
        }

        if let name = screen, name.trimmingCharacters(in: .whitespaces).isEmpty {
            corrections.append(Correction(field: "screen", given: "\"\(name)\"", used: "auto"))
            out.screen = nil
        }

        // [M11] `pets` is canonical when present; the legacy keys are canonical when it is
        // not. Whichever way round, they agree by the time anyone reads them.
        if out.pets.isEmpty {
            out.pets = [PetProfile(name: nil, color: out.color, userName: out.userName)]
        } else {
            if out.pets.count > Self.maximumPets {
                corrections.append(Correction(field: "pets",
                                              given: "\(out.pets.count) cats",
                                              used: "\(Self.maximumPets)"))
                out.pets = Array(out.pets.prefix(Self.maximumPets))
            }
            for index in out.pets.indices {
                if let palette = CatPalette.named(out.pets[index].color) {
                    out.pets[index].color = palette.id
                } else {
                    corrections.append(Correction(field: "pets[\(index)].color",
                                                  given: "\"\(out.pets[index].color)\"",
                                                  used: PetConfig.default.color))
                    out.pets[index].color = PetConfig.default.color
                }

                if let name = out.pets[index].userName {
                    let tidy = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.pets[index].userName = tidy.isEmpty ? nil
                        : String(tidy.prefix(Self.maximumNameLength))
                }
                if let name = out.pets[index].name {
                    let tidy = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    out.pets[index].name = tidy.isEmpty ? nil
                        : String(tidy.prefix(Self.maximumNameLength))
                }
            }
            out.color = out.pets[0].color
            out.userName = out.pets[0].userName
        }

        // A birthday that does not parse is dropped rather than kept: keeping it means a
        // config that looks configured and silently never fires.
        if let birthday, Occasion.parse(birthday) == nil {
            corrections.append(Correction(field: "birthday", given: "\"\(birthday)\"",
                                          used: "none"))
            out.birthday = nil
        }

        // The dedication shares the speech bubble with everything else, so it gets the
        // same treatment the name does: trimmed silently, truncated loudly.
        if let dedication {
            let tidy = dedication.trimmingCharacters(in: .whitespacesAndNewlines)
            if tidy.isEmpty {
                out.dedication = nil
            } else if tidy.count > Self.maximumDedicationLength {
                let cut = String(tidy.prefix(Self.maximumDedicationLength))
                corrections.append(Correction(field: "dedication", given: "\"\(tidy)\"",
                                              used: "\"\(cut)\""))
                out.dedication = cut
            } else {
                out.dedication = tidy
            }
        }

        return (out, corrections)
    }
}

/// [M11] One cat's identity. Separate from `PetConfig`, which describes the stage —
/// speed, scale, screen, menu bar — rather than an actor.
public struct PetProfile: Codable, Equatable {
    /// What this cat is called. `nil` means it has no name of its own; the meeting lines
    /// read correctly without one, per the M10 name-slot rule.
    public var name: String?
    /// Coat colour, as a `CatPalette` id.
    public var color: String
    /// What this cat calls the human.
    public var userName: String?

    public init(name: String? = nil, color: String = CatPalette.default.id,
                userName: String? = nil) {
        self.name = name
        self.color = color
        self.userName = userName
    }

    public var palette: CatPalette { CatPalette.named(color) ?? .default }

    /// Missing keys fall back to defaults, exactly as `PetConfig.init(from:)` does.
    ///
    /// Synthesised `Codable` would *throw* on an entry with no `color`, and a throw here
    /// discards the whole config file — a partial pets entry must cost a clamped value and
    /// a log line, never the user's settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decodeIfPresent(String.self, forKey: .name)
        self.color = try c.decodeIfPresent(String.self, forKey: .color) ?? CatPalette.default.id
        self.userName = try c.decodeIfPresent(String.self, forKey: .userName)
    }
}

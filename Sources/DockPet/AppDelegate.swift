//
//  AppDelegate.swift
//

import AppKit
import QuartzCore
import DockPetCore

/// Command-line options. SPEC §6 requires a `--verbose` flag.
struct LaunchOptions {
    let verbose: Bool
    /// Render the sprite offscreen, check the resulting pixels, and exit. SPEC §9: the
    /// only way to verify drawing on a machine whose screen I cannot see.
    let renderTest: Bool
    /// Drive the Settings window's controls and exit.
    let settingsTest: Bool
    /// True for any of the self-test modes. Used to keep a test run from throwing the
    /// system Accessibility dialog at whoever is running it.
    var isSelfTest: Bool { renderTest || settingsTest || menuTest || dockBounds || interactionTest }

    /// With --settings-test, also render the window to this PNG path. Rendered offscreen
    /// rather than screen-captured, which would need a Screen Recording grant (SPEC §4c).
    let shotPath: String?
    /// Exercise the menu bar item's pause/resume path and exit. A menu click cannot be
    /// scripted without Accessibility permission (§4c), so the app drives it itself.
    let menuTest: Bool
    /// [M8] Print the measured Dock tile bounds and exit. The only way to check the
    /// Accessibility measurement against a Dock I cannot see.
    let dockBounds: Bool
    /// [M10] Drive the click menu and the speech bubble and exit. A click on a floating
    /// window cannot be scripted without Accessibility (§4c), so the app clicks itself.
    let interactionTest: Bool

    init(arguments: [String]) {
        self.verbose = arguments.contains("--verbose") || arguments.contains("-v")
        self.renderTest = arguments.contains("--render-test")
        self.settingsTest = arguments.contains("--settings-test")
        self.shotPath = arguments.first { $0.hasPrefix("--shot=") }?
            .replacingOccurrences(of: "--shot=", with: "")
        self.menuTest = arguments.contains("--menu-test")
        self.dockBounds = arguments.contains("--dock-bounds")
        self.interactionTest = arguments.contains("--interaction-test")
    }
}

/// Why the animation timer is not running.
///
/// SPEC §6 requires the timer be *suspended*, not merely drawing nothing, so each of these
/// invalidates the timer outright. The 500 ms locator poll keeps running throughout and is
/// what wakes the pet back up.
///
/// [M6] There is deliberately no `occluded` case. SPEC §6 asks for suspension when the
/// frontmost app is fullscreen, and an earlier draft tracked `NSWindow.occlusionState` to
/// catch it. Measured against a real fullscreen window, that check never fired — because
/// entering fullscreen removes the Dock's window from the window list *and* zeroes the
/// screen's bottom inset, so `.dockNotLocated` already covers it half a second in. The
/// occlusion tracking was removed rather than kept as an unverified path.
enum AnimationSuspension: String {
    case dockNotLocated = "Dock not located"
    case lowPowerMode = "low power mode enabled"
    case stationary = "pet is not walking"
    case paused = "paused from the menu bar"
}

final class AppDelegate: NSObject, NSApplicationDelegate, MenuBarItemDelegate, SettingsWindowDelegate,
                         PetInteractionDelegate {

    /// [M6] Sprite scale, walk speed and pinned screen now come from config.json.

    /// SPEC §4d: 500 ms, and it keeps running while suspended so the pet can wake.
    private static let locatorInterval: TimeInterval = 0.5

    /// SPEC §6: 10–12 fps, never 60.
    private static let animationFPS: Double = 12

    let options: LaunchOptions
    private var locator = DockLocator()
    var config = PetConfig.default

    // [M11] The members below are `internal` rather than `private` because the pet-facing
    // self-tests moved to PetSelfTests.swift with the `Pet` extraction, and Swift's
    // `private` is file-scoped. Nothing outside this module can see them either way.

    /// [M11] Every pet on the Dock. Exactly one until M11d; the cap is
    /// `PetConfig.maximumPets`.
    ///
    /// SPEC §6 [M11]: the array is *driven* by the single animation timer and the single
    /// 500 ms poll below. A second cat must not double the app's wakeups — only the work
    /// done inside a wakeup.
    var pets: [Pet] = []

    /// The pet the single-pet code paths mean — the menu bar, the settings window, the
    /// self-tests. Optional rather than force-unwrapped: it is empty before
    /// `applicationDidFinishLaunching` has built anything.
    var primaryPet: Pet? { pets.first }

    /// The sheets this pet is actually drawn from — its own coat's, never the app's.
    ///
    /// Keyed on `profile.palette.id` rather than on `profile.color` so a coat name that
    /// never went through the validator still resolves to the palette the pet is really
    /// wearing, instead of missing the dictionary and leaving a cat with no art at all.
    func sprites(for pet: Pet) -> SpriteSet? { spriteSets[pet.profile.palette.id] }

    /// The sheets in the coat the config itself names — pet 0's.
    ///
    /// For the places that mean "the app's art" rather than "this cat's": the sheet
    /// summary in the status menu, `--settings-test`'s pixel counting, and the window size
    /// every pet shares. Every set holds the same art in a different colour, so any of
    /// them answers a question about geometry; only a question about colour needs the
    /// per-pet accessor above.
    var spriteSet: SpriteSet? {
        primaryPet.flatMap(sprites(for:)) ?? spriteSets[config.palette.id]
    }

    var locatorTimer: Timer?
    var animationTimer: Timer?
    private var verboseTimer: Timer?

    private var lastPollTime: CFTimeInterval = 0

    /// [M11] One recoloured `SpriteSet` per **distinct** coat, keyed by `CatPalette.id`.
    ///
    /// Not one set per pet: recolouring is a pass over every pixel of every sheet, so two
    /// cats wearing the same coat share one set — doing the same swap twice is waste, not
    /// safety. And not one set for the app either, which is what it was: `profile.color`
    /// was reported in three places while every pet was handed the single set loaded from
    /// `config.palette`, so all three would have confidently named a coat the cat was not
    /// wearing the moment the two colours differed.
    var spriteSets: [String: SpriteSet] = [:]

    var menuBarItem: MenuBarItem?
    private var settingsWindow: SettingsWindow?
    private var saveDebounce: Timer?
    /// [M11] Non-nil only while the grant is missing and someone is being shown why.
    private var onboarding: OnboardingWindow?
    private var paused = false

    /// Kept alive for the lifetime of the app; a released source stops delivering.
    var reloadSignalSource: DispatchSourceSignal?

    /// [M11] One coordinator for the pair, seeded like everything else in the app that
    /// rolls dice (SPEC §9). It owns the decision — have they met, is the cooldown up,
    /// which pair of lines — and this file only applies it.
    private var meetings = MeetingCoordinator(seed: UInt64.random(in: UInt64.min...UInt64.max))

    var currentLocation: DockLocation?
    private var lastAnimationTime: CFTimeInterval = 0
    /// Two independent transition logs. A single slot made them alternate — the location
    /// line and the animation line differ from each other, so each always looked like a
    /// change and both printed twice a second while dormant.
    private var lastLocationDescription: String?
    private var lastAnimationDescription: String?

    init(options: LaunchOptions) {
        self.options = options
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        let info = ProcessInfo.processInfo
        let policy = NSApp.activationPolicy()

        print("DockPet \(Self.versionString) launched")
        print("  pid              : \(info.processIdentifier)")
        print("  activationPolicy : \(Self.describe(policy)) (expected: accessory)")
        print("  verbose          : \(options.verbose)")
        print("  screens          : \(NSScreen.screens.count)")
        print("  quit with        : killall DockPet")

        if policy != .accessory {
            print("  !! WARNING: activation policy is not .accessory — a Dock icon will appear.")
        }

        // [M6] Config first: it decides scale, speed and which screen to use.
        let outcome = ConfigStore.load()
        config = outcome.config
        locator.pinnedScreenName = config.screen
        print("  config           : \(ConfigStore.url.path)")
        for note in outcome.notes { print("    \(note)") }

        // [M11] Skipped under any self-test: a test run must not rewrite the user's login
        // item as a side effect of checking something else.
        if !options.isSelfTest {
            if case .failure(let error) = LoginItem.setEnabled(config.launchAtLogin) {
                print("[config] could not set launch at login (\(error.localizedDescription))")
            }
            print("[config] launch at login: \(LoginItem.statusDescription)")
        }
        print("  speed            : \(Self.f(CGFloat(config.speed))) px/s at \(Int(Self.animationFPS)) fps")
        print("  scale            : \(config.scale)x")
        print("  screen           : \(config.screen ?? "auto (follow the Dock)")")
        print("  coat             : \(config.palette.displayName) (\(config.color))")
        print("  walk area        : \(dockConfinementSummary())")

        // [M8] A standalone probe, before any window exists: it needs the Accessibility
        // read and nothing else.
        if options.dockBounds { runDockBoundsProbe() }

        // [M11] Every cat this config asks for. `validated()` guarantees this is never
        // empty, so there is no fallback here — one would hide a validator bug rather than
        // fix it.
        let profiles = config.pets

        // SPEC §5: a missing or malformed walk sheet is fatal and loud, never silently
        // skipped. Optional per-state sheets are not fatal — they degrade to a still pose.
        //
        // [M11] One set per distinct coat in the cast, so each pet is handed art in the
        // colour its own profile names.
        let spriteNotes: [String]
        do {
            (spriteSets, spriteNotes) = try loadSpriteSets(for: profiles)
        } catch {
            print("  !! FATAL: could not load sprite sheet — \(error)")
            exit(1)
        }
        guard let set = spriteSet else {
            print("  !! FATAL: no sprite sheets were loaded for \(profiles.count) pet(s)")
            exit(1)
        }
        let m = set.walk.metadata
        let size = petSizeFor(set: set)

        print("  sprite           : \(set.walk.origin)")
        print("  walk sheet       : \(m.frameCount) frames, \(m.frameWidth)x\(m.frameHeight) px each, \(Self.f(CGFloat(m.fps))) fps")
        for note in spriteNotes { print("    \(note)") }
        print("  drawn at         : \(Self.f(size.width))x\(Self.f(size.height)) pt (scale \(config.scale)x)")
        for screen in NSScreen.screens {
            let ratio = m.devicePixelsPerArtPixel(scale: config.scale,
                                                  backingScaleFactor: screen.backingScaleFactor)
            let crisp = m.isCrisp(scale: config.scale, backingScaleFactor: screen.backingScaleFactor)
            print("    \"\(screen.localizedName)\": \(Self.f(ratio)) device px per art px \(crisp ? "(crisp)" : "!! NOT AN INTEGER — art will shimmer")")
        }

        buildPets(from: profiles, size: size)

        // [M11] After the pets exist, so `--render-test` can address them by index: a test
        // that can only see pet 0 would pass while a second cat is broken.
        if options.renderTest { runRenderTest() }

        print("  click menu       : \(PetPrompt.allCases.count) prompts, greeting "
              + (effectiveUserName.map { "\"\($0)\"" } ?? "nobody by name"))

        if config.menuBarIcon {
            let item = MenuBarItem(version: Self.versionString)
            item.delegate = self
            menuBarItem = item
            print("  menu bar         : status item shown (set \"menuBarIcon\": false to hide)")
        } else {
            print("  menu bar         : hidden by config; quit with killall DockPet")
        }

        // [M9] The pet is always confined to the Dock's icons, and measuring them needs
        // Accessibility. Ask once at launch when it is missing: without the grant the app
        // would otherwise start up completely invisible with no explanation of why.
        if DockTiles.isTrusted {
            print("  accessibility    : granted")
        } else if options.isSelfTest {
            print("  accessibility    : NOT granted (self-test: not prompting)")
        } else {
            print("  accessibility    : not granted — requesting it now")
            print("                     the cat stays hidden until it is granted")
            DockTiles.requestTrust()
        }

        installReloadSignalHandler()

        startLocatorTimer()
        if options.verbose { startVerboseTimer() }

        // Place the pet immediately rather than waiting out the first poll interval.
        poll()

        if options.settingsTest { runSettingsTest() }
        if options.menuTest { runMenuTest() }
        if options.interactionTest { runInteractionTest() }

        // [M11] Skipped under a self-test: a test run must not put a window on screen and
        // wait for a human. Skipped when already granted, which is the normal case for me
        // and the case this window would only be noise in.
        if !options.isSelfTest && !DockTiles.isTrusted {
            let window = OnboardingWindow(onGrant: { [weak self] in
                self?.requestDockConfinement()
            })
            onboarding = window
            // A permission prompt should take focus rather than sit behind whatever the
            // user was doing — SPEC §3's "never make key" rule is about the pet's own
            // window, not this one.
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - [M11] The cast

    /// The coats a cast needs: one entry per **distinct** palette, in first-appearance
    /// order so the launch log reads the same way twice.
    ///
    /// Resolved through `profile.palette` rather than compared on `profile.color`, so two
    /// cats whose coats are written differently but resolve to the same palette are still
    /// recognised as one coat.
    static func distinctPalettes(of profiles: [PetProfile]) -> [CatPalette] {
        var seen = Set<String>()
        return profiles.compactMap { seen.insert($0.palette.id).inserted ? $0.palette : nil }
    }

    /// [M11] One recoloured `SpriteSet` per distinct coat in a cast, keyed by palette id.
    ///
    /// Throws rather than exiting, because the two callers want opposite things from a
    /// failure: SPEC §5 makes a missing sheet fatal at launch, while a reload must keep
    /// the cat that is already on screen rather than take it away over a cosmetic setting.
    func loadSpriteSets(for profiles: [PetProfile]) throws -> (sets: [String: SpriteSet],
                                                               notes: [String]) {
        var sets: [String: SpriteSet] = [:]
        var notes: [String] = []
        let palettes = Self.distinctPalettes(of: profiles)
        for palette in palettes {
            let (set, sheetNotes) = try SpriteLoader.loadSet(palette: palette)
            sets[palette.id] = set
            // Named only when there is more than one coat to tell apart, so a single cat's
            // launch log reads exactly as it always has.
            notes += palettes.count > 1 ? sheetNotes.map { "\(palette.id): \($0)" } : sheetNotes
        }
        return (sets, notes)
    }

    /// Build `pets` from a cast and wire each one up.
    ///
    /// Shared by launch and by `rebuildPets(from:)` so that a cat added from Settings is
    /// put together exactly as one built at launch. Two constructions would drift, and the
    /// second cat is always the one that ends up with the older half.
    ///
    /// `spriteSets` must already hold a set for every coat in `profiles`.
    func buildPets(from profiles: [PetProfile], size: CGSize) {
        pets = profiles.enumerated().map { index, profile in
            guard let set = spriteSets[profile.palette.id] else {
                // Unreachable via either caller — both load the cast's coats first — but a
                // pet with no art is an invisible cat with a live mouse monitor, which is
                // worse to diagnose than a loud exit.
                print("  !! FATAL: no sheets were loaded for pet \(index)'s"
                      + " \(profile.palette.id) coat")
                exit(1)
            }
            let pet = Pet(index: index, profile: profile, spriteSet: set,
                          size: size, speed: CGFloat(config.speed))
            // SPEC §5: a sheet that does not slice into the frames it declares is fatal and
            // loud. Checked per pet, because each one slices the sheet for itself.
            let sliced = pet.view.sliceCount(for: .walk)
            if sliced != set.walk.metadata.frameCount {
                print("  !! FATAL: pet \(index) sliced \(sliced) frames but the walk sheet"
                      + " declares \(set.walk.metadata.frameCount)")
                exit(1)
            }
            // [M10] The pet becomes clickable from here on. The window still ignores mouse
            // events by default; the interaction only switches that on while the cursor is
            // actually over the cat, so the Dock keeps every other click.
            pet.interaction.delegate = self
            // [M11] A self-test must not consume the once-a-day dedication or swap in a
            // birthday greeting — see PetInteraction.isSelfTest.
            pet.interaction.isSelfTest = options.isSelfTest
            pet.interaction.attach(to: pet.view, in: pet.window)
            pet.applyBehaviorState(pet.behavior.state, spriteSet: set)
            print("  pet \(index)            : \(pet.profile.name ?? "unnamed"), "
                  + "\(pet.profile.palette.displayName) coat, \(sliced) walk frames")
            return pet
        }
    }

    /// [M11] Change the *number* of cats on the Dock.
    ///
    /// The old pets are torn down first. An orphaned ordered-in `NSWindow` is not freed by
    /// `deinit` — AppKit retains a window that is on screen — so a dropped cat would
    /// otherwise stay on the Dock forever with a live global mouse monitor behind it: a
    /// leak that looks exactly like a rendering bug and is miserable to diagnose.
    ///
    /// Non-fatal on a sprite failure, unlike launch: this runs while cats are on screen,
    /// and a cosmetic setting must not be able to take the pets away. The old cast is
    /// already gone by then, so it says so rather than failing silently.
    func rebuildPets(from cast: [PetProfile]) {
        for pet in pets { pet.teardown() }
        pets = []

        do {
            let (sets, notes) = try loadSpriteSets(for: cast)
            spriteSets = sets
            for note in notes { print("[settings]   \(note)") }
        } catch {
            print("[settings] !! could not load the sheets for \(cast.count) cat(s) — \(error)")
            return
        }
        guard let reference = spriteSet else {
            print("[settings] !! no sheets loaded, so there is nothing to build the cast from")
            return
        }

        print("[settings] rebuilding the cast — \(cast.count) cat(s)")
        buildPets(from: cast, size: petSizeFor(set: reference))
        // Place and show them now rather than waiting out the poll, so the checkbox feels
        // like it did something.
        poll()
    }

    // MARK: - [M8] Dock confinement

    /// One line for the launch log saying where the pet may walk, and what to do if the
    /// answer is "nowhere". Silence here was the whole problem: [M9] made the ungranted
    /// case an invisible app, which looks like a crash rather than a missing permission.
    private func dockConfinementSummary() -> String {
        if !DockTiles.isTrusted {
            return "the Dock's icons — but Accessibility is not granted, so the cat stays"
                + " hidden (menu bar → Grant Accessibility…)"
        }
        return "the Dock's icons (Accessibility granted)"
    }

    /// `--dock-bounds`: measure the Dock's tiles, print what came back, and exit.
    ///
    /// SPEC §9's rule applied to geometry rather than pixels — the measurement has to be
    /// checkable from the command line, on a Dock I cannot look at.
    private func runDockBoundsProbe() -> Never {
        print("\nDockBounds")
        print("  AXIsProcessTrusted : \(DockTiles.isTrusted)")
        if !DockTiles.isTrusted {
            // Ask through the system prompt rather than telling the user to find the
            // bundle by hand. Adding it manually registers the path; the prompt registers
            // *this* binary's signature, which is the identity the check actually tests.
            print("  requesting the grant — approve the dialog, then re-run this probe.")
            DockTiles.requestTrust()
            exit(1)
        }

        var failures = 0
        for screen in NSScreen.screens {
            let geo = DockLocator.geometry(of: screen)
            print("  screen \"\(screen.localizedName)\"")
            print("    frame        : \(Self.describe(geo.frame))")
            print("    visibleFrame : \(Self.describe(geo.visibleFrame))")
            guard Geometry.dockEdge(of: geo) != nil else {
                print("    tiles        : n/a (no Dock inset on this screen)")
                continue
            }
            let start = CACurrentMediaTime()
            let tiles = DockTiles.measure(on: screen)
            let ms = (CACurrentMediaTime() - start) * 1000

            guard let tiles = tiles else {
                print("    tiles        : !! FAILED to measure (\(Self.f(CGFloat(ms))) ms)")
                failures += 1
                continue
            }
            print("    tiles        : \(Self.describe(tiles))  (\(Self.f(CGFloat(ms))) ms)")
            let items = DockTiles.inspect(on: screen)
            print("    dock items   : \(items.filter(\.inBand).count) in band, "
                  + "\(items.filter { !$0.inBand }.count) filtered out")
            for item in items {
                print("      \(item.inBand ? " " : "x") \(Self.f(item.frame.minX))"
                      + "..\(Self.f(item.frame.maxX))  \(item.title)")
            }

            let full = Geometry.walkStrip(on: geo, policy: .horizontalOnly, tiles: nil)
            let confined = Geometry.walkStrip(on: geo, policy: .horizontalOnly, tiles: tiles)
            if let full = full, let confined = confined {
                print("    strip before : [\(Self.f(full.start))...\(Self.f(full.end))]"
                      + " = \(Self.f(full.length)) pt")
                print("    strip after  : [\(Self.f(confined.start))...\(Self.f(confined.end))]"
                      + " = \(Self.f(confined.length)) pt")
                // The whole point of the change: the strip must actually get narrower.
                if confined.length >= full.length {
                    print("    !! FAIL: confinement did not narrow the strip")
                    failures += 1
                }
                // And it must stay inside the screen.
                if confined.start < full.start - 0.001 || confined.end > full.end + 0.001 {
                    print("    !! FAIL: confined strip escapes visibleFrame")
                    failures += 1
                }
            }
        }
        print(failures == 0 ? "\n  dock bounds OK" : "\n  \(failures) failure(s)")
        exit(failures == 0 ? 0 : 1)
    }

    private static func describe(_ rect: CGRect) -> String {
        "x=\(f(rect.minX)) y=\(f(rect.minY)) w=\(f(rect.width)) h=\(f(rect.height))"
    }

    /// Drives the Settings window's controls the way a click would, and checks that each
    /// change reaches the running pet and the config file.
    ///
    /// This writes to the real config.json, so it captures the current settings first and
    /// restores them at the end — running the test must not cost you your preferences.
    private func runSettingsTest() -> Never {
        var failures = 0
        var checks = 0
        func check(_ passed: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
            checks += 1
            if passed { print("  ok    \(what)") }
            else { failures += 1; print("  FAIL  \(what)\(detail().isEmpty ? "" : " — \(detail())")") }
        }
        func settle(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        print("SettingsTest")
        let original = config

        showSettings()
        guard let window = settingsWindow else {
            print("  FAIL  settings window was not created"); exit(1)
        }
        check(window.isVisible, "the settings window opens")
        check(window.title == "DockPet Settings", "with a title")

        if let path = options.shotPath, let view = window.contentView {
            settle(0.4)   // let the controls lay out before capturing
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("  wrote \(path)")
                }
            }
        }

        // --- speed ---
        window.simulate(speed: 60)
        check(config.speed == 60, "the speed slider updates the config", "got \(config.speed)")
        check(pets.allSatisfy { $0.walker.speed == 60 },
              "and reaches every pet's walker immediately",
              "got \(pets.map { $0.walker.speed })")

        // --- scale rebuilds the sprite at a new size ---
        let frameWidth = spriteFrameSize.width
        window.simulate(scale: 3)
        check(config.scale == 3, "the size popup updates the config")
        check(pets.allSatisfy { $0.size.width == frameWidth * 3 },
              "and every pet is rebuilt at the new scale",
              "expected \(frameWidth * 3) pt wide, got \(pets.map { $0.size.width })")
        check(window.contentView != nil, "the window survives a rebuild")

        // --- coat colour ---
        // Checked all the way through to the pixels: the popup has to reach the config,
        // reload the sheets and land a differently-coloured cat in the window. Asserting
        // only on config.color would pass even if the sprite were never rebuilt.
        let greyCoat = CatPalette.grey.coat
        func coatPixels(_ rgb: CatPalette.RGB) -> Int {
            guard let image = spriteSet?.walk.image,
                  let bytes = SpriteRecolor.rgbaBytes(of: image) else { return -1 }
            var found = 0, i = 0
            while i + 3 < bytes.count {
                if bytes[i + 3] == 255 && bytes[i] == rgb.red
                    && bytes[i + 1] == rgb.green && bytes[i + 2] == rgb.blue { found += 1 }
                i += 4
            }
            return found
        }

        check(coatPixels(CatPalette.orange.coat) > 0,
              "the pet starts out in the orange coat the art is drawn in")

        window.simulate(color: "grey")
        check(config.color == "grey", "the coat popup updates the config", "got \(config.color)")
        check(coatPixels(greyCoat) > 0,
              "and the live sheet is actually repainted grey",
              "found \(coatPixels(greyCoat)) grey coat pixels")
        check(coatPixels(CatPalette.orange.coat) == 0,
              "with no orange left on it",
              "\(coatPixels(CatPalette.orange.coat)) orange pixels survived")

        window.simulate(color: "orange")
        check(coatPixels(CatPalette.orange.coat) > 0, "and switching back restores the orange coat")

        check(window.offeredCoatIDs == CatPalette.all.map(\.id),
              "the popup offers every coat, in the catalogue's order",
              "got \(window.offeredCoatIDs)")

        // --- display pinning ---
        if let name = NSScreen.screens.first?.localizedName {
            window.simulate(screen: name)
            check(config.screen == name, "the display popup pins the pet", "got \(config.screen ?? "nil")")
            window.simulate(screen: .some(nil))
            check(config.screen == nil, "and can go back to automatic")
        }

        // --- menu bar toggle ---
        window.simulate(menuBarIcon: false)
        settle(0.3)   // removal is deferred, since this can run from the menu's own action
        check(!config.menuBarIcon, "the checkbox updates the config")
        check(menuBarItem == nil, "and the status item is actually removed")
        window.simulate(menuBarIcon: true)
        settle(0.3)
        check(menuBarItem != nil, "and comes back when re-enabled")

        // --- [M11] the second cat ---
        //
        // Checked through to the pixels and to the live array, for the same reason the
        // coat is: a checkbox that reached the config and nothing else would pass every
        // assertion that only reads `config`.
        func coatPixels(_ rgb: CatPalette.RGB, ofPet index: Int) -> Int {
            guard index < pets.count, let set = sprites(for: pets[index]),
                  let bytes = SpriteRecolor.rgbaBytes(of: set.walk.image) else { return -1 }
            var found = 0, i = 0
            while i + 3 < bytes.count {
                if bytes[i + 3] == 255 && bytes[i] == rgb.red
                    && bytes[i + 1] == rgb.green && bytes[i + 2] == rgb.blue { found += 1 }
                i += 4
            }
            return found
        }

        let soloCoat = config.color
        window.simulate(secondCat: true)
        settle(0.2)
        check(config.pets.count == 2, "the checkbox adds a second cat to the config",
              "config has \(config.pets.count)")
        check(pets.count == 2, "and a second cat is actually built",
              "the array holds \(pets.count)")
        check(window.secondCoatPopupIsEnabled, "its coat popup becomes usable")
        check(window.secondCoatIDs == CatPalette.all.map(\.id),
              "and offers every coat, in the catalogue's order", "got \(window.secondCoatIDs)")
        check(config.pets.count == 2 && config.pets[1].color != soloCoat,
              "the new cat wears a coat the first one is not wearing, so it is visibly a "
              + "second cat",
              "both are \(soloCoat)")
        check(pets.count == 2 && pets[1].index == 1,
              "the rebuilt array is indexed by position, so the log can tell them apart")
        check(pets.count == 2 && pets[0].interaction !== pets[1].interaction,
              "each cat has its own interaction — this is what makes a click resolvable")

        window.simulate(secondColor: "grey")
        settle(0.2)
        check(config.pets.count == 2 && config.pets[1].color == "grey",
              "the second coat popup reaches the second cat's profile",
              "got \(config.pets.map(\.color))")
        check(coatPixels(CatPalette.grey.coat, ofPet: 1) > 0,
              "and its own sheet is actually repainted grey",
              "found \(coatPixels(CatPalette.grey.coat, ofPet: 1)) grey coat pixels")
        check(coatPixels(CatPalette.grey.coat, ofPet: 0) == 0,
              "while the first cat keeps its own coat — one sheet per coat, not one for "
              + "the app",
              "pet 0 has \(coatPixels(CatPalette.grey.coat, ofPet: 0)) grey coat pixels")

        let droppedWindow = pets.count == 2 ? pets[1].window : nil
        window.simulate(secondCat: false)
        settle(0.2)
        check(config.pets.count == 1, "unchecking it drops the second cat from the config")
        check(pets.count == 1, "and from the array", "the array holds \(pets.count)")
        check(!window.secondCoatPopupIsEnabled, "its coat popup goes back to unusable")
        // AppKit retains an on-screen window, so a dropped cat that is not dismissed
        // explicitly stays on the Dock forever with a live mouse monitor behind it.
        check(droppedWindow?.isVisible == false,
              "the dropped cat's window is taken off screen rather than orphaned")

        // --- confinement is no longer a setting [M9] ---
        check(confinementStatus.isEmpty == false, "the window reports the confinement status")
        window.simulate(speed: 45)

        // --- persistence, after the debounce ---
        settle(0.7)
        if let data = try? Data(contentsOf: ConfigStore.url),
           let saved = try? JSONDecoder().decode(PetConfig.self, from: data) {
            check(saved.speed == 45 && saved.scale == 3,
                  "changes are written to config.json",
                  "file says speed=\(saved.speed) scale=\(saved.scale)")
        } else {
            check(false, "config.json could be read back")
        }

        // --- reset ---
        window.simulateReset()
        // [M11] Compared against the *validated* defaults rather than `.default` itself.
        // `validated()` fills the `pets` array in from the legacy keys, so no config that
        // has been through it is ever equal to the bare defaults — and every config in the
        // running app has been through it. The assertion, not the reset, was out of date.
        let defaults = PetConfig.default.validated().config
        check(config == defaults, "Reset to Defaults restores the defaults",
              "got speed=\(config.speed) scale=\(config.scale) pets=\(config.pets.count)")

        // --- restore the user's real settings ---
        settingsDidChange(original)
        settle(0.7)
        check(config == original, "the test restored your original settings")
        window.close()

        print("")
        if failures > 0 { print("\(failures) of \(checks) checks FAILED"); exit(1) }
        print("all \(checks) checks passed")
        exit(0)
    }

    func applicationWillTerminate(_ notification: Notification) {
        locatorTimer?.invalidate()
        animationTimer?.invalidate()
        verboseTimer?.invalidate()
        // [M10] A global event monitor outlives the object that installed it; leaving one
        // registered during teardown is a callback into a half-dead app. Every pet has one.
        // [M11] `Pet.teardown()` is the single place a pet is let go, so quitting and
        // dropping a cat from Settings cannot clean up differently.
        for pet in pets { pet.teardown() }
    }

    // MARK: - Timers
    //
    // SPEC §8 trap 3: every timer goes in `.common` mode, so none of them stall during
    // menu tracking or live resize.

    private func startLocatorTimer() {
        let timer = Timer(timeInterval: Self.locatorInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        locatorTimer = timer
    }

    private func startVerboseTimer() {
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.logSnapshot()
        }
        RunLoop.main.add(timer, forMode: .common)
        verboseTimer = timer
    }

    private func startAnimationIfNeeded() {
        guard animationTimer == nil else { return }
        lastAnimationTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / Self.animationFPS, repeats: true) { [weak self] _ in
            self?.animationTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// SPEC §6: fully suspend, do not merely skip drawing.
    private func suspendAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    // MARK: - Locator poll (500 ms)

    private func poll() {
        guard !pets.isEmpty else { return }

        // Real elapsed time, not the nominal interval: the timer can be late.
        let now = CACurrentMediaTime()
        let dt = lastPollTime == 0 ? 0 : now - lastPollTime
        lastPollTime = now

        // [M11] Bounded lifetime: once the window has said its piece and taken itself off
        // screen, drop the reference rather than holding it — and re-dereferencing it —
        // for the rest of the app's run.
        if let onboarding = onboarding, onboarding.isFinished, !onboarding.isVisible {
            self.onboarding = nil
        }

        if paused {
            currentLocation = nil
            for pet in pets where pet.window.isVisible { pet.window.orderOut(nil) }
            suspendAnimation()
            logAnimation("suspended — \(AnimationSuspension.paused.rawValue)")
            return
        }

        switch locator.locate() {
        case .located(let location):
            // [M11] The poll is the only thing that knows the grant actually worked —
            // `DockTiles.isTrusted` can go true a moment before the tiles are readable.
            onboarding?.markGranted()
            currentLocation = location

            for pet in pets {
                // The behaviour clock only runs while the pet is actually on screen — a
                // pet that spent the last hour dormant should not wake up mid-nap.
                // Advanced here rather than on the animation timer because this timer is
                // the one that always runs; the animation timer is suspended for three of
                // the four states.
                let (previous, state) = pet.advanceBehavior(by: dt)
                if state != previous {
                    logLocation("pet \(pet.index): \(state.rawValue) on"
                                + " \(location.screen.localizedName)")
                    pet.applyBehaviorState(state, spriteSet: sprites(for: pet))
                }
                // [M10] Also here, not only on the animation tick: that timer is suspended
                // for three of the four states (SPEC §6), so a sitting or sleeping cat
                // would depend entirely on the mouse monitor to become clickable. This poll
                // always runs, which caps how long the cat can be wrongly click-through at
                // 500 ms.
                pet.interaction.updateClickThrough()

                // The strip may have changed shape since the last poll; make sure the pet
                // is still standing on it before the next animation frame moves it.
                pet.walker.clamp(to: Geometry.maximumDistance(for: pet.size, on: location.strip))
                pet.position(on: location.strip)
                if !pet.window.isVisible {
                    pet.window.orderFront(nil)   // SPEC §3: never makeKeyAndOrderFront
                }
            }

            // [M11] Once per poll, with the poll's real elapsed time. The coordinator
            // clamps a long step itself, for the same reason `Walker` does — a stalled
            // process must not burn the whole cooldown in one tick — so nothing here tries
            // to compensate for that clamp.
            meetings.advance(by: dt)
            considerMeeting()

        case .absent(let reason):
            currentLocation = nil
            for pet in pets where pet.window.isVisible { pet.window.orderOut(nil) }
            logLocation("dormant — \(reason.rawValue)")
        }

        updateAnimationState()
    }

    /// SPEC §6's suspension conditions, in priority order.
    ///
    /// [M6] Suspend when there is nothing to animate: the pet is stationary AND its state
    /// has no multi-frame sheet of its own. With a sit or sleep animation supplied, the
    /// timer keeps running so that animation plays — the pet simply does not move. Same
    /// reasoning as SPEC §6's listed conditions: never run a 12 fps timer to redraw an
    /// unchanged frame.
    ///
    /// [M11] That test is now "every pet", not "the pet". One walking cat keeps the timer
    /// alive for both, which is correct — and it is why the measured one-third idle figure
    /// from M6 does not survive a second cat (§6 [M11] amendment). `allSatisfy` on an empty
    /// array is `true`, which suspends: no pets is nothing to animate.
    func suspensionReason() -> AnimationSuspension? {
        if paused { return .paused }
        if currentLocation == nil { return .dockNotLocated }
        if pets.allSatisfy({ $0.isStationary(spriteSet: sprites(for: $0)) }) { return .stationary }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPowerMode }
        return nil
    }

    private func updateAnimationState() {
        if let reason = suspensionReason() {
            suspendAnimation()
            logAnimation("suspended — \(reason.rawValue)")
        } else {
            startAnimationIfNeeded()
            logAnimation("running at \(Int(Self.animationFPS)) fps")
        }
    }

    // MARK: - Animation (12 fps)

    private func animationTick() {
        guard !pets.isEmpty, let location = currentLocation else { return }

        // SPEC §7 M3: recomputed against the live strip every tick, never a cached one.
        // Only the screen reference is carried over from the poll; its geometry is re-read
        // here. The window list is deliberately *not* consulted at 12 fps — presence is the
        // 500 ms poll's job, and it is the expensive half.
        // [M8] `location.tiles` comes from the 500 ms poll. The Accessibility read is far
        // too expensive to repeat twelve times a second, and the tiles move slowly enough
        // that a half-second-old measurement is indistinguishable from a fresh one.
        guard let strip = Geometry.walkStrip(on: DockLocator.geometry(of: location.screen),
                                             policy: .horizontalOnly,
                                             tiles: location.tiles) else {
            return   // screen lost its Dock; the next poll will make this dormant properly
        }

        let now = CACurrentMediaTime()
        let dt = now - lastAnimationTime
        lastAnimationTime = now

        // [M11] One timer, every pet. SPEC §6: a second cat must not double the app's
        // wakeups — only the work done inside a wakeup.
        for pet in pets {
            pet.advanceAnimation(by: dt, on: strip, spriteSet: sprites(for: pet))
        }
    }

    // MARK: - [M11] The meeting

    /// Two cats have walked into each other: stop, face each other, trade a line, part.
    ///
    /// **They turn around rather than passing through**, and that is a correctness
    /// requirement rather than a flourish. Two pets that pass through each other overlap
    /// for several consecutive ticks and would re-trigger this on every one; turning them
    /// around separates them monotonically, so the cooldown is the only suppression
    /// needed. No new art either — facing is the horizontal flip §5 already does, and
    /// `sit` already has a sheet.
    private func considerMeeting() {
        guard pets.count == 2 else { return }
        let a = pets[0], b = pets[1]

        // Neither cat interrupts itself mid-sentence, and a cat being clicked is having a
        // conversation with a human, which takes precedence over one with a cat.
        guard !a.interaction.isTalking, !b.interaction.isTalking else { return }

        guard let exchange = meetings.meet(a.window.frame, b.window.frame,
                                           openerName: a.profile.name,
                                           replierName: b.profile.name) else { return }

        for pet in [a, b] {
            pet.behavior.force(.sit)
            pet.applyBehaviorState(.sit, spriteSet: sprites(for: pet))
        }
        // Face each other: the left-hand cat looks right, the right-hand cat looks left.
        let aIsLeft = a.window.frame.minX <= b.window.frame.minX
        a.view.facing = aIsLeft ? .right : .left
        b.view.facing = aIsLeft ? .left : .right

        // SPEC §9: an exchange nobody can see has to be readable in the log.
        print("[meet] pet \(a.index) → \"\(exchange.opener)\"")
        a.interaction.showBubble(exchange.opener)

        DispatchQueue.main.asyncAfter(deadline: .now() + MeetingCoordinator.replyDelay) {
            [weak self, weak b] in
            // Weak on both, and the pet is confirmed still in the array before it speaks:
            // Settings can rebuild the cast during the second and a half between the line
            // and its answer, and a torn-down cat must not put a bubble back on screen.
            guard let self, let b, self.pets.contains(where: { $0 === b }) else { return }
            print("[meet] pet \(b.index) → \"\(exchange.reply)\"")
            b.interaction.showBubble(exchange.reply)
        }

        // Both turn around and walk back the way they came, so the next tick separates
        // them instead of finding them still overlapping.
        for pet in [a, b] { pet.walker.reverse() }
        updateAnimationState()
    }

    // MARK: - Logging

    /// State changes are always logged; they are rare and they explain everything else.
    private func logLocation(_ description: String) {
        guard description != lastLocationDescription else { return }
        lastLocationDescription = description
        print("[state] \(description)")
    }

    private func logAnimation(_ description: String) {
        guard description != lastAnimationDescription else { return }
        lastAnimationDescription = description
        print("[timer] \(description)")
    }

    /// SPEC §6: once per second under `--verbose`.
    private func logSnapshot() {
        var line = "[verbose] "
        let suspension = suspensionReason()

        // The stage: everything the pets share. Per-pet facts go on the lines below —
        // [M11], SPEC §9: two cats that cannot be told apart in the log cannot be debugged.
        if let location = currentLocation {
            let vf = location.screen.visibleFrame
            let strip = location.strip

            line += "state=\(suspension == nil ? "walking" : "suspended")"
            line += " pets=\(pets.count)"
            line += " screen=\"\(location.screen.localizedName)\""
            line += " scale=\(Self.f(location.screen.backingScaleFactor))"
            line += " visibleFrame=\(Self.f(vf))"
            line += " dockEdge=\(strip.edge.rawValue)"
            line += " baseline=\(Self.f(strip.baseline))"
            line += " strip=[\(Self.f(strip.start))...\(Self.f(strip.end))]"
            line += " tiles=" + (location.tiles.map { "[\(Self.f($0.minX))...\(Self.f($0.maxX))]" }
                                 ?? "unmeasured")
        } else {
            line += "state=dormant"
            line += " pets=\(pets.count)"
            line += " dockOnScreen=\(DockLocator.isDockOnScreen())"
            // Shown anyway: under autohide this is unchanged, which is exactly the trap
            // that makes the presence check necessary (PROBE.md F4).
            if let main = NSScreen.screens.first {
                line += " screens[0].visibleFrame=\(Self.f(main.visibleFrame))"
            }
        }

        // No Dock rect is logged: SPEC §4b [M0] uses the window list for presence only and
        // never reads its bounds, so there is no second coordinate space in play.
        line += " locatorTimer=\(locatorTimer?.isValid == true ? "active" : "invalid")"
        line += " animationTimer=\(animationTimer == nil ? "suspended" : "active(\(Int(Self.animationFPS))fps)")"
        line += " suspendReason=\(suspension?.rawValue ?? "none")"
        line += " lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        print(line)

        for pet in pets { print(petSnapshot(pet, on: currentLocation?.strip)) }
    }

    /// [M11] One line per pet, indented under the stage line. Everything here is a fact
    /// about *this* cat, and every claim is stated so it can be checked from the log alone
    /// (SPEC §9 — you cannot see my screen, and I cannot see yours).
    private func petSnapshot(_ pet: Pet, on strip: WalkStrip?) -> String {
        let frame = pet.window.frame
        var line = "  pet \(pet.index)"
        if let name = pet.profile.name { line += " (\(name))" }
        line += " coat=\(pet.profile.color)"
        line += " behavior=\(pet.behavior.state.rawValue)"
        line += " sheet=\((sprites(for: pet)?.hasOwnSheet(for: pet.behavior.state) ?? false) ? "own" : "walk-fallback")"
        line += " dwell=\(Self.f(CGFloat(pet.behavior.timeInState)))/\(Self.f(CGFloat(pet.behavior.currentDwell)))s"
        line += " transitions=\(pet.behavior.transitionCount)"
        line += " frame=\(pet.sequencer.index)/\(pet.sequencer.frameCount)"
        line += " facing=\(pet.view.facing == .left ? "left" : "right")"
        line += " window=\(Self.f(frame))"
        line += " visible=\(pet.window.isVisible)"
        // [M10] Clicking is invisible in a log otherwise: whether the window is currently
        // accepting mouse events is the whole difference between a clickable cat and a
        // Dock that has stopped responding, and it changes as the cursor moves.
        line += " takesClicks=\(pet.window.ignoresMouseEvents == false)"
        line += " talking=\(pet.interaction.isTalking)"
        if let reply = pet.interaction.lastReply, pet.interaction.isTalking {
            line += " saying=\"\(reply)\""
            line += " bubble=\(pet.interaction.bubbleFrame.map { Self.f($0) } ?? "none")"
        }

        guard let strip = strip else { return line }
        let maximum = Geometry.maximumDistance(for: pet.size, on: strip)

        let restsOnEdge: Bool
        switch strip.edge {
        case .bottom: restsOnEdge = abs(frame.minY - strip.baseline) < 0.001
        case .left:   restsOnEdge = abs(frame.minX - strip.baseline) < 0.001
        case .right:  restsOnEdge = abs(frame.maxX - strip.baseline) < 0.001
        }
        let onStrip = pet.walker.distance >= 0 && pet.walker.distance <= maximum + 0.001

        line += " distance=\(Self.f(pet.walker.distance))/\(Self.f(maximum))"
        line += " dir=\(pet.walker.direction == .forward ? "forward" : "backward")"
        line += " restsOnDockEdge=\(restsOnEdge)"
        line += " onStrip=\(onStrip)"
        if !restsOnEdge { line += "  !! WINDOW IS NOT ON THE DOCK EDGE" }
        if !onStrip { line += "  !! PET HAS LEFT THE STRIP" }
        return line
    }

    // MARK: - Menu bar

    /// Human-readable summary for the status menu.
    var isPaused: Bool { paused }

    /// [M8] Confined only if the user asked for it *and* the last poll actually measured
    /// the tiles. Reporting the config flag alone would claim confinement the pet does not
    /// have whenever the grant is missing.
    var needsAccessibilityGrant: Bool { !DockTiles.isTrusted }

    var isConfinedToDock: Bool {
        currentLocation?.tiles != nil
    }

    /// [M8] The system prompt, from a click and nowhere else.
    ///
    /// The grant lands asynchronously and, on macOS, only takes effect for a running
    /// process once the user flips the switch — so there is nothing to do here but ask.
    /// The 500 ms poll notices on its own and the pet moves onto the Dock without a
    /// restart.
    func requestDockConfinement() {
        print("[state] requesting Accessibility so the pet can be confined to the Dock")
        DockTiles.requestTrust()
    }

    var statusSummary: String {
        if paused { return "Paused" }
        guard let location = currentLocation, let pet = primaryPet else {
            if !DockTiles.isTrusted { return "Waiting for Accessibility" }
            return "Waiting — \(lastLocationDescription ?? "looking for the Dock")"
        }
        let verb: String
        switch pet.behavior.state {
        case .walk:  verb = "Walking"
        case .idle:  verb = "Standing"
        case .sit:   verb = "Sitting"
        case .sleep: verb = "Sleeping"
        }
        return "\(verb) on \(location.screen.localizedName)"
    }

    /// One line naming which sheets are loaded, so a reload's effect is visible in the menu.
    var spriteSummary: String {
        guard let set = spriteSet else { return "No sheets loaded" }
        let parts = PetState.allCases.map { state -> String in
            if let own = set.sheets[state] {
                return "\(state.rawValue) \(own.metadata.frameCount)f"
            }
            return "\(state.rawValue) —"
        }
        return "Sheets: " + parts.joined(separator: ", ")
    }

    /// Re-read config.json and the sprite sheets without restarting.
    ///
    /// Unlike launch, nothing here is fatal: this runs while the pet is on screen, and a
    /// typo in a sidecar should cost a log line, not the running app. A failed sprite
    /// reload keeps whatever was already loaded.
    func reload() {
        print("[reload] re-reading config and sprites")

        let outcome = ConfigStore.load()
        for note in outcome.notes { print("[reload]   \(note)") }
        applyConfig(outcome.config, persist: false, rebuildSprites: false)

        do {
            // [M11] The cast's coats, not the config's one coat: `applyConfig` above has
            // already brought every pet's profile up to date, so this is what they wear.
            let (sets, notes) = try loadSpriteSets(for: pets.map(\.profile))
            for note in notes { print("[reload]   \(note)") }
            applySprites(sets)
        } catch {
            print("[reload]   !! sprite reload failed, keeping the current sheets — \(error)")
        }

        // Reposition against the live strip straight away rather than waiting out the poll.
        poll()
        print("[reload] done — speed=\(Self.f(CGFloat(config.speed))) scale=\(config.scale)x "
              + "coats=\(loadedCoatSummary), \(spriteSummary)")
    }

    /// Make a config live. The single place any setting takes effect, whether it came from
    /// the file, a reload, or the Settings window.
    ///
    /// `rebuildSprites` is skipped by `reload()`, which reloads the sheets itself straight
    /// afterwards and would otherwise rebuild the view twice.
    func applyConfig(_ newConfig: PetConfig, persist: Bool, rebuildSprites: Bool = true) {
        let previous = config
        // [M11] Guarded the same way as the launch-time call: a self-test must not rewrite
        // the user's real login item as a side effect of checking something else.
        if !options.isSelfTest, newConfig.launchAtLogin != config.launchAtLogin {
            LoginItem.setEnabled(newConfig.launchAtLogin)
        }
        config = newConfig

        // Speed describes the stage rather than an actor, so every pet gets it.
        for pet in pets { pet.walker.speed = CGFloat(config.speed) }
        locator.pinnedScreenName = config.screen

        let cast = Self.cast(of: newConfig)
        if cast.count != pets.count {
            // [M11] A changed *number* of cats is a rebuild, not an update: windows have
            // to be created or dismissed and every interaction re-attached to a live view.
            rebuildPets(from: cast)
        } else {
            // [M11] A pet's identity comes from the config, so a coat or a name changed
            // here has to reach the pet as well as the file. Three places report
            // `profile.color` — the launch log, `--verbose` and `--render-test` — and a
            // stale profile would have all three describing a cat that is not on screen.
            for (index, profile) in cast.enumerated() { pets[index].profile = profile }

            // Reload when the cast is no longer wearing the coats that are loaded. Stated
            // as "what is wanted vs what is loaded" rather than as "did `config.color`
            // change", because with two cats the second one's coat can change while the
            // config's own coat does not.
            if rebuildSprites, Set(pets.map(\.profile.palette.id)) != Set(spriteSets.keys) {
                // The recolour happens as the sheets are decoded, so a new coat means
                // reading them again — re-scaling the sets already in memory would only
                // resize the colours they already have.
                reloadSprites()
            } else if rebuildSprites, config.scale != previous.scale {
                applySprites(spriteSets)   // recomputes petSize at the new scale
            }
        }
        if config.menuBarIcon != previous.menuBarIcon {
            // Deferred: this can be called from the menu item's own action.
            DispatchQueue.main.async { [weak self] in self?.applyMenuBarVisibility() }
        }
        if persist { scheduleSave() }
    }

    /// Writing on every slider tick would be dozens of writes per drag; 0.4 s coalesces a
    /// drag into one.
    private func scheduleSave() {
        saveDebounce?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            switch ConfigStore.write(self.config) {
            case .success: print("[settings] saved \(ConfigStore.url.lastPathComponent)")
            case .failure(let error): print("[settings] !! could not save — \(error.localizedDescription)")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveDebounce = timer
    }

    // MARK: - [M10] PetInteractionDelegate

    /// What the pet calls you.
    ///
    /// `config.userName` wins when it is set. Otherwise the macOS account's first name,
    /// so a fresh install greets you properly without anyone having opened Settings — the
    /// feature is worth nothing if it says "Hello!" until you configure it.
    ///
    /// `nil` is a real answer, not a failure: a user who cleared the field gets lines
    /// rendered without a name, which Phrasebook handles on purpose.
    var effectiveUserName: String? {
        if let configured = config.userName, !configured.isEmpty { return configured }
        let account = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = account.split(separator: " ").first, !first.isEmpty else { return nil }
        // Guard against the account "name" being an email or a path fragment, which would
        // read as nonsense in a speech bubble.
        let word = String(first)
        guard !word.contains("@"), !word.contains("/"),
              word.count <= PetConfig.maximumNameLength else { return nil }
        return word
    }

    /// Which cat is asking.
    ///
    /// [M11] The whole reason the delegate callbacks carry an interaction. Resolving to
    /// `primaryPet` instead would put the *first* cat to sleep when you clicked the second
    /// and greet you with the *first* cat's name — both of which look like a working app
    /// until you notice it is answering for the wrong animal.
    private func pet(for interaction: PetInteraction) -> Pet? {
        pets.first { $0.interaction === interaction }
    }

    func interactionUserName(for interaction: PetInteraction) -> String? {
        // A cat with no `userName` of its own falls back to the app-wide answer rather
        // than to nothing: M10's rule is that a fresh install greets you properly without
        // anyone having opened Settings, and that has to survive a second cat.
        guard let pet = pet(for: interaction) else { return effectiveUserName }
        return pet.profile.userName ?? effectiveUserName
    }

    var interactionScale: Int { config.scale }
    var interactionScreen: NSScreen? { currentLocation?.screen }
    var interactionBirthday: String? { config.birthday }
    var interactionDedication: String? { config.dedication }

    /// A click changed what the pet is doing. Unlike the poll's own transitions this can
    /// happen at any moment, so the sheet swap and the timer decision are both redone here.
    ///
    /// [M11] Applied to the cat that was clicked, resolved by interaction identity — so
    /// *Take a nap* on the second cat naps the second cat.
    func interactionForcePetState(_ state: PetState, for interaction: PetInteraction) {
        guard let pet = pet(for: interaction) else { return }
        let previous = pet.behavior.state
        pet.behavior.force(state)
        if pet.behavior.state != previous {
            pet.applyBehaviorState(pet.behavior.state, spriteSet: sprites(for: pet))
            logLocation("pet \(pet.index): \(pet.behavior.state.rawValue) (asked for it)")
        }
        updateAnimationState()
    }

    func interactionShowSettings() { showSettings() }

    // MARK: - SettingsWindowDelegate

    var currentConfig: PetConfig { config }

    var spriteFrameSize: CGSize {
        guard let m = spriteSet?.walk.metadata else { return CGSize(width: 32, height: 32) }
        return CGSize(width: CGFloat(m.frameWidth), height: CGFloat(m.frameHeight))
    }

    var confinementStatus: String {
        if DockTiles.isTrusted { return "The cat stays over the Dock's icons." }
        return "Waiting for Accessibility — it is needed to find the Dock's icons. "
            + "Grant it in System Settings ▸ Privacy & Security ▸ Accessibility."
    }

    func settingsDidChange(_ newConfig: PetConfig) {
        // The UI cannot produce an out-of-range value, but validating here means the same
        // rules apply no matter where a config came from.
        let (validated, corrections) = newConfig.validated()
        for c in corrections {
            print("[settings] \(c.field)=\(c.given) is out of range, using \(c.used)")
        }
        applyConfig(validated, persist: true)
        poll()
    }

    func showSettings() {
        let window = settingsWindow ?? SettingsWindow(delegate: self)
        settingsWindow = window
        // Re-read in case config.json changed since the window was last open.
        window.loadFromConfig()
        // An accessory app has to activate explicitly, or the window opens behind whatever
        // you were using.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Re-read the sheets from disk in the current coat.
    ///
    /// Non-fatal like every other reload: a failure here keeps the cat that is already on
    /// screen, in the colour it already is, rather than taking the pet away over a
    /// cosmetic setting.
    private func reloadSprites() {
        do {
            let (sets, _) = try loadSpriteSets(for: pets.map(\.profile))
            applySprites(sets)
            print("[settings] coats are now \(loadedCoatSummary)")
        } catch {
            print("[settings] !! could not reload the sheets for \(loadedCoatSummary), "
                  + "keeping the current ones — \(error)")
        }
    }

    /// [M11] The coats the cast is wearing, for one line of log.
    private var loadedCoatSummary: String {
        let coats = Self.distinctPalettes(of: pets.map(\.profile)).map(\.displayName)
        return coats.isEmpty ? "no coats" : coats.joined(separator: " + ")
    }

    /// Swap in a new set of sheets, keeping each pet's current state and heading.
    ///
    /// [M11] Each pet is handed the set matching its own coat. Every set is the same art
    /// in a different colour, so one of them decides the window size for all of them.
    private func applySprites(_ sets: [String: SpriteSet]) {
        spriteSets = sets
        guard let reference = spriteSet else { return }
        let size = petSizeFor(set: reference)
        for pet in pets {
            guard let set = sprites(for: pet) else { continue }
            pet.applySprites(set, size: size)
        }
    }

    /// The cast a config describes: its `pets`, or the legacy flat keys read as pet 0.
    ///
    /// `validated()` guarantees `pets` is non-empty and mirrors those keys, so on every
    /// path a real config takes this is simply `config.pets`. The fallback is for the
    /// self-tests, which build a `PetConfig` by hand and never pass it through the
    /// validator: without it `applyConfig` would read a hand-built config as a cast of
    /// none and stop keeping the pets' identities in step with it.
    static func cast(of config: PetConfig) -> [PetProfile] {
        config.pets.isEmpty
            ? [PetProfile(name: nil, color: config.color, userName: config.userName)]
            : config.pets
    }

    /// The window size for a sheet at the configured scale. Every pet is the same size —
    /// `scale` is global, because it describes the stage rather than an actor.
    ///
    /// Derived from the sheet, never hardcoded (SPEC §5).
    private func petSizeFor(set: SpriteSet) -> CGSize {
        set.walk.metadata.pointSize(scale: config.scale)
    }

    private func applyMenuBarVisibility() {
        if config.menuBarIcon, menuBarItem == nil {
            let item = MenuBarItem(version: Self.versionString)
            item.delegate = self
            menuBarItem = item
            print("[reload]   menu bar item shown")
        } else if !config.menuBarIcon, let item = menuBarItem {
            item.remove()
            menuBarItem = nil
            print("[reload]   menu bar item hidden")
        }
    }

    /// `killall -HUP DockPet` reloads too, which is handy when iterating on art from a
    /// shell and is what makes the reload path testable from outside the app.
    private func installReloadSignalHandler() {
        signal(SIGHUP, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        source.setEventHandler { [weak self] in
            print("[reload] SIGHUP received")
            self?.reload()
        }
        source.resume()
        reloadSignalSource = source
        print("  reload           : menu item, or killall -HUP DockPet")
    }

    func setPaused(_ newValue: Bool) {
        guard newValue != paused else { return }
        paused = newValue
        print("[state] \(paused ? "paused" : "resumed") from the menu bar")
        // Apply immediately rather than waiting out the poll interval, so the menu click
        // feels instant.
        poll()
    }

    // MARK: - Formatting

    static func f(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    static func f(_ r: CGRect) -> String {
        "(\(f(r.origin.x)),\(f(r.origin.y)) \(f(r.width))x\(f(r.height)))"
    }

    static var versionString: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "(unbundled)"
    }

    private static func describe(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular:    return "regular"
        case .accessory:  return "accessory"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown(\(policy.rawValue))"
        }
    }
}

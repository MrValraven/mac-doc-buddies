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
    /// [M11] Drive the once-a-day dedication's positive path and exit. See
    /// `AppDelegate.runDedicationTest()` for how it says a real dedication without ever
    /// touching the real state.json or config.json.
    let dedicationTest: Bool

    /// True for any of the self-test modes. Used to keep a test run from throwing the
    /// system Accessibility dialog at whoever is running it, and — for every mode except
    /// `--dedication-test` — to keep `PetInteraction.say` from ever consuming a real
    /// dedication (see `PetInteraction.isSelfTest`).
    var isSelfTest: Bool {
        renderTest || settingsTest || menuTest || dockBounds || interactionTest || dedicationTest
            || kissTest
    }

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
    /// [M12] Send two cats to each other, run the kiss to its end, and exit. The sequence
    /// takes six seconds of screen and produces no file, so this is the only way anybody
    /// who cannot watch it can tell whether it works.
    let kissTest: Bool

    init(arguments: [String]) {
        self.verbose = arguments.contains("--verbose") || arguments.contains("-v")
        self.renderTest = arguments.contains("--render-test")
        self.settingsTest = arguments.contains("--settings-test")
        self.shotPath = arguments.first { $0.hasPrefix("--shot=") }?
            .replacingOccurrences(of: "--shot=", with: "")
        self.menuTest = arguments.contains("--menu-test")
        self.dockBounds = arguments.contains("--dock-bounds")
        self.interactionTest = arguments.contains("--interaction-test")
        self.dedicationTest = arguments.contains("--dedication-test")
        self.kissTest = arguments.contains("--kiss-test")
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

    /// [M12] The kiss in progress, or `nil` — which is nearly always. One at a time: the
    /// cast is two cats, and both of them are in it.
    private var kiss: KissInProgress?

    /// The routine, the pair it belongs to, and the hearts while they are up.
    ///
    /// `left` and `right` are settled once, when the kiss starts, from where the cats are
    /// standing — not from their position in `pets`. They swap places during the approach
    /// often enough that reading it per frame would have the line come out of whichever cat
    /// happened to be leading.
    private struct KissInProgress {
        var routine = KissRoutine()
        let left: Pet
        let right: Pet
        var hearts: HeartsWindow?
    }

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
                // SPEC 11a: a registration failure is logged and clamped to "off", never
                // fatal. Clamped as well as logged so the ticked box in Settings stops
                // claiming something that did not happen — a silently-ignored tick is
                // indistinguishable from a working one until the next reboot.
                print("[config] could not set launch at login (\(error.localizedDescription))")
                print("[config] clamping launchAtLogin to false — \(LoginItem.statusDescription)")
                config.launchAtLogin = false
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

        // [M11] Every cat this config asks for.
        //
        // Through `cast(of:)` rather than `config.pets` directly. `validated()` does fill
        // the array in, but not every config here has been through it: a hand-built
        // `PetConfig` has an empty `pets`, and so did `ConfigStore`'s two fallback paths
        // until they were fixed. An empty cast loads no sprite sheets and the guard below
        // exits — which is a silent first-launch death on a Mac with no config.json, not a
        // loud validator bug. One shared normalisation, in the one place that already
        // existed for it.
        let profiles = Self.cast(of: config)

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
            // [M11] Asked for by the onboarding window's button below, and nowhere else on
            // this path. Prompting here as well put the system TCC alert and DockPet's own
            // window on screen on the same run-loop turn, fighting over a first-run user's
            // attention — and spent the one-shot alert before the button that exists to
            // present it deliberately ever got the click.
            print("  accessibility    : not granted — the welcome window will ask")
            print("                     the cat stays hidden until it is granted")
        }

        installReloadSignalHandler()

        startLocatorTimer()
        if options.verbose { startVerboseTimer() }

        // Place the pet immediately rather than waiting out the first poll interval.
        poll()

        if options.settingsTest { runSettingsTest() }
        if options.menuTest { runMenuTest() }
        if options.interactionTest { runInteractionTest() }
        if options.dedicationTest { runDedicationTest() }
        if options.kissTest { runKissTest() }

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

    /// Where a cat with no history of its own starts out.
    ///
    /// [M11] Alternating ends, walking towards each other. Two same-size pets both at
    /// distance 0 have **identical** frames, and `MeetingCoordinator.haveMet` is true for
    /// identical frames (`a.intersects(b) || a == b`) — so an unspaced cast launches
    /// stacked into what reads as one cat, and the very first located poll spends the 60
    /// second cooldown on a meeting the pair is having with itself. They would only drift
    /// apart once their behaviour machines diverged, which an 8–22 second walk dwell can
    /// take a while to do.
    ///
    /// The strip has not been measured when this is called — at launch nothing has polled
    /// yet — so the far end is a distance larger than any strip rather than a fraction of
    /// one. Both `Walker.clamp` on the first poll and `Geometry.petFrame` itself clamp it
    /// onto whatever the strip turns out to be; it is finite so that arithmetic on it
    /// cannot go to infinity if it is ever advanced before that.
    static func startingPlace(forPetAt index: Int) -> (CGFloat, Walker.Direction) {
        index.isMultiple(of: 2) ? (0, .forward) : (Self.beyondAnyStrip, .backward)
    }

    private static let beyondAnyStrip: CGFloat = 1_000_000

    /// Build `pets` from a cast and wire each one up.
    ///
    /// Shared by launch and by `rebuildPets(from:)` so that a cat added from Settings is
    /// put together exactly as one built at launch. Two constructions would drift, and the
    /// second cat is always the one that ends up with the older half.
    ///
    /// `spriteSets` must already hold a set for every coat in `profiles`.
    ///
    /// `carrying` is where each cat was standing before a rebuild, by position. A cat that
    /// was halfway along the Dock must not be teleported back to the near end because a
    /// *different* cat was added or dropped.
    func buildPets(from profiles: [PetProfile], size: CGSize,
                   carrying: [Walker] = []) {
        pets = profiles.enumerated().map { index, profile in
            guard let set = spriteSets[profile.palette.id] else {
                // Unreachable via either caller — both load the cast's coats first — but a
                // pet with no art is an invisible cat with a live mouse monitor, which is
                // worse to diagnose than a loud exit.
                print("  !! FATAL: no sheets were loaded for pet \(index)'s"
                      + " \(profile.palette.id) coat")
                exit(1)
            }
            // Where this cat starts: where it was standing if it survived a rebuild,
            // otherwise its spaced-out place in a fresh cast.
            let start = index < carrying.count
                ? (carrying[index].distance, carrying[index].direction)
                : Self.startingPlace(forPetAt: index)
            let pet = Pet(index: index, profile: profile, spriteSet: set,
                          size: size, speed: CGFloat(config.speed),
                          distance: start.0, direction: start.1)
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
        // Sheets **first**, and only then tear the old cast down. Emptying `pets` before
        // knowing the art will load would take every cat away over a failed disk read —
        // precisely what the paragraph above promises cannot happen.
        let sets: [String: SpriteSet]
        do {
            let (loaded, notes) = try loadSpriteSets(for: cast)
            sets = loaded
            for note in notes { print("[settings]   \(note)") }
        } catch {
            print("[settings] !! could not load the sheets for \(cast.count) cat(s), keeping"
                  + " the cast that is on screen — \(error)")
            return
        }
        guard let reference = cast.first.flatMap({ sets[$0.palette.id] }) ?? sets.values.first
        else {
            print("[settings] !! no sheets loaded, so there is nothing to build the cast"
                  + " from — keeping the cast that is on screen")
            return
        }

        // Where everyone was standing, so a surviving cat is not teleported to the near
        // end because a different cat was added or dropped.
        let carried = pets.map(\.walker)
        // [M12] Before the cats go: the hearts belong to the pair, not to either window, so
        // nothing else on this path would take them down.
        endKiss()
        for pet in pets { pet.teardown() }
        pets = []
        spriteSets = sets

        print("[settings] rebuilding the cast — \(cast.count) cat(s)")
        buildPets(from: cast, size: petSizeFor(set: reference), carrying: carried)
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

        check(coatPixels(CatPalette.olive.coat) > 0,
              "the pet starts out in the olive coat, the default")
        check(coatPixels(CatPalette.orange.coat) == 0,
              "and not in the orange the sheet is drawn in — the default is a recolour "
              + "like any other, so a fresh install must already have been repainted")

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

        // --- [M11] launch at login ---
        //
        // `simulate(launchAtLogin:)` has existed since the checkbox did and nothing ever
        // called it, so the one control whose effect a user cannot see for themselves —
        // it only shows at the next reboot — was also the one control with no assertion
        // behind it. The registration itself is deliberately not exercised: `applyConfig`
        // skips `LoginItem` under a self-test, because a test run must not rewrite the
        // real login item on this Mac. What is checked is the wiring either side of it,
        // which is where a checkbox silently fails to mean anything.
        let loginBefore = config.launchAtLogin
        window.simulate(launchAtLogin: false)
        check(!config.launchAtLogin, "the login checkbox reaches the config",
              "got \(config.launchAtLogin)")
        window.simulate(launchAtLogin: true)
        check(config.launchAtLogin, "and switches back on", "got \(config.launchAtLogin)")
        settle(0.7)
        if let data = try? Data(contentsOf: ConfigStore.url),
           let saved = try? JSONDecoder().decode(PetConfig.self, from: data) {
            check(saved.launchAtLogin, "and is persisted, so the next launch agrees with the box",
                  "file says launchAtLogin=\(saved.launchAtLogin)")
        } else {
            check(false, "config.json could be read back to check launchAtLogin persisted")
        }
        window.simulate(launchAtLogin: loginBefore)

        // --- [M11] the keys this window has no control for ---
        //
        // `birthday` and `dedication` are the gift layer, and neither has a control in the
        // Settings window. A window that rebuilt the config from its controls set both to
        // `nil`, `applyConfig` assigned the result wholesale and `ConfigStore.write`
        // replaced the file — so nudging the speed slider deleted them from disk, with no
        // way back but hand-editing JSON. These are the two lines that would have caught
        // it, so they live here now.
        var gift = config
        gift.birthday = "12-25"
        gift.dedication = "For you, {name} — every day."
        settingsDidChange(gift)
        window.loadFromConfig()
        check(config.dedication == gift.dedication && config.birthday == gift.birthday,
              "a birthday and a dedication can be configured at all",
              "birthday=\(config.birthday ?? "nil") dedication=\(config.dedication ?? "nil")")

        window.simulate(speed: 55)
        check(config.dedication == gift.dedication,
              "a configured dedication survives a slider move",
              "got \(config.dedication ?? "nil")")
        check(config.birthday == gift.birthday,
              "and so does the birthday", "got \(config.birthday ?? "nil")")

        window.simulate(color: config.color)
        check(config.dedication != nil && config.birthday != nil,
              "and touching the coat popup does not delete them either",
              "birthday=\(config.birthday ?? "nil") dedication=\(config.dedication ?? "nil")")

        settle(0.7)
        if let data = try? Data(contentsOf: ConfigStore.url),
           let saved = try? JSONDecoder().decode(PetConfig.self, from: data) {
            check(saved.dedication == gift.dedication && saved.birthday == gift.birthday,
                  "and they are still on disk after the debounced write — this is the one "
                  + "that matters, because the file is what the recipient keeps",
                  "file says birthday=\(saved.birthday ?? "nil") "
                  + "dedication=\(saved.dedication ?? "nil")")
        } else {
            check(false, "config.json could be read back to check the gift layer survived")
        }

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

        // Put the first cat in the coat that *leads the catalogue* before ticking the box.
        // That is the configuration the bug lived in: `fillCoats` always ends on
        // `selectItem(at:)`, so the second popup's selection is never nil, the
        // `?? coatUnlike(...)` behind it could never run, and the new cat silently took
        // `CatPalette.all[0]` — which is the default coat, and therefore usually the coat
        // the first cat is already wearing. Two identical cats. Written against
        // `all.first` rather than a colour name so it stays a real regression test however
        // the catalogue is reordered.
        guard let leadCoat = CatPalette.all.first?.id else {
            print("  FAIL  the coat catalogue is empty"); exit(1)
        }
        window.simulate(color: leadCoat)
        settle(0.2)
        let soloCoat = config.color
        check(soloCoat == leadCoat, "the first cat is wearing the coat that leads the popup",
              "got \(soloCoat), expected \(leadCoat)")

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

        // [M12] The kissing toggle, while there are two cats for it to govern.
        window.simulate(kisses: false)
        settle(0.2)
        check(config.kisses == false, "the kissing checkbox reaches the config",
              "got \(config.kisses)")
        check(!interactionCanKiss,
              "and takes the menu item away with it, rather than leaving one that does nothing")
        window.simulate(kisses: true)
        settle(0.2)
        check(config.kisses, "and switching it back on returns it", "got \(config.kisses)")
        check(interactionCanKiss, "along with the menu item")

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
        let beforeReset = config
        window.simulateReset()
        // [M11] Compared against the *validated* defaults rather than `.default` itself.
        // `validated()` fills the `pets` array in from the legacy keys, so no config that
        // has been through it is ever equal to the bare defaults — and every config in the
        // running app has been through it. The assertion, not the reset, was out of date.
        //
        // `birthday` and `dedication` are expected to survive the reset: this window has
        // no control for either, and "Reset to Defaults" resets what it controls rather
        // than deleting something the user can only put back by hand.
        var expectedAfterReset = PetConfig.default
        expectedAfterReset.birthday = beforeReset.birthday
        expectedAfterReset.dedication = beforeReset.dedication
        let defaults = expectedAfterReset.validated().config
        check(config == defaults, "Reset to Defaults restores the defaults",
              "got speed=\(config.speed) scale=\(config.scale) pets=\(config.pets.count)")
        check(config.dedication == beforeReset.dedication,
              "without deleting the dedication it cannot show",
              "got \(config.dedication ?? "nil")")

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
        // [M12] The hearts are the pair's rather than a pet's, and they own a timer.
        endKiss()
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

        // [M11] Bounded lifetime: once the window is off screen, drop the reference
        // rather than holding it — and re-dereferencing it twice a second — for the rest
        // of the app's run.
        //
        // Off screen, not `isFinished && off screen`. The window is `.closable`, and
        // `isFinished` is only ever set by `markGranted()`, so a first-run user who closed
        // it by hand without granting anything left it retained forever. Kept closable
        // rather than solving it by removing the close button: "not now" is a legitimate
        // answer on someone else's Mac, and the menu bar's "Grant Accessibility…" is the
        // way back — same shared ask, now that it actually opens the pane.
        if let onboarding = onboarding, !onboarding.isVisible {
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
        // [M12] A kiss is something to animate even when nothing is moving. Both cats sit
        // through the line and the hearts, and without this the timer would suspend on the
        // frame they sat down — taking the clock that ends the kiss with it and leaving the
        // pair sitting there with a bubble up, permanently. The other reasons still win;
        // `updateAnimationState` lets the kiss go rather than letting it hang.
        if kiss != nil { return nil }
        if pets.allSatisfy({ $0.isStationary(spriteSet: sprites(for: $0)) }) { return .stationary }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPowerMode }
        return nil
    }

    private func updateAnimationState() {
        if let reason = suspensionReason() {
            // [M12] The timer is about to stop, and the kiss is driven by it. Letting it go
            // here is what keeps "the Dock went away mid-kiss" from meaning "two cats sit
            // facing each other until the app is relaunched".
            if kiss != nil {
                print("[kiss] abandoned — the animation stopped (\(reason.rawValue))")
                releaseKiss()
            }
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

        // [M12] Before the pets move: the kiss decides where two of them are going, and
        // the phase it lands on this frame is what `moves:` below is asked about.
        advanceKiss(by: dt, on: strip)

        // [M11] One timer, every pet. SPEC §6: a second cat must not double the app's
        // wakeups — only the work done inside a wakeup.
        for pet in pets {
            pet.advanceAnimation(by: dt, on: strip, spriteSet: sprites(for: pet),
                                 moves: !isSteered(pet))
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
        // [M12] A kiss owns both cats for its whole length, including the parting walk —
        // without this, the overlap they are standing in during the kiss would be read as
        // a fresh meeting and put a conversation on top of it.
        guard kiss == nil else { return }
        let a = pets[0], b = pets[1]

        // Neither cat interrupts itself mid-sentence, and a cat being clicked is having a
        // conversation with a human, which takes precedence over one with a cat.
        guard !a.interaction.isTalking, !b.interaction.isTalking else { return }

        // An overlap with neither cat walking is not a meeting — it is two pets that
        // happen to be standing in the same place. Cheap insurance behind the spacing in
        // `startingPlace`: a degenerate stack must never be able to spend the cooldown on
        // an exchange nobody could read as one.
        guard a.behavior.state.isMoving || b.behavior.state.isMoving else { return }

        // SPEC §7 11e: the *left-hand* cat speaks first, and each line addresses the other
        // one. Which cat that is depends on where they are standing, not on their position
        // in the array.
        let aIsLeft = a.window.frame.minX <= b.window.frame.minX
        let opener = aIsLeft ? a : b
        let replier = aIsLeft ? b : a

        guard let encounter = meetings.meet(a.window.frame, b.window.frame,
                                            openerName: opener.profile.name,
                                            replierName: replier.profile.name,
                                            kissesAllowed: config.kisses) else { return }

        // [M12] One meeting in five, when kissing is switched on. The pair is handed to the
        // kiss whole — it does its own sitting, facing and parting — so nothing below this
        // point runs for it.
        guard case .chat(let exchange) = encounter else {
            beginKiss(opener, replier, reason: "they met")
            return
        }

        for pet in [a, b] {
            pet.behavior.force(.sit)
            pet.applyBehaviorState(.sit, spriteSet: sprites(for: pet))
        }
        // Face each other: the left-hand cat looks right, the right-hand cat looks left.
        opener.view.facing = .right
        replier.view.facing = .left

        // SPEC §9: the forced state change is invisible to the poll's own state log, which
        // only prints a transition `advanceBehavior` reported — and this one was imposed
        // from outside it. Without this line a `--verbose` reader sees two cats stop dead
        // with nothing saying why, on the one feature nobody can watch happen.
        logLocation("pet \(opener.index) and pet \(replier.index) meet — both sit")

        // SPEC §9: an exchange nobody can see has to be readable in the log.
        print("[meet] pet \(opener.index) → \"\(exchange.opener)\"")
        opener.interaction.showBubble(exchange.opener)

        DispatchQueue.main.asyncAfter(deadline: .now() + MeetingCoordinator.replyDelay) {
            [weak self, weak opener, weak replier] in
            // Weak on both, and the pet is confirmed still in the array before it speaks:
            // Settings can rebuild the cast during the second and a half between the line
            // and its answer, and a torn-down cat must not put a bubble back on screen.
            //
            // `isTalking` is checked for the same reason the guard at the top of this
            // method checks it, in the other direction: if the human clicked this cat
            // during the gap, the meeting must not steal the bubble back off them.
            guard let self, let replier,
                  self.pets.contains(where: { $0 === replier }),
                  !replier.interaction.isTalking else { return }
            print("[meet] pet \(replier.index) → \"\(exchange.reply)\"")

            // Take the opener's bubble down before the answer goes up. Nothing else does:
            // each bubble runs its own reading-time timer, and `BubbleGeometry.frame`
            // centres a bubble over its own pet's midX. The two cats stand 34–64 pt apart
            // and a line is around 215 pt wide, so leaving the first up means roughly a
            // second and a half of two opaque rectangles and two tails overlapping — the
            // milestone's headline feature reading as a rendering glitch.
            //
            // Deliberate trade-off: `dismissBubble()` clears the opener's `isTalking`,
            // which restarts its behaviour clock (`Pet.advanceBehavior` freezes that clock
            // while a pet is talking). Acceptable here — the opener was just forced into
            // `.sit`, which carries a 3–9 s dwell, so it stays sitting through the answer
            // either way.
            opener?.interaction.dismissBubble()
            replier.interaction.showBubble(exchange.reply)
        }

        // Both turn around and walk back the way they came, so the next tick separates
        // them instead of finding them still overlapping.
        for pet in [a, b] { pet.walker.reverse() }
        updateAnimationState()
    }

    // MARK: - [M12] The kiss

    /// Whether this pet's position is being driven by the kiss rather than by its walker.
    ///
    /// True only during the approach. Once they are touching, the pair sits — and the walk
    /// away afterwards is an ordinary walk in a reversed direction, which is what makes the
    /// parting look like the cats decided it rather than like a cutscene.
    private func isSteered(_ pet: Pet) -> Bool {
        guard let kiss, kiss.routine.phase == .approach else { return false }
        return pet === kiss.left || pet === kiss.right
    }

    /// Start a kiss between two cats: they drop what they are saying and set off.
    ///
    /// `reason` is for the log and nothing else — SPEC §9, on a six-second sequence nobody
    /// reading this can watch. "they met" and "asked for it" are the two.
    private func beginKiss(_ a: Pet, _ b: Pet, reason: String) {
        guard kiss == nil, pets.count == 2 else { return }

        // Settled here, once. During the approach the two cats cross and re-cross; reading
        // "who is on the left" per frame would move the line from one cat to the other
        // mid-sentence.
        let aIsLeft = a.window.frame.minX <= b.window.frame.minX
        let left = aIsLeft ? a : b
        let right = aIsLeft ? b : a
        kiss = KissInProgress(left: left, right: right)

        // A cat mid-sentence stops talking rather than walking off with its bubble in tow.
        for pet in [left, right] {
            pet.interaction.dismissBubble()
            pet.behavior.force(.walk)
            pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
        }

        print("[kiss] pet \(left.index) and pet \(right.index) set off — \(reason)")
        logLocation("pet \(left.index) and pet \(right.index) walk toward each other")
        updateAnimationState()
    }

    /// One frame of the kiss: steer the pair, then act on any phase it just entered.
    private func advanceKiss(by dt: TimeInterval, on strip: WalkStrip) {
        guard var current = kiss else { return }

        // Settings can rebuild the cast at any moment, and a kiss holding two cats that are
        // no longer on screen would keep the hearts up over nothing and never end.
        guard pets.contains(where: { $0 === current.left }),
              pets.contains(where: { $0 === current.right }) else {
            print("[kiss] abandoned — the cast changed mid-kiss")
            endKiss()
            return
        }

        let left = current.left, right = current.right
        let touching = MeetingCoordinator.haveMet(left.window.frame, right.window.frame)
        let (previous, phase) = current.routine.advance(by: dt, touching: touching)
        kiss = current

        if phase != previous { enterKissPhase(phase, previous: previous, on: strip) }

        // Per-frame work, after the transition so a phase entered this frame gets its own
        // first frame rather than the outgoing phase's.
        switch kiss?.routine.phase {
        case .approach:
            // Both walk to the point between them. Recomputed every frame rather than
            // fixed at the start: the strip can move or shrink under them mid-approach, and
            // a target from four seconds ago can be somewhere neither cat can stand.
            let midpoint = (left.walker.distance + right.walker.distance) / 2
            for pet in [left, right] {
                pet.walker.walk(toward: midpoint, by: dt,
                                maxDistance: Geometry.maximumDistance(for: pet.size, on: strip))
            }
            // Facing is set from the pair rather than from each walker's direction: the two
            // are the same thing during the approach, except on the frames where a cat has
            // arrived and stopped, and a cat that turns its back the moment it arrives is
            // the one frame of this anybody would notice.
            left.view.facing = .right
            right.view.facing = .left
        case .kiss:
            // The Dock can be resized mid-kiss; the hearts belong over the pair, not over
            // the place the pair was standing when they went up.
            kiss?.hearts?.reposition(over: left.window.frame.union(right.window.frame))
        default:
            break
        }
    }

    /// The one-shot work that belongs to a phase: the line, the hearts, the parting.
    private func enterKissPhase(_ phase: KissRoutine.Phase, previous: KissRoutine.Phase,
                                on strip: WalkStrip) {
        guard let current = kiss else { return }
        let left = current.left, right = current.right

        switch phase {
        case .approach:
            break   // where every kiss starts; nothing to enter

        case .announce:
            for pet in [left, right] {
                pet.behavior.force(.sit)
                pet.applyBehaviorState(.sit, spriteSet: sprites(for: pet))
            }
            left.view.facing = .right
            right.view.facing = .left
            print("[kiss] pet \(left.index) → \"\(Phrasebook.kissLine)\"")
            logLocation("pet \(left.index) and pet \(right.index) reach each other — both sit")
            left.interaction.showBubble(Phrasebook.kissLine)

        case .kiss:
            // The line comes down before the hearts go up, for the reason the meeting takes
            // the opener's bubble down before the reply: two cats this close share the space
            // a bubble needs, and a bubble under the hearts reads as a rendering glitch.
            left.interaction.dismissBubble()
            let hearts = HeartsWindow(over: left.window.frame.union(right.window.frame),
                                      scale: config.scale)
            kiss?.hearts = hearts
            print("[kiss] pet \(left.index) and pet \(right.index) kiss — hearts up")
            // The routine's own clock ends this phase; the hearts' timer only draws them.
            // Nothing is hung off `onFinish` beyond dropping the reference, so a stalled
            // frame cannot leave the pair sitting there forever waiting on a window.
            hearts.start { [weak self] in self?.kiss?.hearts = nil }

        case .part:
            kiss?.hearts?.dismiss()
            kiss?.hearts = nil
            for pet in [left, right] {
                pet.walker.reverse()
                pet.behavior.force(.walk)
                pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
                pet.view.facing = pet.walker.direction == .forward ? .right : .left
            }
            print("[kiss] pet \(left.index) and pet \(right.index) part")
            updateAnimationState()

        case .done:
            if current.routine.abandoned {
                // The approach ran out of time — a Dock that moved, a strip that shrank, a
                // cat that could not reach the midpoint. Say so: two cats walking toward
                // each other and then giving up is otherwise unexplainable in the log.
                print("[kiss] abandoned — the two never reached each other")
                for pet in [left, right] {
                    pet.behavior.force(.walk)
                    pet.applyBehaviorState(.walk, spriteSet: sprites(for: pet))
                }
            }
            endKiss()
        }
    }

    /// Let the kiss go: hearts down, pair handed back to its own behaviour.
    ///
    /// Also the teardown path — called when the cast changes mid-kiss and when the app
    /// quits — so there is one place that can leave a hearts window on screen, rather than
    /// three.
    func endKiss() {
        guard kiss != nil else { return }
        releaseKiss()
        updateAnimationState()
    }

    /// Drop the kiss without touching the timer.
    ///
    /// Separate from `endKiss` for one caller: `updateAnimationState` itself, which is
    /// already deciding about the timer when it finds a kiss it has to let go. Calling
    /// `endKiss` from there would re-enter it.
    private func releaseKiss() {
        guard let current = kiss else { return }
        current.hearts?.dismiss()
        // A kiss let go mid-sentence must not leave the line hanging over a cat that has
        // gone back to walking.
        for pet in [current.left, current.right] { pet.interaction.dismissBubble() }
        kiss = nil

        // [M12] The pair has just spent six seconds together; the cooldown is stamped so
        // they do not strike up a conversation the instant they stop kissing. It is already
        // stamped for a kiss that came out of a meeting — doing it again is harmless, and
        // it is the only stamp a kiss asked for from the menu ever gets.
        meetings.noteMeeting()
    }

    /// Exposed so `--kiss-test` can follow a sequence it cannot watch. `nil` when no kiss
    /// is under way, which is nearly always.
    var kissPhase: KissRoutine.Phase? { kiss?.routine.phase }

    /// Exposed for the same reason: the hearts are the one part of the kiss with no line
    /// in the log of its own while it is on screen.
    var kissHeartsAreUp: Bool { kiss?.hearts?.isVisible ?? false }

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
            // [M12] A kiss holds both cats out of their own behaviour for six seconds. With
            // nothing here, a `--verbose` reader sees two cats walk into each other, sit,
            // stand up and part, with every per-pet line above saying only `behavior=sit`
            // and no line anywhere naming the thing that is happening.
            if let kiss {
                line += " kiss=\(kiss.routine.phase.rawValue)"
                line += " kissClock=\(Self.f(CGFloat(kiss.routine.timeInPhase)))s"
                line += " hearts=\(kiss.hearts?.isVisible == true)"
            }
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

        // Two asks, because neither is enough on its own.
        //
        // `AXIsProcessTrustedWithOptions(prompt:)` shows the system alert — the one that
        // deep-links and registers *this* binary's signature — but only while no TCC
        // record exists for us. Once the user has answered it, dismissed it, or clicked
        // Deny, every later call returns false and presents nothing at all. A button
        // labelled "Open Accessibility Settings…" that does nothing from the second click
        // onwards is precisely the dead end the onboarding window exists to prevent.
        let prompted = DockTiles.requestTrust()

        // So always open the pane too. It is a no-op cost when the alert did appear (the
        // pane the alert links to is the pane we open), and it is the whole fix when it
        // did not.
        if let url = URL(string: "x-apple.systempreferences:"
                         + "com.apple.preference.security?Privacy_Accessibility") {
            let opened = NSWorkspace.shared.open(url)
            print("[state] system alert shown: \(!prompted ? "no (already answered once)" : "yes")"
                  + ", Accessibility pane opened: \(opened)")
        }
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
        var newConfig = newConfig
        let previous = config
        // [M11] Guarded the same way as the launch-time call: a self-test must not rewrite
        // the user's real login item as a side effect of checking something else.
        if !options.isSelfTest, newConfig.launchAtLogin != config.launchAtLogin {
            if case .failure(let error) = LoginItem.setEnabled(newConfig.launchAtLogin) {
                // SPEC 11a again: logged and clamped to "off". Clamped on `newConfig`,
                // before it is assigned and before `scheduleSave()` writes it out, so what
                // lands in config.json is what actually happened rather than what was
                // asked for. Ticking the box on a Mac that will not accept our local
                // self-signed identity used to persist `"launchAtLogin": true` and give
                // the user no sign it had not taken.
                print("[config] could not set launch at login (\(error.localizedDescription))")
                print("[config] clamping launchAtLogin to false — \(LoginItem.statusDescription)")
                newConfig.launchAtLogin = false
            }
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

            // [M11] Compared **per pet and in order**, not as a set of loaded coats. Swap
            // cat 0 to grey and cat 1 to orange in one change and the set of coats is
            // identical, so nothing would reload: each cat would keep the other's art
            // while its profile, the launch log, `--verbose` and `--render-test` all
            // claimed the new coat. That is exactly the failure the per-pet sprite set
            // exists to prevent, reintroduced one level up.
            let wanted = cast.map(\.palette.id)
            let reassign = wanted != Self.cast(of: previous).map(\.palette.id)
            if rebuildSprites, !wanted.allSatisfy({ spriteSets[$0] != nil }) {
                // A coat with no sheets in memory. The recolour happens as the sheets are
                // decoded, so a new coat means reading them again — re-scaling the sets
                // already in memory would only resize the colours they already have.
                reloadSprites()
            } else if rebuildSprites, reassign || config.scale != previous.scale {
                // Same sheets, different cats wearing them — or a new scale. Re-handing
                // them out costs no disk read.
                applySprites(spriteSets)
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

    /// [M12] Three conditions, all of which can change between one click and the next.
    var interactionCanKiss: Bool { config.kisses && pets.count == 2 && kiss == nil }

    func interactionRequestKiss() {
        // Re-checked rather than trusted: the menu was built when the click landed, and a
        // menu can sit open while the other cat is dropped from Settings or starts a kiss
        // of its own.
        guard interactionCanKiss else { return }
        beginKiss(pets[0], pets[1], reason: "asked for it")
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

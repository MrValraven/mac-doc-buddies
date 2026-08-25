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

    private let options: LaunchOptions
    private var locator = DockLocator()
    private var config = PetConfig.default

    private var window: PetWindow?
    private var locatorTimer: Timer?
    private var animationTimer: Timer?
    private var verboseTimer: Timer?

    /// SPEC §7 M5. Seeded from the system generator so each launch differs, while the type
    /// itself stays deterministic and testable.
    private var behavior = BehaviorMachine(seed: UInt64.random(in: UInt64.min...UInt64.max))
    private var lastPollTime: CFTimeInterval = 0

    private var spriteSet: SpriteSet?
    private var petView: PetView?
    private var menuBarItem: MenuBarItem?
    private var settingsWindow: SettingsWindow?
    private var saveDebounce: Timer?
    private var paused = false
    /// Kept alive for the lifetime of the app; a released source stops delivering.
    /// [M10] Clicking the pet: hit testing, the prompt menu, and the speech bubble.
    private let interaction = PetInteraction()

    private var reloadSignalSource: DispatchSourceSignal?
    private var sequencer = FrameSequencer(frameCount: 1, fps: 1)

    /// Size in points, derived from the sheet — never hardcoded (SPEC §5).
    private var petSize: CGSize = .zero

    private var currentLocation: DockLocation?
    /// Speed is overwritten from config.json at launch.
    private var walker = Walker(speed: 30)
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
        walker.speed = CGFloat(config.speed)
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

        // SPEC §5: a missing or malformed walk sheet is fatal and loud, never silently
        // skipped. Optional per-state sheets are not fatal — they degrade to a still pose.
        let set: SpriteSet
        let spriteNotes: [String]
        do {
            (set, spriteNotes) = try SpriteLoader.loadSet(palette: config.palette)
        } catch {
            print("  !! FATAL: could not load sprite sheet — \(error)")
            exit(1)
        }
        self.spriteSet = set
        let m = set.walk.metadata
        self.sequencer = FrameSequencer(frameCount: m.frameCount, fps: m.fps)
        self.petSize = m.pointSize(scale: config.scale)

        print("  sprite           : \(set.walk.origin)")
        print("  walk sheet       : \(m.frameCount) frames, \(m.frameWidth)x\(m.frameHeight) px each, \(Self.f(CGFloat(m.fps))) fps")
        for note in spriteNotes { print("    \(note)") }
        print("  drawn at         : \(Self.f(petSize.width))x\(Self.f(petSize.height)) pt (scale \(config.scale)x)")
        for screen in NSScreen.screens {
            let ratio = m.devicePixelsPerArtPixel(scale: config.scale,
                                                  backingScaleFactor: screen.backingScaleFactor)
            let crisp = m.isCrisp(scale: config.scale, backingScaleFactor: screen.backingScaleFactor)
            print("    \"\(screen.localizedName)\": \(Self.f(ratio)) device px per art px \(crisp ? "(crisp)" : "!! NOT AN INTEGER — art will shimmer")")
        }

        if options.renderTest {
            RenderTest.run(spriteSet: set, scale: config.scale)
        }

        let view = PetView(frame: NSRect(origin: .zero, size: petSize), spriteSet: set)
        if view.sliceCount(for: .walk) != m.frameCount {
            print("  !! FATAL: sliced \(view.sliceCount(for: .walk)) frames but the walk sheet declares \(m.frameCount)")
            exit(1)
        }
        self.petView = view
        let window = PetWindow(contentRect: NSRect(origin: .zero, size: petSize), content: view)
        self.window = window

        // [M10] The pet becomes clickable from here on. The window still ignores mouse
        // events by default; the interaction only switches that on while the cursor is
        // actually over the cat, so the Dock keeps every other click.
        interaction.delegate = self
        interaction.attach(to: view, in: window)
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
        check(walker.speed == 60, "and reaches the walker immediately", "got \(walker.speed)")

        // --- scale rebuilds the sprite at a new size ---
        let frameWidth = spriteFrameSize.width
        window.simulate(scale: 3)
        check(config.scale == 3, "the size popup updates the config")
        check(petSize.width == frameWidth * 3,
              "and the pet is rebuilt at the new scale",
              "expected \(frameWidth * 3) pt wide, got \(petSize.width)")
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
        check(config == .default, "Reset to Defaults restores the defaults",
              "got speed=\(config.speed) scale=\(config.scale)")

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

    /// Drives the menu bar item's pause/resume path and checks the consequences.
    private func runMenuTest() -> Never {
        var failures = 0
        var checks = 0
        func check(_ passed: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
            checks += 1
            if passed { print("  ok    \(what)") }
            else { failures += 1; print("  FAIL  \(what)\(detail().isEmpty ? "" : " — \(detail())")") }
        }

        print("MenuTest")
        check(menuBarItem != nil, "status item was created")
        check(menuBarItem?.iconDescription == "cat.fill symbol",
              "the menu bar icon is the cat symbol, not the text fallback",
              "got \(menuBarItem?.iconDescription ?? "nil")")
        check(!isPaused, "starts unpaused")

        let running = statusSummary
        check(!running.isEmpty && running != "Paused", "status summary describes the pet",
              "got \"\(running)\"")
        let wasVisible = window?.isVisible ?? false

        setPaused(true)
        check(isPaused, "pause takes effect")
        check(statusSummary == "Paused", "status summary reports Paused", "got \"\(statusSummary)\"")
        check(suspensionReason() == .paused, "suspension reason is 'paused'",
              "got \(String(describing: suspensionReason()))")
        check(animationTimer == nil, "animation timer is suspended, not merely idle")
        check(window?.isVisible == false, "the pet is hidden while paused")
        check(locatorTimer?.isValid == true, "the 500 ms locator poll keeps running so resume works")

        setPaused(false)
        check(!isPaused, "resume takes effect")
        check(statusSummary != "Paused", "status summary stops reporting Paused")
        if wasVisible {
            check(window?.isVisible == true, "the pet comes back after resuming")
            check(animationTimer != nil, "and the animation timer restarts")
        }

        // --- reload ---------------------------------------------------------------
        check(!spriteSummary.isEmpty && spriteSummary != "No sheets loaded",
              "sprite summary lists the loaded sheets", "got \"\(spriteSummary)\"")

        // Prove reload genuinely re-reads config rather than no-opping: corrupt the live
        // value first and check it comes back from disk.
        walker.speed = 999
        let sizeBefore = petSize
        reload()
        check(walker.speed == CGFloat(config.speed),
              "reload re-reads config.json and reapplies speed",
              "speed is \(walker.speed), config says \(config.speed)")
        check(spriteSet != nil, "reload leaves a sprite set loaded")
        check(petView != nil, "reload rebuilds the pet view")
        check(petSize == sizeBefore, "reload keeps the pet size when nothing changed",
              "\(sizeBefore) -> \(petSize)")
        check(window?.contentView === petView, "the rebuilt view is installed in the window")
        check(reloadSignalSource != nil, "SIGHUP reload handler is installed")

        print("")
        if failures > 0 { print("\(failures) of \(checks) checks FAILED"); exit(1) }
        print("all \(checks) checks passed")
        exit(0)
    }

    /// [M10] Drives a click on the pet and checks what comes back.
    ///
    /// The parts that can be checked without a screen are already covered by the test
    /// executable — Phrasebook picks the words, BubbleGeometry places the bubble, AlphaMask
    /// decides what counts as a click. What is left is the wiring, and the wiring needs a
    /// real window with a real sprite in it, which is what this is. SPEC §9: the claims
    /// below are all readable from the log.
    private func runInteractionTest() -> Never {
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

        print("InteractionTest")

        guard let view = petView, let petWindow = window else {
            print("  FAIL  the pet view and window exist")
            exit(1)
        }

        // --- hit testing ----------------------------------------------------------
        // The cat is drawn feet-down and centred, so the middle of the frame is art and
        // the top corners are the empty space above its ears.
        let middle = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        check(view.isOverSprite(middle), "the middle of the frame is the cat",
              "frame is \(Self.f(view.bounds))")

        // Printed unconditionally: the two checks below are about *where* the art is, and
        // when one fails this is the only thing that says why.
        print("  the clickable cat (# art, + tolerance, . click-through):")
        for line in view.silhouetteDescription().split(separator: "\n") {
            print("        \(line)")
        }

        // Nothing is assumed about the art: the shipped cat leaves its corners empty, but
        // the generated placeholder sheet is a solid block, and a check that passes or
        // fails on which sheet loaded would be worse than none.
        if let through = view.clickThroughSample() {
            check(!view.isOverSprite(through),
                  "the empty space around the cat is not — this is what leaves the Dock its clicks",
                  "at \(Self.f(through.x)),\(Self.f(through.y))")
            check(view.hitTest(view.convert(through, to: view.superview)) == nil,
                  "and the view declines to handle a click there")
        } else {
            print("  note  this sheet fills its whole frame, so there is no transparent "
                  + "margin to fall through — clicks in the frame all belong to the pet")
        }

        // Outside the window is always somebody else's click, whatever the art looks like.
        let outside = NSPoint(x: view.bounds.maxX + 10, y: view.bounds.midY)
        check(!view.isOverSprite(outside), "a point outside the pet's frame is never the cat")

        // --- the cursor ------------------------------------------------------------
        // The cursor is the only hint that the cat is clickable at all, and it is the one
        // part of this feature that cannot be checked by looking at a screenshot: the
        // pointer is not in the picture. So the decision is checked directly.
        check(view.cursor(at: middle) == .pointingHand,
              "the cursor over the cat is a pointing hand, so the cat looks clickable")

        if let through = view.clickThroughSample() {
            check(view.cursor(at: through) == .arrow,
                  "and goes back to an arrow over the space the Dock still owns")
        }

        // The cursor must agree with the hit test everywhere, not just at two points: a
        // pointing hand over a spot that does not take clicks is a worse lie than no
        // cursor change at all.
        var disagreements = 0
        for row in 0..<32 {
            for column in 0..<32 {
                let point = NSPoint(x: view.bounds.width * (CGFloat(column) + 0.5) / 32,
                                    y: view.bounds.height * (CGFloat(row) + 0.5) / 32)
                let saysClickable = view.cursor(at: point) == .pointingHand
                if saysClickable != view.isOverSprite(point) { disagreements += 1 }
            }
        }
        check(disagreements == 0,
              "the cursor promises exactly what the hit test delivers, across the frame",
              "\(disagreements) of 1024 sampled points disagree")

        // A tracking area is what makes any of this work for a window that can never be
        // key (SPEC §3). Without `.activeAlways` the system would only update the cursor
        // for the active app, which DockPet never is.
        if let area = view.cursorTrackingArea {
            check(area.options.contains(.activeAlways),
                  "the tracking area is active even though the app never is")
            check(area.options.contains(.cursorUpdate),
                  "and asks for cursor updates")
            check(view.trackingAreas.contains(area), "and is actually installed on the view")
        } else {
            check(false, "the pet view has a cursor tracking area")
        }

        // A click-through window that never switches on is a cat you cannot click; one that
        // never switches off is a Dock you cannot use. Both directions are checked.
        check(petWindow.ignoresMouseEvents,
              "the window ignores mouse events while the cursor is elsewhere")

        // --- the prompts ----------------------------------------------------------
        for prompt in PetPrompt.allCases {
            interaction.dismissBubble()
            interaction.say(prompt)
            settle(0.25)

            guard let reply = interaction.lastReply, let bubble = interaction.bubbleFrame else {
                check(false, "\(prompt.rawValue) produces a reply and a bubble")
                continue
            }

            check(!reply.isEmpty && !reply.contains("{name}"),
                  "\(prompt.rawValue) answers in words, with the name slot filled",
                  "got \"\(reply)\"")
            check(interaction.isTalking, "\(prompt.rawValue) leaves the pet talking")

            let pet = petWindow.frame
            check(bubble.minY >= pet.maxY,
                  "\(prompt.rawValue): the bubble sits above the cat, not over it",
                  "bubble \(Self.f(bubble)) vs pet \(Self.f(pet))")

            if let screen = currentLocation?.screen {
                let vf = screen.visibleFrame
                check(bubble.minX >= vf.minX && bubble.maxX <= vf.maxX
                      && bubble.maxY <= vf.maxY,
                      "\(prompt.rawValue): the bubble is fully on screen",
                      "bubble \(Self.f(bubble)) vs visibleFrame \(Self.f(vf))")
            }

            check(!behavior.state.isMoving,
                  "\(prompt.rawValue): the pet stops walking while it talks",
                  "state is \(behavior.state.rawValue)")
        }

        // --- the nap is the one prompt that changes what the pet does afterwards ---
        interaction.dismissBubble()
        interaction.say(.nap)
        settle(0.2)
        check(behavior.state == .sleep, "\"Take a nap\" actually puts the pet to sleep",
              "state is \(behavior.state.rawValue)")

        // --- the name -------------------------------------------------------------
        let originalConfig = config
        applyConfig(PetConfig(speed: config.speed, scale: config.scale, screen: config.screen,
                              menuBarIcon: config.menuBarIcon, color: config.color,
                              userName: "Testcat"), persist: false)
        check(effectiveUserName == "Testcat", "a configured name is the one the pet uses",
              "got \(String(describing: effectiveUserName))")

        var sawTheName = false
        for _ in 0..<12 {
            interaction.dismissBubble()
            interaction.say(.hello)
            if interaction.lastReply?.contains("Testcat") == true { sawTheName = true; break }
        }
        check(sawTheName, "and it reaches the bubble", "last was \"\(interaction.lastReply ?? "")\"")

        applyConfig(originalConfig, persist: false)
        check(config == originalConfig, "the test restored your original settings")

        // --- the bubble goes away on its own --------------------------------------
        interaction.dismissBubble()
        interaction.say(.hello)
        settle(0.2)
        check(interaction.isTalking, "the bubble is up")
        let staysUp = BubbleGeometry.readingTime(for: interaction.lastReply ?? "")
        settle(staysUp + 0.6)
        check(!interaction.isTalking, "and takes itself down again without a second click",
              "still up after \(Self.f(CGFloat(staysUp)) )s")
        check(interaction.bubbleFrame == nil, "leaving no window behind")

        // --- a picture of it, since nobody reading this log can see my screen ------
        if let path = options.shotPath {
            interaction.say(.hello)
            settle(0.35)
            if let bubbleView = interaction.bubbleFrame.flatMap({ _ in
                    NSApp.windows.compactMap { $0 as? BubbleWindow }.first?.contentView }),
               let rep = bubbleView.bitmapImageRepForCachingDisplay(in: bubbleView.bounds) {
                bubbleView.cacheDisplay(in: bubbleView.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("  shot  wrote \(path) (\(Int(bubbleView.bounds.width))x\(Int(bubbleView.bounds.height)) pt)")
                } else {
                    check(false, "the bubble could be encoded to PNG")
                }
            } else {
                check(false, "the bubble could be rendered offscreen")
            }
            interaction.dismissBubble()
        }

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
        // registered during teardown is a callback into a half-dead app.
        interaction.stopMouseTracking()
        interaction.dismissBubble()
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
        guard let window = window else { return }

        // Real elapsed time, not the nominal interval: the timer can be late.
        let now = CACurrentMediaTime()
        let dt = lastPollTime == 0 ? 0 : now - lastPollTime
        lastPollTime = now

        if paused {
            currentLocation = nil
            if window.isVisible { window.orderOut(nil) }
            suspendAnimation()
            logAnimation("suspended — \(AnimationSuspension.paused.rawValue)")
            return
        }

        switch locator.locate() {
        case .located(let location):
            currentLocation = location

            // The behaviour clock only runs while the pet is actually on screen — a pet
            // that spent the last hour dormant should not wake up mid-nap. Advanced here
            // rather than on the animation timer because this timer is the one that always
            // runs; the animation timer is suspended for three of the four states.
            let previousState = behavior.state
            // [M10] The behaviour clock stops while the pet is talking, so it holds the
            // pose it answered in rather than wandering out from under its own sentence.
            let state = interaction.isTalking ? previousState : behavior.advance(by: dt)
            if state != previousState {
                logLocation("\(state.rawValue) on \(location.screen.localizedName)")
                applyBehaviorState(state)
            }
            // [M10] Also here, not only on the animation tick: that timer is suspended
            // for three of the four states (SPEC §6), so a sitting or sleeping cat would
            // depend entirely on the mouse monitor to become clickable. This poll always
            // runs, which caps how long the cat can be wrongly click-through at 500 ms.
            interaction.updateClickThrough()

            // The strip may have changed shape since the last poll; make sure the pet is
            // still standing on it before the next animation frame moves it.
            walker.clamp(to: Geometry.maximumDistance(for: petSize, on: location.strip))
            position(in: window, on: location.strip)
            if !window.isVisible {
                window.orderFront(nil)   // SPEC §3: never makeKeyAndOrderFront
            }

        case .absent(let reason):
            currentLocation = nil
            if window.isVisible {
                window.orderOut(nil)
            }
            logLocation("dormant — \(reason.rawValue)")
        }

        updateAnimationState()
    }

    /// SPEC §6's suspension conditions, in priority order.
    private func suspensionReason() -> AnimationSuspension? {
        if paused { return .paused }
        if currentLocation == nil { return .dockNotLocated }
        // [M6] Suspend when there is nothing to animate: the pet is stationary AND this
        // state has no multi-frame sheet of its own. With a sit or sleep animation
        // supplied, the timer keeps running so that animation plays — the pet simply does
        // not move. Same reasoning as SPEC §6's listed conditions: never run a 12 fps timer
        // to redraw an unchanged frame.
        if !behavior.state.isMoving && !(spriteSet?.isAnimated(behavior.state) ?? false) {
            return .stationary
        }
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
        guard let window = window, let location = currentLocation else { return }

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

        // [M6] Only walking moves the pet. A sit or sleep animation still plays below.
        if behavior.state.isMoving {
            walker.advance(by: dt, maxDistance: Geometry.maximumDistance(for: petSize, on: strip))
            // SPEC §5: flip horizontally for the return trip rather than shipping mirrored art.
            petView?.facing = walker.direction == .forward ? .right : .left
        }
        position(in: window, on: strip)

        // The sheet plays at its own fps, independent of this timer's rate.
        sequencer.advance(by: dt)
        petView?.frameIndex = sequencer.index

        // [M10] Two things move the cat relative to the cursor: the cursor, which the
        // interaction's own mouse monitor catches, and the cat, which is this. The bubble
        // follows for the same reason — the Dock can be resized mid-sentence.
        interaction.updateClickThrough()
        if interaction.isTalking { interaction.positionBubble() }
    }

    /// [M6] Swap to a state's sheet and restart its cycle from the top rather than
    /// resuming mid-stride.
    ///
    /// [M10] Called from the poll when the behaviour machine changes state on its own, and
    /// from `interactionForcePetState` when a click changes it instead.
    private func applyBehaviorState(_ state: PetState) {
        let sheet = spriteSet?.sheet(for: state)
        sequencer = FrameSequencer(frameCount: sheet?.metadata.frameCount ?? 1,
                                   fps: sheet?.metadata.fps ?? 1)
        petView?.state = state
        petView?.frameIndex = 0
    }

    private func position(in window: PetWindow, on strip: WalkStrip) {
        let frame = Geometry.petFrame(size: petSize, on: strip, distance: walker.distance)
        window.setFrame(frame, display: true)
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
        let frame = window?.frame ?? .zero
        let suspension = suspensionReason()

        if let location = currentLocation {
            let vf = location.screen.visibleFrame
            let strip = location.strip

            // The positional claim, stated as a boolean so success is checkable from the
            // log alone (SPEC §9 — you cannot see my screen, and I cannot see yours).
            let restsOnEdge: Bool
            switch strip.edge {
            case .bottom: restsOnEdge = abs(frame.minY - strip.baseline) < 0.001
            case .left:   restsOnEdge = abs(frame.minX - strip.baseline) < 0.001
            case .right:  restsOnEdge = abs(frame.maxX - strip.baseline) < 0.001
            }
            let onStrip = walker.distance >= 0
                && walker.distance <= Geometry.maximumDistance(for: petSize, on: strip) + 0.001

            line += "state=\(suspension == nil ? "walking" : "suspended")"
            line += " screen=\"\(location.screen.localizedName)\""
            line += " scale=\(Self.f(location.screen.backingScaleFactor))"
            line += " visibleFrame=\(Self.f(vf))"
            line += " dockEdge=\(strip.edge.rawValue)"
            line += " baseline=\(Self.f(strip.baseline))"
            line += " strip=[\(Self.f(strip.start))...\(Self.f(strip.end))]"
            line += " tiles=" + (location.tiles.map { "[\(Self.f($0.minX))...\(Self.f($0.maxX))]" }
                                 ?? "unmeasured")
            line += " distance=\(Self.f(walker.distance))/\(Self.f(Geometry.maximumDistance(for: petSize, on: strip)))"
            line += " dir=\(walker.direction == .forward ? "forward" : "backward")"
            line += " window=\(Self.f(frame))"
            line += " restsOnDockEdge=\(restsOnEdge)"
            line += " onStrip=\(onStrip)"
            line += " visible=\(window?.isVisible ?? false)"
            line += " behavior=\(behavior.state.rawValue)"
            line += " sheet=\((spriteSet?.hasOwnSheet(for: behavior.state) ?? false) ? "own" : "walk-fallback")"
            line += " dwell=\(Self.f(CGFloat(behavior.timeInState)))/\(Self.f(CGFloat(behavior.currentDwell)))s"
            line += " transitions=\(behavior.transitionCount)"
            line += " frame=\(sequencer.index)/\(sequencer.frameCount)"
            line += " facing=\(petView?.facing == .left ? "left" : "right")"
            if !restsOnEdge { line += "  !! WINDOW IS NOT ON THE DOCK EDGE" }
            if !onStrip { line += "  !! PET HAS LEFT THE STRIP" }
        } else {
            line += "state=dormant"
            line += " dockOnScreen=\(DockLocator.isDockOnScreen())"
            line += " visible=\(window?.isVisible ?? false)"
            // Shown anyway: under autohide this is unchanged, which is exactly the trap
            // that makes the presence check necessary (PROBE.md F4).
            if let main = NSScreen.screens.first {
                line += " screens[0].visibleFrame=\(Self.f(main.visibleFrame))"
            }
        }

        // No Dock rect is logged: SPEC §4b [M0] uses the window list for presence only and
        // never reads its bounds, so there is no second coordinate space in play.
        // [M10] Clicking is invisible in a log otherwise: whether the window is currently
        // accepting mouse events is the whole difference between a clickable cat and a
        // Dock that has stopped responding, and it changes as the cursor moves.
        line += " takesClicks=\(window?.ignoresMouseEvents == false)"
        line += " talking=\(interaction.isTalking)"
        if let reply = interaction.lastReply, interaction.isTalking {
            line += " saying=\"\(reply)\""
            line += " bubble=\(interaction.bubbleFrame.map { Self.f($0) } ?? "none")"
        }
        line += " locatorTimer=\(locatorTimer?.isValid == true ? "active" : "invalid")"
        line += " animationTimer=\(animationTimer == nil ? "suspended" : "active(\(Int(Self.animationFPS))fps)")"
        line += " suspendReason=\(suspension?.rawValue ?? "none")"
        line += " lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
        print(line)
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
        guard let location = currentLocation else {
            if !DockTiles.isTrusted { return "Waiting for Accessibility" }
            return "Waiting — \(lastLocationDescription ?? "looking for the Dock")"
        }
        let verb: String
        switch behavior.state {
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
            let (set, notes) = try SpriteLoader.loadSet(palette: config.palette)
            for note in notes { print("[reload]   \(note)") }
            applySprites(set)
        } catch {
            print("[reload]   !! sprite reload failed, keeping the current sheets — \(error)")
        }

        // Reposition against the live strip straight away rather than waiting out the poll.
        poll()
        print("[reload] done — speed=\(Self.f(CGFloat(config.speed))) scale=\(config.scale)x "
              + "coat=\(config.color), \(spriteSummary)")
    }

    /// Make a config live. The single place any setting takes effect, whether it came from
    /// the file, a reload, or the Settings window.
    ///
    /// `rebuildSprites` is skipped by `reload()`, which reloads the sheets itself straight
    /// afterwards and would otherwise rebuild the view twice.
    private func applyConfig(_ newConfig: PetConfig, persist: Bool, rebuildSprites: Bool = true) {
        let previous = config
        if newConfig.launchAtLogin != config.launchAtLogin {
            LoginItem.setEnabled(newConfig.launchAtLogin)
        }
        config = newConfig

        walker.speed = CGFloat(config.speed)
        locator.pinnedScreenName = config.screen

        if rebuildSprites, config.color != previous.color {
            // The recolour happens as the sheets are decoded, so a new coat means reading
            // them again — re-scaling the set already in memory would only resize the
            // colour it already has.
            reloadSprites()
        } else if rebuildSprites, config.scale != previous.scale, let set = spriteSet {
            applySprites(set)          // recomputes petSize at the new scale
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

    var interactionUserName: String? { effectiveUserName }
    var interactionScale: Int { config.scale }
    var interactionScreen: NSScreen? { currentLocation?.screen }

    /// A click changed what the pet is doing. Unlike the poll's own transitions this can
    /// happen at any moment, so the sheet swap and the timer decision are both redone here.
    func interactionForcePetState(_ state: PetState) {
        let previous = behavior.state
        behavior.force(state)
        if behavior.state != previous {
            applyBehaviorState(behavior.state)
            logLocation("\(behavior.state.rawValue) (asked for it)")
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
            let (set, _) = try SpriteLoader.loadSet(palette: config.palette)
            applySprites(set)
            print("[settings] coat is now \(config.palette.displayName)")
        } catch {
            print("[settings] !! could not reload the sheets for the "
                  + "\(config.palette.displayName) coat, keeping the current one — \(error)")
        }
    }

    /// Swap in a new sprite set, keeping the pet's current state and heading.
    private func applySprites(_ set: SpriteSet) {
        spriteSet = set
        petSize = set.walk.metadata.pointSize(scale: config.scale)

        let sheet = set.sheet(for: behavior.state)
        sequencer = FrameSequencer(frameCount: sheet.metadata.frameCount, fps: sheet.metadata.fps)

        let view = PetView(frame: NSRect(origin: .zero, size: petSize), spriteSet: set)
        view.state = behavior.state
        view.facing = walker.direction == .forward ? .right : .left
        view.frameIndex = 0
        petView = view

        // The sheet may be a different size; resize before swapping so the view is not
        // briefly stretched.
        window?.setContentSize(petSize)
        window?.contentView = view

        // [M10] Re-attach: this is a brand new view, and an interaction still pointing at
        // the old one would leave the cat unclickable with nothing on screen to say why.
        if let window = window { interaction.attach(to: view, in: window) }
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

    private static func f(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

    private static func f(_ r: CGRect) -> String {
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

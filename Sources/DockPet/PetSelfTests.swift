//
//  PetSelfTests.swift — the self-tests that drive the pets and read the answer back.
//
//  [M11] Split out of AppDelegate as part of the `Pet` extraction. These three modes are
//  the entire safety net for work whose result is visual (SPEC §9: nobody reading the log
//  can see the screen), and they grew a loop each when `AppDelegate` stopped holding
//  exactly one of everything — a test that can only see pet 0 passes while the second cat
//  is broken.
//
//  `--settings-test` and `--dock-bounds` stay in AppDelegate: neither drives a pet. One
//  drives the Settings window, the other reads the Dock before any pet exists.
//

import AppKit
import DockPetCore

/// [M11] Mirrors the private `State` type in StateStore.swift, so `--dedication-test` can
/// decode the scratch state.json straight off disk — independent proof that the stamp was
/// actually written, not merely that `StateStore.lastGreetedDay`'s own read agrees with its
/// own write. Declared at file scope rather than nested inside the test function: a local
/// nested Codable type inside a function that ends by calling `exit` confuses the compiler's
/// reachability analysis into (wrongly) flagging that function's own final `if failures > 0`
/// as dead code.
private struct DedicationTestRawState: Codable { var lastGreetedDay: String? }

extension AppDelegate {

    /// `--render-test`: the per-pet half first, then `RenderTest`'s pixel checks.
    ///
    /// [M11] The pixel checks are about the sheets, which every pet shares, so they say
    /// nothing about whether each pet actually got a view of the right size with the sheet
    /// sliced into it. That is what this half is for, and it is indexed: a test that can
    /// only see pet 0 passes while the second cat is broken. Any failure here exits before
    /// `RenderTest.run`, which owns the exit code for everything after it.
    func runRenderTest() -> Never {
        print("\npets")
        var failures = 0

        guard let reference = spriteSet else {
            print("  FAIL no sprite sheets were loaded at all")
            exit(1)
        }
        // The shipped sheet in the colours it is actually drawn in, decoded once and
        // reused: every pet's coat is checked against it below.
        let baseBytes = (try? SpriteLoader.load(palette: .base))
            .flatMap { SpriteRecolor.rgbaBytes(of: $0.image) }

        for pet in pets {
            guard let set = sprites(for: pet) else {
                failures += 1
                print("  FAIL pet \(pet.index) coat=\(pet.profile.color)"
                      + " — no sheets were loaded for that coat")
                continue
            }
            let sliced = pet.view.sliceCount(for: .walk)
            let framesOK = sliced == set.walk.metadata.frameCount
            let sizeOK = pet.view.bounds.size == pet.size
            // SPEC §3: the pet's window must never be able to take focus.
            let neverKey = !pet.window.canBecomeKey && !pet.window.canBecomeMain
            // [M11] The coat is *asserted*, not merely printed. This line used to report
            // `profile.color` while every pet was handed the one set loaded from
            // `config.palette`, and it excluded the coat from its `ok` — so it would have
            // printed the wrong colour and passed. A third of the safety net for work
            // whose result is visual cannot be a line that agrees with whatever it is told.
            let coat = Self.coatEvidence(for: pet, set: set, baseBytes: baseBytes)
            let ok = framesOK && sizeOK && neverKey && coat.ok
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") pet \(pet.index)"
                  + " coat=\(pet.profile.color) (\(coat.detail))"
                  + " drawn=\(Self.f(pet.view.bounds.width))x\(Self.f(pet.view.bounds.height))"
                  + "/\(Self.f(pet.size.width))x\(Self.f(pet.size.height)) pt"
                  + " sliced=\(sliced)/\(set.walk.metadata.frameCount) walk frames"
                  + " canBecomeKey=\(pet.window.canBecomeKey)")
        }
        // [M11] The cast must not start stacked.
        //
        // Two same-size pets both at walk distance 0 produce byte-identical frames, and
        // `MeetingCoordinator.haveMet` is true for identical frames — so an unspaced pair
        // launches on top of each other, reads as one cat, and spends the 60 second
        // cooldown on a meeting with itself on the very first located poll.
        //
        // Checked against a synthetic strip rather than the live one: every pet's window
        // still sits at the origin until the first poll positions it, and the real strip
        // needs an Accessibility grant that a self-test cannot assume. The numbers below
        // are a plain 1000 pt bottom strip — the geometry is what is under test, not the
        // Dock.
        if pets.count > 1 {
            let strip = WalkStrip(edge: .bottom, baseline: 0, start: 0, end: 1000)
            let frames = pets.map { pet -> CGRect in
                var walker = pet.walker
                walker.clamp(to: Geometry.maximumDistance(for: pet.size, on: strip))
                return Geometry.petFrame(size: pet.size, on: strip, distance: walker.distance)
            }
            for i in frames.indices {
                for j in frames.indices where j > i {
                    let apart = !frames[i].intersects(frames[j]) && frames[i] != frames[j]
                    if !apart { failures += 1 }
                    print("  \(apart ? "ok  " : "FAIL") pets \(i) and \(j) start apart on a"
                          + " 1000 pt strip — \(Self.f(frames[i])) vs \(Self.f(frames[j]))")
                }
            }
        }

        if failures > 0 {
            print("\n\(failures) of \(pets.count) pet(s) FAILED")
            exit(1)
        }
        RenderTest.run(spriteSet: reference, scale: config.scale)
    }

    /// [M11] Is this pet's art really in the coat its profile names?
    ///
    /// Proved from the pixels rather than from the plumbing: the shipped sheet is decoded
    /// once, put through *this* pet's palette here, and the result compared byte for byte
    /// with the sheet the pet is actually holding. Two cats handed the same set therefore
    /// cannot both pass — whichever one is wearing the other's coat fails.
    ///
    /// The generated placeholder sheet has no coat colours in it, so there is nothing to
    /// swap and nothing to assert; that case says so in the log instead of quietly
    /// claiming a coat it cannot see. The shipped art always has them, and the self-tests
    /// are run from the bundle.
    private static func coatEvidence(for pet: Pet, set: SpriteSet,
                                     baseBytes: [UInt8]?) -> (ok: Bool, detail: String) {
        let palette = pet.profile.palette
        guard let baseBytes else {
            return (false, "the base sheet could not be decoded to compare against")
        }
        guard let bytes = SpriteRecolor.rgbaBytes(of: set.walk.image) else {
            return (false, "its own sheet could not be decoded")
        }

        var expected = baseBytes
        palette.recolor(rgba: &expected)
        guard bytes == expected else {
            return (false, "its sheet is not the shipped art in the \(palette.id) coat")
        }

        let inBase = countPixels(CatPalette.base.coat, in: baseBytes)
        guard inBase > 0 else {
            return (true, "placeholder art — no coat pixels to swap, so no coat to check")
        }
        let worn = countPixels(palette.coat, in: bytes)
        let leftover = palette.isIdentity ? 0 : countPixels(CatPalette.base.coat, in: bytes)
        return (worn == inBase && leftover == 0,
                "\(worn)/\(inBase) px in \(palette.id), \(leftover) px still base")
    }

    /// Opaque pixels of exactly this colour.
    private static func countPixels(_ rgb: CatPalette.RGB, in rgba: [UInt8]) -> Int {
        var found = 0, i = 0
        while i + 3 < rgba.count {
            if rgba[i + 3] == 255 && rgba[i] == rgb.red
                && rgba[i + 1] == rgb.green && rgba[i + 2] == rgb.blue { found += 1 }
            i += 4
        }
        return found
    }

    /// Drives the menu bar item's pause/resume path and checks the consequences.
    func runMenuTest() -> Never {
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

        // [M11] Every pet, by index. Pausing hides *the app*, so a check that only looks
        // at pet 0 would pass with a second cat still on screen.
        check(!pets.isEmpty, "there is at least one pet to drive", "pets=\(pets.count)")
        let wasVisible = pets.map { $0.window.isVisible }

        setPaused(true)
        check(isPaused, "pause takes effect")
        check(statusSummary == "Paused", "status summary reports Paused", "got \"\(statusSummary)\"")
        check(suspensionReason() == .paused, "suspension reason is 'paused'",
              "got \(String(describing: suspensionReason()))")
        check(animationTimer == nil, "animation timer is suspended, not merely idle")
        for pet in pets {
            check(!pet.window.isVisible, "pet \(pet.index) is hidden while paused")
        }
        check(locatorTimer?.isValid == true, "the 500 ms locator poll keeps running so resume works")

        setPaused(false)
        check(!isPaused, "resume takes effect")
        check(statusSummary != "Paused", "status summary stops reporting Paused")
        if wasVisible.contains(true) {
            // [M11] Indexed by position in `pets`, not by `pet.index`. The two agree today,
            // but the invariant is written down nowhere and Settings can now rebuild the
            // array — and an out-of-range crash inside the safety net is the worst place
            // for one.
            for (i, pet) in pets.enumerated() where wasVisible[i] {
                check(pet.window.isVisible, "pet \(pet.index) comes back after resuming")
            }
            check(animationTimer != nil, "and the animation timer restarts")
        }

        // --- reload ---------------------------------------------------------------
        check(!spriteSummary.isEmpty && spriteSummary != "No sheets loaded",
              "sprite summary lists the loaded sheets", "got \"\(spriteSummary)\"")

        // Prove reload genuinely re-reads config rather than no-opping: corrupt the live
        // value first and check it comes back from disk.
        for pet in pets { pet.walker.speed = 999 }
        let sizesBefore = pets.map { $0.size }
        reload()
        check(spriteSet != nil, "reload leaves a sprite set loaded")
        for (i, pet) in pets.enumerated() {
            check(pet.walker.speed == CGFloat(config.speed),
                  "pet \(pet.index): reload re-reads config.json and reapplies speed",
                  "speed is \(pet.walker.speed), config says \(config.speed)")
            check(pet.size == sizesBefore[i],
                  "pet \(pet.index): reload keeps the pet size when nothing changed",
                  "\(sizesBefore[i]) -> \(pet.size)")
            check(pet.window.contentView === pet.view,
                  "pet \(pet.index): the rebuilt view is installed in its own window")
            check(pet.view.sliceCount(for: .walk) > 0,
                  "pet \(pet.index): the rebuilt view has the sheet sliced into it")
        }
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
    func runInteractionTest() -> Never {
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

        guard let primary = primaryPet else {
            print("  FAIL  at least one pet was built")
            exit(1)
        }

        // [M11] Every pet, addressed by index. Each cat has its own view, its own alpha
        // masks, its own window and its own bubble, so a pass on pet 0 says nothing about
        // pet 1 — which is exactly the failure this loop exists to catch.
        for pet in pets {
            let label = "pet \(pet.index)"
            let view = pet.view
            let petWindow = pet.window
            let interaction = pet.interaction
            print("  --- \(label) ---")

            // --- hit testing ------------------------------------------------------
            // The cat is drawn feet-down and centred, so the middle of the frame is art and
            // the top corners are the empty space above its ears.
            let middle = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
            check(view.isOverSprite(middle), "\(label): the middle of the frame is the cat",
                  "frame is \(Self.f(view.bounds))")

            // Printed unconditionally: the two checks below are about *where* the art is,
            // and when one fails this is the only thing that says why.
            print("  the clickable cat (# art, + tolerance, . click-through):")
            for line in view.silhouetteDescription().split(separator: "\n") {
                print("        \(line)")
            }

            // Nothing is assumed about the art: the shipped cat leaves its corners empty,
            // but the generated placeholder sheet is a solid block, and a check that passes
            // or fails on which sheet loaded would be worse than none.
            if let through = view.clickThroughSample() {
                check(!view.isOverSprite(through),
                      "\(label): the empty space around the cat is not — this is what leaves"
                      + " the Dock its clicks",
                      "at \(Self.f(through.x)),\(Self.f(through.y))")
                check(view.hitTest(view.convert(through, to: view.superview)) == nil,
                      "\(label): and the view declines to handle a click there")
            } else {
                print("  note  this sheet fills its whole frame, so there is no transparent "
                      + "margin to fall through — clicks in the frame all belong to the pet")
            }

            // Outside the window is always somebody else's click, whatever the art is.
            let outside = NSPoint(x: view.bounds.maxX + 10, y: view.bounds.midY)
            check(!view.isOverSprite(outside),
                  "\(label): a point outside the pet's frame is never the cat")

            // --- the cursor -------------------------------------------------------
            // The cursor is the only hint that the cat is clickable at all, and it is the
            // one part of this feature that cannot be checked by looking at a screenshot:
            // the pointer is not in the picture. So the decision is checked directly.
            check(view.cursor(at: middle) == .pointingHand,
                  "\(label): the cursor over the cat is a pointing hand, so it looks clickable")

            if let through = view.clickThroughSample() {
                check(view.cursor(at: through) == .arrow,
                      "\(label): and goes back to an arrow over the space the Dock still owns")
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
                  "\(label): the cursor promises exactly what the hit test delivers, across"
                  + " the frame",
                  "\(disagreements) of 1024 sampled points disagree")

            // A tracking area is what makes any of this work for a window that can never be
            // key (SPEC §3). Without `.activeAlways` the system would only update the cursor
            // for the active app, which DockPet never is.
            if let area = view.cursorTrackingArea {
                check(area.options.contains(.activeAlways),
                      "\(label): the tracking area is active even though the app never is")
                check(area.options.contains(.cursorUpdate),
                      "\(label): and asks for cursor updates")
                check(view.trackingAreas.contains(area),
                      "\(label): and is actually installed on the view")
            } else {
                check(false, "\(label): the pet view has a cursor tracking area")
            }

            // A click-through window that never switches on is a cat you cannot click; one
            // that never switches off is a Dock you cannot use. Both directions are checked.
            check(petWindow.ignoresMouseEvents,
                  "\(label): the window ignores mouse events while the cursor is elsewhere")

            // --- the prompts ------------------------------------------------------
            for prompt in PetPrompt.allCases {
                interaction.dismissBubble()
                interaction.say(prompt)
                settle(0.25)

                guard let reply = interaction.lastReply,
                      let bubble = interaction.bubbleFrame else {
                    check(false, "\(label): \(prompt.rawValue) produces a reply and a bubble")
                    continue
                }

                check(!reply.isEmpty && !reply.contains("{name}"),
                      "\(label): \(prompt.rawValue) answers in words, with the name slot filled",
                      "got \"\(reply)\"")
                check(interaction.isTalking,
                      "\(label): \(prompt.rawValue) leaves the pet talking")

                let petFrame = petWindow.frame
                check(bubble.minY >= petFrame.maxY,
                      "\(label): \(prompt.rawValue): the bubble sits above the cat, not over it",
                      "bubble \(Self.f(bubble)) vs pet \(Self.f(petFrame))")

                if let screen = currentLocation?.screen {
                    let vf = screen.visibleFrame
                    check(bubble.minX >= vf.minX && bubble.maxX <= vf.maxX
                          && bubble.maxY <= vf.maxY,
                          "\(label): \(prompt.rawValue): the bubble is fully on screen",
                          "bubble \(Self.f(bubble)) vs visibleFrame \(Self.f(vf))")
                }

                check(!pet.behavior.state.isMoving,
                      "\(label): \(prompt.rawValue): the pet stops walking while it talks",
                      "state is \(pet.behavior.state.rawValue)")
            }

            // --- the nap is the one prompt that changes what the pet does afterwards ---
            interaction.dismissBubble()
            interaction.say(.nap)
            settle(0.2)
            check(pet.behavior.state == .sleep,
                  "\(label): \"Take a nap\" actually puts the pet to sleep",
                  "state is \(pet.behavior.state.rawValue)")

            // --- the bubble goes away on its own ----------------------------------
            interaction.dismissBubble()
            interaction.say(.hello)
            settle(0.2)
            check(interaction.isTalking, "\(label): the bubble is up")
            let staysUp = BubbleGeometry.readingTime(for: interaction.lastReply ?? "")
            settle(staysUp + 0.6)
            check(!interaction.isTalking,
                  "\(label): and takes itself down again without a second click",
                  "still up after \(Self.f(CGFloat(staysUp)) )s")
            check(interaction.bubbleFrame == nil, "\(label): leaving no window behind")
        }

        // --- the name -------------------------------------------------------------
        //
        // [M11] Built by mutating the **live** config rather than by constructing a fresh
        // `PetConfig`. A hand-built one has an empty `pets`, which `cast(of:)` normalises
        // to a single profile — under a two-cat config that is a changed cast, so
        // `applyConfig` would tear both cats down and rebuild one. Every check below would
        // then still pass, on the closed detached pet captured at the top of this method,
        // testing nothing that is live.
        let originalConfig = config
        var named = config
        named.userName = "Testcat"
        for index in named.pets.indices { named.pets[index].userName = "Testcat" }
        applyConfig(named, persist: false)
        check(pets.count == originalConfig.pets.count,
              "renaming does not rebuild the cast, so these are still the live pets",
              "\(pets.count) pets for \(originalConfig.pets.count) profiles")
        check(pets.contains { $0 === primary },
              "and the pet captured at the start of this test is still one of them")
        check(effectiveUserName == "Testcat", "a configured name is the one the pet uses",
              "got \(String(describing: effectiveUserName))")

        var sawTheName = false
        for _ in 0..<12 {
            primary.interaction.dismissBubble()
            primary.interaction.say(.hello)
            if primary.interaction.lastReply?.contains("Testcat") == true {
                sawTheName = true; break
            }
        }
        check(sawTheName, "and it reaches the bubble",
              "last was \"\(primary.interaction.lastReply ?? "")\"")
        primary.interaction.dismissBubble()

        // --- [M11] each cat answers with its OWN name ------------------------------
        //
        // The nap half of the two-cat dispatch bug is covered per pet above — a delegate
        // resolving to `primaryPet` would fail those. This is the name half, which
        // otherwise rests entirely on code reading. Giving the cats *different* names is
        // the whole point: with one cat, or with two that share a name, answering for pet
        // 0 looks exactly like answering correctly.
        var distinct = config
        for index in distinct.pets.indices {
            distinct.pets[index].userName = "Cat\(index)Name"
        }
        distinct.userName = distinct.pets.first?.userName
        applyConfig(distinct, persist: false)

        for pet in pets {
            let expected = pet.profile.userName ?? effectiveUserName
            let resolved = interactionUserName(for: pet.interaction)
            check(resolved == expected,
                  "pet \(pet.index): the delegate resolves this cat's name, not pet 0's",
                  "got \(resolved ?? "nil"), expected \(expected ?? "nil")")
            check(pet.profile.userName == "Cat\(pet.index)Name",
                  "pet \(pet.index): and it is the name this cat was actually given",
                  "profile says \(pet.profile.userName ?? "nil")")

            var sawItsOwn = false
            for _ in 0..<12 {
                pet.interaction.dismissBubble()
                pet.interaction.say(.hello)
                if pet.interaction.lastReply?.contains("Cat\(pet.index)Name") == true {
                    sawItsOwn = true; break
                }
            }
            check(sawItsOwn, "pet \(pet.index): and its own name reaches its own bubble",
                  "last was \"\(pet.interaction.lastReply ?? "")\"")
            pet.interaction.dismissBubble()
        }

        if pets.count > 1 {
            let first = interactionUserName(for: pets[0].interaction)
            let second = interactionUserName(for: pets[1].interaction)
            check(first != second,
                  "two cats with different names are told apart — this is the check that "
                  + "fails when the delegate answers for the wrong animal",
                  "both got \(first ?? "nil")")
        }

        // --- no configured name at all: the macOS account answers --------------------
        //
        // The rule this guards is that nobody's name is baked into the app. A config with
        // no `userName` — which is what a fresh install has, and what this one ships with
        // — must greet whoever is logged into the Mac, not a name left in a file. Checked
        // against `NSFullUserName()` rather than a literal, because the whole point is
        // that the answer comes from the account rather than from anything written here.
        var anonymous = config
        anonymous.userName = nil
        for index in anonymous.pets.indices { anonymous.pets[index].userName = nil }
        applyConfig(anonymous, persist: false)

        let account = NSFullUserName().split(separator: " ").first.map(String.init)
        check(effectiveUserName == account,
              "with no name configured, the pet greets the macOS account's first name",
              "got \(effectiveUserName ?? "nobody"), account is \(account ?? "nameless")")
        check(pets.allSatisfy { interactionUserName(for: $0.interaction) == account },
              "and every cat does, not just the first",
              "got \(pets.map { interactionUserName(for: $0.interaction) ?? "nobody" })")

        if let account {
            var sawTheAccount = false
            for _ in 0..<12 {
                primary.interaction.dismissBubble()
                primary.interaction.say(.hello)
                if primary.interaction.lastReply?.contains(account) == true {
                    sawTheAccount = true; break
                }
            }
            check(sawTheAccount, "and it is the name that reaches the bubble",
                  "last was \"\(primary.interaction.lastReply ?? "")\"")
            primary.interaction.dismissBubble()
        }

        applyConfig(originalConfig, persist: false)
        check(config == originalConfig, "the test restored your original settings")
        for pet in pets { pet.interaction.dismissBubble() }

        // --- a picture of it, since nobody reading this log can see my screen ------
        if let path = options.shotPath {
            primary.interaction.say(.hello)
            settle(0.35)
            if let bubbleView = primary.interaction.bubbleFrame.flatMap({ _ in
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
            primary.interaction.dismissBubble()
        }

        print("")
        if failures > 0 { print("\(failures) of \(checks) checks FAILED"); exit(1) }
        print("all \(checks) checks passed")
        exit(0)
    }

    /// [M11] `--dedication-test`: drives the once-a-day dedication's positive path.
    ///
    /// This is the feature M11 exists to deliver — one line the owner writes into
    /// config.json, said on the first click of each day — and until this mode existed it
    /// had zero coverage of ever actually being said. `--settings-test` covers its
    /// *persistence* (does moving a slider erase it); this covers the other direction: is
    /// it ever spoken, does the second click of the day get an ordinary reply instead, does
    /// `StateStore.lastGreetedDay` round-trip through state.json, does a new day make it
    /// available again, and does the clicked prompt's own effect — the thing an earlier bug
    /// lost — still happen on the dedication's own click.
    ///
    /// Two guardrails keep this from ever touching anything real:
    ///  - `StateStore.directoryOverride` is pointed at a fresh temporary directory before a
    ///    single dedication is said, and set back to `nil` — checked, not merely hoped —
    ///    before this function's final checks. Not a `defer`: every check here can only
    ///    fail by incrementing `failures` and continuing, never by leaving the function
    ///    early, and this function (like every other self-test mode) ends by calling
    ///    `exit`, which tears the process down without running Swift's deferred cleanup.
    ///    The real ~/Library/Application Support/DockPet/state.json is never opened.
    ///  - `config` is mutated in memory only, through `applyConfig(_, persist: false)` (as
    ///    the other self-tests already do), and restored the same way before the final
    ///    checks. config.json on disk is never written.
    ///
    /// The `isSelfTest` guard in `PetInteraction.say` stays in force for
    /// `--render-test`, `--menu-test`, `--interaction-test` and `--settings-test`: each of
    /// those builds its pets with `isSelfTest == true` and `isDedicationTest == false`,
    /// which `say` still refuses to say a dedication under. Only the one pet driven here
    /// gets `isDedicationTest = true`, and only for the lifetime of this function.
    func runDedicationTest() -> Never {
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
        /// Independent of `StateStore`: decodes the scratch state.json straight off disk,
        /// the same way `--settings-test` reads config.json back rather than trusting the
        /// in-memory value that wrote it.
        func rawStamp(in directory: URL) -> String? {
            let data = try? Data(contentsOf: directory.appendingPathComponent("state.json"))
            let state = data.flatMap { try? JSONDecoder().decode(DedicationTestRawState.self, from: $0) }
            return state?.lastGreetedDay
        }

        print("DedicationTest")

        guard let primary = primaryPet else {
            print("  FAIL  at least one pet was built")
            exit(1)
        }

        // Snapshotted before anything else runs, so the very last checks below are a
        // byte-for-byte comparison against what was actually on disk beforehand — not an
        // assumption that memory-only config edits and a redirected StateStore add up to
        // "untouched".
        let realStateURL = ConfigStore.directory.appendingPathComponent("state.json")
        let realConfigBefore = try? Data(contentsOf: ConfigStore.url)
        let realStateBefore = try? Data(contentsOf: realStateURL)

        // --- the two guardrails: a scratch state.json, and a memory-only config --------
        //
        // Restored explicitly near the end, and checked, rather than via `defer`: this
        // function always ends by calling `exit`, like every other self-test mode, and
        // `exit` tears the process down without running Swift's deferred cleanup — a
        // `defer` here would read as a restore that in fact never fires.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("DockPetDedicationTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        StateStore.directoryOverride = scratch

        let originalConfig = config
        primary.interaction.isDedicationTest = true

        let marker = "[[DEDICATION]]"
        var dedicated = config
        dedicated.dedication = "For you, {name}, today and every day. \(marker)"
        // Kept out of the birthday path deliberately, so this test cannot become
        // calendar-dependent: on the one day of the year `Occasion.isBirthday` is true,
        // `.hello` would be swapped for `.birthday` *after* a dedication is spent, which is
        // a real behaviour but not the one this mode exists to check.
        dedicated.birthday = nil
        dedicated.userName = "Dedicatee"
        for index in dedicated.pets.indices { dedicated.pets[index].userName = "Dedicatee" }
        applyConfig(dedicated, persist: false)

        let today = Date()
        let todayStamp = Occasion.dayStamp(today)

        // --- a fresh store has nothing to gate on --------------------------------------
        check(StateStore.lastGreetedDay == nil,
              "the scratch state.json starts with no stamp",
              "got \(StateStore.lastGreetedDay ?? "nil")")

        // --- first click of the day: the dedication, AND the clicked prompt's own effect
        //
        // Driven with .nap rather than .hello so this proves the exact thing the earlier
        // bug got wrong: the dedication swapping in the words must not swallow "Take a
        // nap"'s own effect on the pet.
        primary.interaction.dismissBubble()
        primary.interaction.say(.nap)
        settle(0.25)
        let firstReply = primary.interaction.lastReply
        check(firstReply?.contains(marker) == true,
              "the first reply of the day is the dedication",
              "got \"\(firstReply ?? "nil")\"")
        check(firstReply?.contains("{name}") == false,
              "and {name} was rendered, not left in the bubble",
              "got \"\(firstReply ?? "nil")\"")
        check(firstReply?.contains("Dedicatee") == true,
              "rendered specifically with this cat's name",
              "got \"\(firstReply ?? "nil")\"")
        check(primary.behavior.state == .sleep,
              "\"Take a nap\", clicked on the dedication's own turn, still puts the pet to "
              + "sleep — this is the bug where the dedication used to swallow the prompt",
              "state is \(primary.behavior.state.rawValue)")

        // --- state.json now holds today's stamp, and Occasion.dayStamp agrees ----------
        check(StateStore.lastGreetedDay == todayStamp,
              "state.json holds today's stamp",
              "got \(StateStore.lastGreetedDay ?? "nil"), expected \(todayStamp)")
        let onDisk = rawStamp(in: scratch)
        check(onDisk == todayStamp,
              "and the stamp is genuinely on disk, decoded independently of StateStore",
              "file says \(onDisk ?? "nil"), expected \(todayStamp)")

        // --- second click, same day: an ordinary reply, not the dedication -------------
        primary.interaction.dismissBubble()
        primary.interaction.say(.hello)
        settle(0.25)
        let secondReply = primary.interaction.lastReply
        check(secondReply?.contains(marker) == false,
              "the second click of the same day is not the dedication",
              "got \"\(secondReply ?? "nil")\"")
        check(StateStore.lastGreetedDay == todayStamp,
              "and the stamp is unchanged by an ordinary reply",
              "got \(StateStore.lastGreetedDay ?? "nil")")

        // --- a new day makes it available again -----------------------------------------
        StateStore.lastGreetedDay = "2000-01-01"
        primary.interaction.dismissBubble()
        primary.interaction.say(.hello)
        settle(0.25)
        let newDayReply = primary.interaction.lastReply
        check(newDayReply?.contains(marker) == true,
              "a different stamp already in the store makes the dedication available again",
              "got \"\(newDayReply ?? "nil")\"")
        check(StateStore.lastGreetedDay == todayStamp,
              "and re-stamps to today, not to whatever the old stamp was",
              "got \(StateStore.lastGreetedDay ?? "nil")")

        // --- with no dedication configured, an ordinary reply, and nothing is stamped --
        StateStore.lastGreetedDay = nil
        var undedicated = dedicated
        undedicated.dedication = nil
        applyConfig(undedicated, persist: false)
        primary.interaction.dismissBubble()
        primary.interaction.say(.hello)
        settle(0.25)
        let noDedicationReply = primary.interaction.lastReply
        check(noDedicationReply?.contains(marker) == false,
              "with dedication nil, the ordinary reply comes back",
              "got \"\(noDedicationReply ?? "nil")\"")
        check(StateStore.lastGreetedDay == nil,
              "and nothing is stamped, since nothing was said on the day's behalf",
              "got \(StateStore.lastGreetedDay ?? "nil")")

        primary.interaction.dismissBubble()

        // --- restore both guardrails before checking anything about the real files -----
        applyConfig(originalConfig, persist: false)
        check(config == originalConfig, "the test restored your original settings")
        primary.interaction.isDedicationTest = false
        check(!primary.interaction.isDedicationTest,
              "and this pet is no longer exempt from the dedication guard")
        StateStore.directoryOverride = nil
        check(StateStore.directoryOverride == nil,
              "and state.json points back at the real directory")

        // --- neither guardrail leaked into the real files -------------------------------
        check((try? Data(contentsOf: ConfigStore.url)) == realConfigBefore,
              "the real config.json is byte-for-byte unchanged",
              "\(ConfigStore.url.path)")
        check((try? Data(contentsOf: realStateURL)) == realStateBefore,
              "the real state.json is byte-for-byte unchanged",
              "\(realStateURL.path)")

        print("")
        if failures > 0 { print("\(failures) of \(checks) checks FAILED"); exit(1) }
        print("all \(checks) checks passed")
        exit(0)
    }

    /// [M12] Sends the two cats to each other and follows the kiss to its end.
    ///
    /// The phases, the drift and the words are covered by the test executable; what is left
    /// is the wiring, which needs two real windows on a real Dock. SPEC §9: every claim
    /// below is one the log can carry, because the sequence takes six seconds of screen and
    /// leaves nothing behind afterwards.
    ///
    /// Like `--dedication-test`, this drives the real app with a temporary config and puts
    /// the original back before it exits — running the test must not cost you a cat.
    func runKissTest() -> Never {
        var failures = 0
        var checks = 0
        func check(_ passed: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
            checks += 1
            if passed { print("  ok    \(what)") }
            else { failures += 1; print("  FAIL  \(what)\(detail().isEmpty ? "" : " — \(detail())")") }
        }
        /// Run the real run loop, so the real animation timer drives the real kiss.
        func settle(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        /// Wait for a phase, up to a limit. Returns whether it arrived.
        func waitFor(_ phase: KissRoutine.Phase?, within limit: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(limit)
            while Date() < deadline {
                if kissPhase == phase { return true }
                settle(0.1)
            }
            return kissPhase == phase
        }

        print("KissTest")

        let originalConfig = config

        // Two cats, kissing on, whatever the real config says. Not persisted: this is a
        // test run, and it is put back below.
        var testConfig = originalConfig
        testConfig.kisses = true
        if testConfig.pets.count < 2 {
            let first = testConfig.pets.first ?? PetProfile(name: nil, color: testConfig.color,
                                                            userName: testConfig.userName)
            let other = CatPalette.all.first { $0.id != first.color } ?? .default
            testConfig.pets = [first, PetProfile(name: nil, color: other.id, userName: nil)]
        }
        applyConfig(testConfig, persist: false)
        settle(0.6)   // let the poll place the rebuilt cast

        check(pets.count == 2, "the test has two cats to work with", "got \(pets.count)")
        guard pets.count == 2 else {
            print("\n\(failures + 1) of \(checks + 1) checks FAILED")
            applyConfig(originalConfig, persist: false)
            exit(1)
        }

        guard currentLocation != nil else {
            // Not a failure of the kiss: with no Dock located there is nowhere to walk, and
            // saying so beats reporting six phantom failures.
            print("  SKIP  the Dock is not located (grant Accessibility, or unhide the Dock)"
                  + " — there is no strip to kiss on")
            applyConfig(originalConfig, persist: false)
            exit(1)
        }

        check(interactionCanKiss, "with two cats and kissing on, the menu item is offered")

        // --- the approach ---------------------------------------------------------------
        let before = pets.map(\.walker.distance)
        interactionRequestKiss()
        check(kissPhase == .approach, "asking for a kiss sets both cats walking",
              "phase \(kissPhase.map { $0.rawValue } ?? "none")")
        check(!interactionCanKiss, "and a second ask is refused while that one is under way")

        settle(0.8)
        let closing = zip(before, pets.map(\.walker.distance))
            .map { abs($0 - $1) }
        check(closing.contains { $0 > 0 }, "the cats are moving toward each other",
              "moved \(closing.map { Self.f($0) })")

        // --- the line -------------------------------------------------------------------
        check(waitFor(.announce, within: KissRoutine.approachCeiling + 1),
              "they reach each other and one of them speaks",
              "phase \(kissPhase.map { $0.rawValue } ?? "none")")
        let talker = pets.first { $0.interaction.isTalking }
        check(talker != nil, "a bubble is up")
        check(talker?.interaction.lastReply == Phrasebook.kissLine,
              "and it says \"\(Phrasebook.kissLine)\"",
              "got \(talker?.interaction.lastReply ?? "nothing")")
        check(pets.allSatisfy { $0.behavior.state == .sit }, "both cats have sat down",
              "got \(pets.map { $0.behavior.state.rawValue })")
        check(MeetingCoordinator.haveMet(pets[0].window.frame, pets[1].window.frame),
              "and they are standing against each other")

        // --- the hearts -----------------------------------------------------------------
        check(waitFor(.kiss, within: KissRoutine.announceDuration + 1), "then they kiss",
              "phase \(kissPhase.map { $0.rawValue } ?? "none")")
        check(kissHeartsAreUp, "the hearts are on screen")
        check(pets.allSatisfy { !$0.interaction.isTalking },
              "and the line has come down, so nothing overlaps the hearts")

        // --- what the hearts were about ---------------------------------------------------
        check(waitFor(.declare, within: KissRoutine.kissDuration + 1),
              "once the hearts have gone, one of them says what it meant",
              "phase \(kissPhase.map { $0.rawValue } ?? "none")")
        check(!kissHeartsAreUp, "the hearts are down before the bubble goes up")
        check(pets.first { $0.interaction.isTalking }?.interaction.lastReply
              == Phrasebook.loveLine.opener,
              "it says \"\(Phrasebook.loveLine.opener)\"",
              "got \(pets.first { $0.interaction.isTalking }?.interaction.lastReply ?? "nothing")")

        // --- the answer -----------------------------------------------------------------
        check(waitFor(.reply, within: KissRoutine.declareDuration + 1),
              "the other cat answers", "phase \(kissPhase.map { $0.rawValue } ?? "none")")
        let answerer = pets.first { $0.interaction.isTalking }
        check(answerer != nil, "a bubble is up for the answer")
        check(answerer !== talker, "and it belongs to the other cat, not the one that spoke")
        check(answerer?.interaction.lastReply == Phrasebook.loveLine.reply,
              "it says \"\(Phrasebook.loveLine.reply)\"",
              "got \(answerer?.interaction.lastReply ?? "nothing")")
        check(pets.filter { $0.interaction.isTalking }.count == 1,
              "and only one bubble is up — two cats this close have room for one")

        // --- parting --------------------------------------------------------------------
        check(waitFor(.part, within: KissRoutine.replyDuration + 1), "the kiss ends",
              "phase \(kissPhase.map { $0.rawValue } ?? "none")")
        check(pets.allSatisfy { !$0.interaction.isTalking },
              "the last bubble comes down with it")
        check(!kissHeartsAreUp, "and there are no hearts left on screen")
        check(pets.allSatisfy { $0.behavior.state == .walk }, "and both cats walk away",
              "got \(pets.map { $0.behavior.state.rawValue })")

        check(waitFor(nil, within: KissRoutine.partDuration + 1),
              "the routine finishes and hands the pair back to its own behaviour",
              "phase \(kissPhase.map { $0.rawValue } ?? "none")")

        settle(0.5)
        check(!MeetingCoordinator.haveMet(pets[0].window.frame, pets[1].window.frame),
              "the two are apart again, so the next tick is not read as a fresh meeting")

        // --- the toggle -----------------------------------------------------------------
        var noKissing = testConfig
        noKissing.kisses = false
        applyConfig(noKissing, persist: false)
        check(!interactionCanKiss, "with kissing switched off, the menu item is gone")
        interactionRequestKiss()
        check(kissPhase == nil, "and asking anyway does nothing",
              "phase \(kissPhase.map { $0.rawValue } ?? "none")")

        // --- put the real settings back --------------------------------------------------
        applyConfig(originalConfig, persist: false)
        check(config == originalConfig, "the test restored your original settings")

        print("")
        if failures > 0 { print("\(failures) of \(checks) checks FAILED"); exit(1) }
        print("all \(checks) checks passed")
        exit(0)
    }

    /// [M13] Run the birthday scene now and check every phase of it.
    ///
    /// SPEC §9, in its sharpest form. The scene is ten seconds of screen on one morning a
    /// year, so the alternative to this is finding out whether it works on the day it was
    /// meant to be a surprise, with no time left to fix it. `--scene-test` lifts the date
    /// and the once-a-day gate, and writes neither stamp, so rehearsing it in August cannot
    /// silence the real one.
    func runSceneTest() -> Never {
        var failures = 0
        var checks = 0
        func check(_ passed: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
            checks += 1
            if passed { print("  ok    \(what)") }
            else { failures += 1; print("  FAIL  \(what)\(detail().isEmpty ? "" : ": \(detail())")") }
        }
        func settle(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func waitFor(_ phase: BirthdayScene.Phase?, within limit: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(limit)
            while Date() < deadline {
                if scenePhase == phase { return true }
                settle(0.05)
            }
            return scenePhase == phase
        }

        print("SceneTest")

        let originalConfig = config
        let originalSceneDay = StateStore.lastSceneDay
        let originalGreetedDay = StateStore.lastGreetedDay

        var testConfig = originalConfig
        if testConfig.pets.count < 2 {
            let first = testConfig.pets.first ?? PetProfile(name: nil, color: testConfig.color,
                                                            userName: testConfig.userName)
            let other = CatPalette.all.first { $0.id != first.color } ?? .default
            testConfig.pets = [first, PetProfile(name: nil, color: other.id, userName: nil)]
        }
        applyConfig(testConfig, persist: false)
        settle(0.6)

        check(pets.count == 2, "the scene has two cats to work with", "got \(pets.count)")
        guard pets.count == 2 else {
            print("\n\(failures + 1) of \(checks + 1) checks FAILED")
            applyConfig(originalConfig, persist: false)
            exit(1)
        }
        guard currentLocation != nil else {
            print("  SKIP  the Dock is not located (grant Accessibility, or unhide the Dock):"
                  + " there is no strip to hold a scene on")
            applyConfig(originalConfig, persist: false)
            exit(1)
        }

        // --- it starts on its own ---------------------------------------------------
        let before = pets.map(\.walker.distance)
        considerBirthdayScene()
        check(scenePhase == .approach, "the scene starts without anything being clicked",
              "phase \(scenePhase.map { $0.rawValue } ?? "none")")
        guard let running = scene else {
            print("\n\(failures + 1) of \(checks + 1) checks FAILED")
            applyConfig(originalConfig, persist: false)
            exit(1)
        }
        check(!interactionCanKiss, "and a kiss cannot be asked for on top of it")

        settle(0.8)
        let closing = zip(before, pets.map(\.walker.distance)).map { abs($0 - $1) }
        check(closing.contains { $0 > 0 }, "both cats set off toward each other",
              "moved \(closing.map { Self.f($0) })")

        // --- they gather -------------------------------------------------------------
        check(waitFor(.gather, within: BirthdayScene.approachCeiling + 1),
              "they reach each other and settle",
              "phase \(scenePhase.map { $0.rawValue } ?? "none")")
        check(pets.allSatisfy { $0.behavior.state == .sit }, "both cats sit down",
              "got \(pets.map { $0.behavior.state.rawValue })")
        check(MeetingCoordinator.haveMet(pets[0].window.frame, pets[1].window.frame),
              "and they are standing against each other")
        check(pets.allSatisfy { !$0.interaction.isTalking },
              "nobody speaks before they have arrived")

        // --- the announcement --------------------------------------------------------
        check(waitFor(.announce, within: BirthdayScene.gatherDuration + 1),
              "then one of them gives the birthday line",
              "phase \(scenePhase.map { $0.rawValue } ?? "none")")
        check(running.left.interaction.isTalking, "the left cat is the one that says it")
        check(running.left.interaction.lastReply == running.announcement,
              "and it says what the scene said it would",
              "got \(running.left.interaction.lastReply ?? "nothing")")

        // --- the celebration ---------------------------------------------------------
        check(waitFor(.celebrate, within: BirthdayScene.announceDuration + 1),
              "then the confetti falls",
              "phase \(scenePhase.map { $0.rawValue } ?? "none")")
        check(sceneConfettiIsUp, "the confetti is on screen")
        check(sceneHeartsAreUp, "and the hearts are up with it rather than after it")
        check(pets.allSatisfy { !$0.interaction.isTalking },
              "and the line has come down, so nothing overlaps them")

        // --- the wish ----------------------------------------------------------------
        check(waitFor(.wish, within: BirthdayScene.celebrateDuration + 1),
              "then the other one answers",
              "phase \(scenePhase.map { $0.rawValue } ?? "none")")
        check(!sceneConfettiIsUp, "the confetti is down before the bubble goes up")
        check(!sceneHeartsAreUp, "and so are the hearts")
        check(running.right.interaction.isTalking, "the right cat is the one that answers")
        check(running.right.interaction.lastReply == running.wish,
              "and it says the wish the scene chose",
              "got \(running.right.interaction.lastReply ?? "nothing")")

        // --- the parting -------------------------------------------------------------
        check(waitFor(.part, within: BirthdayScene.wishDuration + 1), "then they part",
              "phase \(scenePhase.map { $0.rawValue } ?? "none")")
        check(pets.allSatisfy { !$0.interaction.isTalking },
              "the last bubble comes down with it")
        check(pets.allSatisfy { $0.behavior.state == .walk }, "and both cats walk away",
              "got \(pets.map { $0.behavior.state.rawValue })")

        check(waitFor(nil, within: BirthdayScene.partDuration + 1),
              "the scene finishes and hands the pair back to its own behaviour",
              "phase \(scenePhase.map { $0.rawValue } ?? "none")")
        check(!sceneConfettiIsUp && !sceneHeartsAreUp,
              "with nothing of it left on screen")

        settle(0.5)
        check(!MeetingCoordinator.haveMet(pets[0].window.frame, pets[1].window.frame),
              "the two are apart again, so the next tick is not read as a fresh meeting")

        // --- it does not spend the real thing ----------------------------------------
        check(StateStore.lastSceneDay == originalSceneDay,
              "the rehearsal did not stamp the real once-a-day gate, so her birthday still"
                + " gets its scene",
              "was \(originalSceneDay ?? "nil"), now \(StateStore.lastSceneDay ?? "nil")")
        check(StateStore.lastGreetedDay == originalGreetedDay,
              "and did not spend the dedication either",
              "was \(originalGreetedDay ?? "nil"), now \(StateStore.lastGreetedDay ?? "nil")")

        applyConfig(originalConfig, persist: false)
        check(config == originalConfig, "the test restored your original settings")

        print("")
        if failures > 0 { print("\(failures) of \(checks) checks FAILED"); exit(1) }
        print("all \(checks) checks passed")
        exit(0)
    }
}

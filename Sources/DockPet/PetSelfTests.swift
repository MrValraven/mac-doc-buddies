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

extension AppDelegate {

    /// `--render-test`: the per-pet half first, then `RenderTest`'s pixel checks.
    ///
    /// [M11] The pixel checks are about the sheets, which every pet shares, so they say
    /// nothing about whether each pet actually got a view of the right size with the sheet
    /// sliced into it. That is what this half is for, and it is indexed: a test that can
    /// only see pet 0 passes while the second cat is broken. Any failure here exits before
    /// `RenderTest.run`, which owns the exit code for everything after it.
    func runRenderTest(set: SpriteSet) -> Never {
        print("\npets")
        var failures = 0
        for pet in pets {
            let sliced = pet.view.sliceCount(for: .walk)
            let framesOK = sliced == set.walk.metadata.frameCount
            let sizeOK = pet.view.bounds.size == pet.size
            // SPEC §3: the pet's window must never be able to take focus.
            let neverKey = !pet.window.canBecomeKey && !pet.window.canBecomeMain
            let ok = framesOK && sizeOK && neverKey
            if !ok { failures += 1 }
            print("  \(ok ? "ok  " : "FAIL") pet \(pet.index)"
                  + " coat=\(pet.profile.color)"
                  + " drawn=\(Self.f(pet.view.bounds.width))x\(Self.f(pet.view.bounds.height))"
                  + "/\(Self.f(pet.size.width))x\(Self.f(pet.size.height)) pt"
                  + " sliced=\(sliced)/\(set.walk.metadata.frameCount) walk frames"
                  + " canBecomeKey=\(pet.window.canBecomeKey)")
        }
        if failures > 0 {
            print("\n\(failures) of \(pets.count) pet(s) FAILED")
            exit(1)
        }
        RenderTest.run(spriteSet: set, scale: config.scale)
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
            for pet in pets where wasVisible[pet.index] {
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
        for pet in pets {
            check(pet.walker.speed == CGFloat(config.speed),
                  "pet \(pet.index): reload re-reads config.json and reapplies speed",
                  "speed is \(pet.walker.speed), config says \(config.speed)")
            check(pet.size == sizesBefore[pet.index],
                  "pet \(pet.index): reload keeps the pet size when nothing changed",
                  "\(sizesBefore[pet.index]) -> \(pet.size)")
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
        // One config key for the whole app, so this is applied once rather than per pet.
        let originalConfig = config
        applyConfig(PetConfig(speed: config.speed, scale: config.scale, screen: config.screen,
                              menuBarIcon: config.menuBarIcon, color: config.color,
                              userName: "Testcat"), persist: false)
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

        applyConfig(originalConfig, persist: false)
        check(config == originalConfig, "the test restored your original settings")
        primary.interaction.dismissBubble()

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
}

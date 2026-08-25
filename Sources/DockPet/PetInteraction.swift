//
//  PetInteraction.swift — clicking the pet: the menu, and the reply.
//
//  [M10] Kept out of AppDelegate, which is already the largest file in the project and
//  owns four timers, the locator and the config. This owns exactly three things: whether
//  the pet's window is currently taking mouse events, the menu that a click opens, and the
//  bubble that the chosen prompt answers in.
//
//  The two halves that can be checked without a screen live in DockPetCore — Phrasebook
//  picks the words, BubbleGeometry places the bubble — so what is left here is wiring.
//

import AppKit
import DockPetCore

/// What the interaction needs from the app, and what it asks the app to do.
protocol PetInteractionDelegate: AnyObject {
    /// What *this* pet should call the user, or `nil` if it should greet them without a
    /// name.
    ///
    /// [M11] Resolved per interaction rather than read once for the app. Each cat has its
    /// own `userName`, and a property could only ever answer for one of them — the second
    /// cat would greet you with the first cat's name, which looks exactly like a working
    /// app until you notice it is answering for the wrong animal.
    func interactionUserName(for interaction: PetInteraction) -> String?
    /// Sprite scale, so the bubble's border matches the art's pixel size.
    var interactionScale: Int { get }
    /// The screen the pet is on, for keeping the bubble on it.
    var interactionScreen: NSScreen? { get }
    /// [M11] The birthday, and the line said once a day, both read from the config.
    var interactionBirthday: String? { get }
    var interactionDedication: String? { get }
    /// Put *this* pet into a state — how "Take a nap" takes effect, and how the pet stops
    /// walking while it talks.
    ///
    /// [M11] Also resolved per interaction: a nap has to land on the cat that was clicked,
    /// not on whichever one happens to be first in the array.
    func interactionForcePetState(_ state: PetState, for interaction: PetInteraction)
    /// Open the Settings window, so the click menu is a complete way to reach the app for
    /// anyone who turned the menu bar icon off.
    func interactionShowSettings()
}

final class PetInteraction: NSObject, PetViewClickDelegate, NSMenuDelegate {

    /// Points between the pet's head and the tail of the bubble.
    private static let bubbleGap: CGFloat = 4

    weak var delegate: PetInteractionDelegate?

    private weak var window: PetWindow?
    private weak var view: PetView?

    private var bubbleWindow: BubbleWindow?
    private var bubbleView: BubbleView?
    private var bubbleTimer: Timer?

    /// Seeded from the system generator once, so two launches do not open with the same
    /// hello, while a single run stays reproducible from that seed (SPEC §9).
    private var phrasebook = Phrasebook(seed: UInt64.random(in: UInt64.min...UInt64.max))

    private var mouseMonitor: Any?
    private var menuIsOpen = false

    /// [M11] True under `--interaction-test` and the other self-tests. A test run must not
    /// consume the once-a-day dedication or swap in a birthday greeting — it would spend
    /// the one thing this feature exists to deliver, on a day nobody would connect to the
    /// cause.
    var isSelfTest = false

    /// [M11] True on exactly the one pet `--dedication-test` drives, and only for the
    /// duration of that test. `isSelfTest` above stays `true` for that mode too — it still
    /// wants the Accessibility prompt and the login-item write skipped — so this is the
    /// narrow, separate switch that lifts the dedication guard in `say(_:)` for that one
    /// pet without touching what `isSelfTest` means for `--render-test`, `--menu-test`,
    /// `--interaction-test` or `--settings-test`: those four keep `isDedicationTest`
    /// `false`, so `isSelfTest` alone still blocks them from ever consuming a dedication.
    var isDedicationTest = false

    /// True while the pet has something to say. The app holds the behaviour clock still
    /// for the duration, so the cat does not wander out from under its own sentence.
    private(set) var isTalking = false

    /// The last thing the pet said, and what was asked. For the status menu and the log —
    /// SPEC §9 wants the app's state readable without watching the screen.
    private(set) var lastPrompt: PetPrompt?
    private(set) var lastReply: String?

    // MARK: - Wiring

    /// Attach to the pet's window and view.
    ///
    /// Called again whenever AppDelegate rebuilds the view — a scale or coat change makes
    /// a new PetView, and an interaction still pointing at the old one would leave the cat
    /// unclickable with no visible sign of why.
    func attach(to view: PetView, in window: PetWindow) {
        self.view = view
        self.window = window
        view.clickDelegate = self
        startMouseTracking()
        updateClickThrough()
    }

    /// Keep `ignoresMouseEvents` in step with whether the cursor is over the cat.
    ///
    /// There is no per-pixel version of click-through in AppKit: a window either takes
    /// mouse events in its whole rectangle or none of it. So the rectangle is switched on
    /// only while the cursor is actually over the art, and the Dock keeps every other
    /// click — including the ones that land in the transparent corners of the pet's frame.
    ///
    /// Two things move: the cursor and the cat. The monitor below covers the first; the
    /// animation tick calls this for the second.
    func updateClickThrough() {
        guard let window = window, let view = view else { return }

        // A menu closes on its own terms; taking events away mid-track would strand it.
        guard !menuIsOpen else { return }

        let mouse = NSEvent.mouseLocation
        guard window.isVisible, window.frame.contains(mouse) else {
            if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
            return
        }

        let local = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
        let shouldIgnore = !view.isOverSprite(local)
        if window.ignoresMouseEvents != shouldIgnore {
            window.ignoresMouseEvents = shouldIgnore
            // [M10] The cat moves as well as the cursor, so it can walk out from under a
            // stationary pointer. `mouseExited` covers the pointer leaving the frame; this
            // covers the frame leaving the pointer, and the transparent margin, where the
            // window stops taking events and no tracking-area event is coming.
            if shouldIgnore { NSCursor.arrow.set() }
        }
    }

    private func startMouseTracking() {
        guard mouseMonitor == nil else { return }
        // Global, because DockPet is an accessory app that is never frontmost — these are
        // the events that happen in *other* apps, which is all of them. Mouse monitors need
        // no permission of their own; only keyboard ones do.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.updateClickThrough()
        }
    }

    func stopMouseTracking() {
        if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        window?.ignoresMouseEvents = true
    }

    // MARK: - The click

    func petView(_ view: PetView, wasClickedAt point: NSPoint) {
        // A second click while the pet is mid-sentence dismisses it rather than stacking a
        // menu on top of a bubble.
        if isTalking { dismissBubble() }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // [M11] `.birthday` is not a prompt anyone picks — it is swapped in for `.hello`
        // on the day. Listing it would leave a dead menu item for the other 364.
        for prompt in PetPrompt.allCases where prompt != .birthday {
            if prompt == .nap { menu.addItem(.separator()) }
            let item = NSMenuItem(title: prompt.menuTitle,
                                  action: #selector(promptChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = prompt.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(settingsChosen),
                                  keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        menuIsOpen = true
        menu.popUp(positioning: nil, at: point, in: view)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Deferred: the click that chose an item is still being delivered, and turning the
        // window click-through here would pull the rug out from under it.
        DispatchQueue.main.async { [weak self] in
            self?.menuIsOpen = false
            self?.updateClickThrough()
        }
    }

    @objc private func settingsChosen() {
        delegate?.interactionShowSettings()
    }

    @objc private func promptChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let prompt = PetPrompt(rawValue: raw) else { return }
        say(prompt)
    }

    /// Answer a prompt: pick the words, stop the pet, and put the bubble up.
    ///
    /// [M11] The dedication changes only the *words*. Everything else about a reply — the
    /// pet stopping, `lastReply`, the `[pet]` log line, and the prompt's own effect — is
    /// the same on the first click of the day as on the second. An earlier draft returned
    /// early here, which quietly dropped whatever the user had actually asked for: the
    /// first *Take a nap* of the day showed the dedication and left the cat wide awake.
    func say(_ prompt: PetPrompt) {
        var prompt = prompt
        let today = Date()
        let stamp = Occasion.dayStamp(today)

        // [M11] Is this the first reply of the day, with a dedication to spend it on?
        //
        // Decided **before** the birthday swap below, and that order is the whole fix.
        // Swapping first and then pre-empting the swapped prompt is how the birthday
        // greeting got eaten on the one morning of the year both features fire: the swap
        // had already happened, the dedication discarded its result, and the user had to
        // click a second time to ever see a birthday line. Checked first, the swap has
        // simply not happened yet — the dedication is said now and the birthday greeting
        // is still waiting, unspent, on the next click.
        let dedication: String? = {
            // [M11] `isDedicationTest` is the one deliberate, narrow exception: it is only
            // ever true on the single pet `--dedication-test` drives, so this still reads
            // as "never under self-test" for the other four modes.
            guard (!isSelfTest || isDedicationTest), let line = delegate?.interactionDedication,
                  StateStore.lastGreetedDay != stamp else { return nil }
            return line
        }()

        // [M11] On the day, "Say hello" greets you for the birthday instead. Swapped here
        // rather than in the menu so the menu item keeps its ordinary title all year.
        if dedication == nil, !isSelfTest, prompt == .hello,
           Occasion.isBirthday(today, birthday: delegate?.interactionBirthday) {
            prompt = .birthday
        }

        let name = delegate?.interactionUserName(for: self)
        let reply = dedication.map { Phrasebook.render($0, name: name) }
            ?? phrasebook.reply(to: prompt, name: name)

        lastPrompt = prompt
        lastReply = reply
        // SPEC §9: the one sentence this feature exists to deliver has to be readable in
        // the log, because nobody debugging it can see the screen. The prompt is named
        // alongside it so the line still says what was clicked.
        print("[pet] \(dedication == nil ? prompt.rawValue : "dedication (\(prompt.rawValue))")"
              + " → \"\(reply)\"")

        // A nap is the one prompt that changes what the pet is doing afterwards. Everything
        // else parks it in `idle` for the length of the bubble: `idle` is stationary, so
        // the existing "only walking moves the pet" rule in animationTick does the stopping
        // without a second switch for it.
        //
        // [M11] Applied on the dedication's click too. Every prompt must still do what it
        // says on the first click of the day — and this is also what stops the cat walking
        // out from under its own dedication.
        delegate?.interactionForcePetState(prompt.forcedState ?? .idle, for: self)

        showBubble(reply)

        // [M11] Stamped only once the bubble is genuinely up — `showBubble` returns in
        // silence when the delegate has gone, and stamping first would spend the day on a
        // dedication nobody was shown. `isTalking` is set inside `showBubble`, past that
        // guard, so it is the honest signal for "it was presented".
        if dedication != nil, isTalking { StateStore.lastGreetedDay = stamp }
    }

    // MARK: - The bubble

    /// Put a line in the pet's speech bubble.
    ///
    /// [M11] Not `private`: the meeting between two cats presents a bubble from
    /// `AppDelegate`, and two methods that both put text in a bubble would drift apart.
    func showBubble(_ text: String) {
        dismissBubble()
        guard let delegate = delegate else { return }

        // [M11] Recorded here rather than only in `reply(to:)`, so that every line the pet
        // says is one `--verbose` can name. The meeting between two cats calls straight
        // into this method, and without this the snapshot printed `talking=true` with no
        // `saying=` beside it — SPEC §9, on a feature nobody can watch happen.
        //
        // Set past the delegate guard, alongside `isTalking`: both mean "a bubble is
        // actually on screen", and the snapshot only prints the reply while it is.
        lastReply = text

        let scale = delegate.interactionScale
        let view = BubbleView(text: text, scale: scale)
        let window = BubbleWindow(content: view)

        bubbleView = view
        bubbleWindow = window
        isTalking = true

        positionBubble()

        // Faded in rather than snapped: at 12 fps the pet's own motion is deliberately
        // steppy, but a rectangle appearing instantly next to it reads as a glitch.
        window.alphaValue = 0
        window.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            window.animator().alphaValue = 1
        }

        let timer = Timer(timeInterval: BubbleGeometry.readingTime(for: text),
                          repeats: false) { [weak self] _ in
            self?.fadeOutBubble()
        }
        RunLoop.main.add(timer, forMode: .common)
        bubbleTimer = timer
    }

    /// Put the bubble where it belongs relative to the pet right now.
    ///
    /// Called on every animation tick as well as at show time: the pet is held still while
    /// it talks, but "held still" depends on the Dock not moving underneath it, and the
    /// Dock can be resized or hidden mid-sentence.
    func positionBubble() {
        guard let bubbleWindow = bubbleWindow, let bubbleView = bubbleView,
              let petWindow = window, let delegate = delegate else { return }

        let petFrame = petWindow.frame
        let visible = (delegate.interactionScreen ?? NSScreen.main)?.visibleFrame
            ?? petFrame.insetBy(dx: -200, dy: -200)

        let frame = BubbleGeometry.frame(size: bubbleView.bounds.size, above: petFrame,
                                         within: visible, gap: Self.bubbleGap)
        bubbleWindow.setFrame(frame, display: true)
        bubbleView.tailCenterX = BubbleGeometry.tailCenterX(in: frame, pointingAt: petFrame)
    }

    private func fadeOutBubble() {
        guard let window = bubbleWindow else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Guarded: another bubble may have been put up during the fade, and tearing
            // down whatever is current would take the new one with it.
            if self?.bubbleWindow === window { self?.dismissBubble() }
        })
    }

    /// Take the bubble down now. Safe to call when there is none.
    func dismissBubble() {
        bubbleTimer?.invalidate()
        bubbleTimer = nil
        bubbleWindow?.orderOut(nil)
        bubbleWindow = nil
        bubbleView = nil
        isTalking = false
    }

    /// The bubble's window frame, or `nil` when the pet is not talking. For the self-test.
    var bubbleFrame: CGRect? { bubbleWindow?.frame }
}

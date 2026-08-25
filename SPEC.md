# SPEC.md — DockPet

A macOS background app that renders an animated pixel-art pet walking along the top
edge of the Dock. Purely decorative, no interaction required in v1.

**Target OS: macOS 26.5 (Tahoe).** Some notes below are version-specific; they are
marked. Read this whole file before writing code. Follow the working agreement in §9.

---

## 1. Hard constraints

These are decisions, not suggestions. If you think one is wrong, say so and wait for
my answer — do not silently do something else.

- **Language/UI:** Swift + AppKit. No SwiftUI-only app lifecycle (`@main struct App`);
  use `NSApplication` + `NSApplicationDelegate` explicitly. SwiftUI is allowed *inside*
  the window's content view if it's simpler, but the window itself must be a real
  `NSWindow` subclass I can configure.
- **Build system:** Swift Package Manager only. **Do not create an `.xcodeproj`.**
  I need every file in this repo to be plain text you can edit reliably.
- **No SpriteKit, no Electron, no Tauri, no Python.**
- **No third-party dependencies** in v1. Foundation, AppKit, CoreGraphics, QuartzCore only.
  **[M11]** `ServiceManagement` is added to that list, for the login item and nothing else.
  It is a system framework, so §1's actual rule — nothing that is not shipped by Apple —
  still holds; the list was an enumeration of what had been needed so far, not a ceiling.
- **Deployment target: macOS 13.0**, even though I run 26.5. Nothing here needs a newer
  API, and a low target keeps the toolchain boring. Do not raise it "to use modern APIs."
- **Energy discipline is a requirement, not polish.** This app runs all day. See §6.

## 2. Repo layout

```
Package.swift
SPEC.md
PROBE.md                     // measured output from M0; see §4
bundle.sh
dockprobe.swift              // standalone diagnostic, not part of the app target
makecert.sh                  // [M8] issues the local code-signing identity, run once
makeicon.swift               // [M7] generates Resources/AppIcon.icns, also standalone
makesprite.swift             // [M7] generates Resources/sprites/cat_walk.png, also standalone
Sources/
  DockPetCore/               // [M1] pure logic, no AppKit — importable by the test harness
    Geometry.swift           // coordinate conversion, pure functions
    Behavior.swift           // walker; state machine joins it at M5
    SpriteSheet.swift        // [M4] sidecar metadata, validation, frame timing
    Config.swift             // [M6] config.json schema + validation
    Phrasebook.swift         // [M10] the prompts and what the pet says to each
    AlphaMask.swift          // [M10] which sprite pixels are solid enough to click
    BubbleGeometry.swift     // [M10] where the speech bubble goes, and for how long
    Meeting.swift            // [M11] when two pets have met, and what they trade
    Kiss.swift               // [M12] the kiss's phases, and where the hearts are
  DockPet/                   // the executable
    main.swift
    AppDelegate.swift
    PetWindow.swift          // NSWindow subclass
    PetView.swift            // rendering
    SpriteLoader.swift       // [M4] finds/validates the sheet, generates the placeholder
    RenderTest.swift         // [M4] --render-test: checks drawing by inspecting pixels
    ConfigStore.swift        // [M6] reads/seeds config.json
    MenuBarItem.swift        // [M7] status item in the menu bar
    DockTiles.swift          // [M8] the Dock's tile bounds, via Accessibility
    DockLocator.swift        // finds the walkable strip
    PetInteraction.swift     // [M10] the click, the prompt menu, the bubble's lifetime
    BubbleWindow.swift       // [M10] draws the speech bubble
    Pet.swift                // [M11] one pet: its window, view, walker, behaviour, clicks
    OnboardingWindow.swift   // [M11] shown only when Accessibility is missing
    LoginItem.swift          // [M11] SMAppService registration, and its Settings toggle
    HeartsWindow.swift       // [M12] the hearts that rise over a kissing pair
Tests/
  DockPetTests/              // [M1] one executable target, not XCTest — see below
    main.swift               // entry point: runs each suite, then reports
    Harness.swift            // the assertion helpers (this is the whole "framework")
    GeometryTests.swift
    BehaviorTests.swift      // [M3]
    SpriteTests.swift        // [M4]
    ConfigTests.swift        // [M6] config + strip policy
    CatPaletteTests.swift    // coat recolouring
    PhrasebookTests.swift    // [M10] the name slot, the pools, determinism
    AlphaMaskTests.swift     // [M10] pixel lookup, the flip, the click tolerance
    BubbleTests.swift        // [M10] bubble placement, screen edges, the tail
    MeetingTests.swift       // [M11] overlap, cooldown, the exchange, birthday dates
    KissTests.swift          // [M12] steering, the phases, the drift, the toggle
Resources/
  sprites/
```

> **[M1] Amendment — testing without Xcode (2026-08-25).** This machine has Command Line
> Tools but no Xcode, so **`swift test` cannot run**: `XCTest` ships inside Xcode, and the
> swift-testing module (`import Testing`) is not in the CLT toolchain either. Both were
> checked.
>
> `Tests/DockPetTests/GeometryTests.swift` is therefore an **`.executableTarget`**, not a
> `.testTarget`, run with `swift run GeometryTests`. It prints one line per assertion,
> reports failures with `file:line`, and exits non-zero if any fail — verified by
> deliberately breaking an expectation. No third-party dependencies, so §1 still holds.
>
> This requires the pure code to be importable, hence the new `DockPetCore` library target.
> Side benefit: §5's "no AppKit imports in `Behavior.swift`" becomes compiler-enforced,
> because `DockPetCore` links neither AppKit nor the app.
>
> `swift build` still builds everything, including the harness.

`bundle.sh` must:
1. `swift build -c release`
2. assemble `DockPet.app/Contents/{MacOS,Resources}`
3. copy the binary and `Resources/`
4. write `Info.plist`
5. print the path to the built `.app`

It must be idempotent and safe to re-run. Target loop: `./bundle.sh && open DockPet.app`.

`Info.plist` must include: `CFBundleName`, `CFBundleIdentifier` (`com.local.dockpet`),
`CFBundleExecutable`, `CFBundlePackageType` = `APPL`, `CFBundleShortVersionString`,
`LSMinimumSystemVersion` = `13.0`, and **`LSUIElement` = `true`** (no Dock icon, no menu bar).
Also call `NSApp.setActivationPolicy(.accessory)` at startup as a belt-and-braces measure.

## 3. Window configuration

The pet lives in a borderless, transparent, click-through window floating above the Dock.

```swift
window.styleMask = .borderless
window.level = .statusBar        // NSWindow.Level(rawValue: 25); Dock sits at 20
window.isOpaque = false
window.backgroundColor = .clear
window.hasShadow = false
window.ignoresMouseEvents = true
window.collectionBehavior = [.canJoinAllSpaces, .stationary,
                             .fullScreenAuxiliary, .ignoresCycle]
```

`PetWindow` overrides `canBecomeKey` and `canBecomeMain` to return `false`.
Use `orderFront(nil)`, never `makeKeyAndOrderFront` — the window must never take focus.

Do **not** use `.screenSaver` or higher levels — they draw over the menu bar and over
fullscreen apps, which looks broken.

## 4. Locating the walkable strip

> **Amended after M0 (2026-08-25).** §4a's autohide note was wrong for macOS 26 and §4b's
> premise does not hold at all. Changes are marked **[M0]** below; evidence is in
> `PROBE.md`.

This is the core problem. It splits into two independent questions, with very different
difficulty. **Do not conflate them.**

### 4a. Vertical position — use `NSScreen.visibleFrame`

`visibleFrame` is the screen rect with the menu bar and Dock already excluded. With the
Dock at the bottom, `screen.visibleFrame.minY` **is** the Dock's top edge. This is public,
stable, correctly-oriented AppKit API. It needs no coordinate flipping and no window
scraping. Use it.

With the Dock on the left or right, the relevant edge is `visibleFrame.minX` / `maxX`
instead. The inset also identifies *which* screen has the Dock: a Dock-less display has a
zero inset on that edge.

**[M0] Correction — autohide.** This spec previously claimed that `visibleFrame` reclaims
the Dock's space when autohidden. **It does not on macOS 26.5.** With `autohide=1` and the
cursor verified to be nowhere near the Dock edge, the bottom inset stays at its full value
(80.0 pt), unchanged from the Dock-visible case, sampled once a second for 8 s. So
`visibleFrame` gives the correct *position* but tells you nothing about *presence*: relying
on it alone would park the pet 80 pt above the desktop with no Dock beneath it. Presence
detection is §4b.

### 4b. [M8] Horizontal extent — the Dock's tiles, via Accessibility

> **[M9] Amended.** Tile confinement is no longer optional and no longer falls back. Where
> this section says the pet reverts to the full `visibleFrame` width without a measurement,
> it now goes **dormant** instead — see the [M9] bullets in §4c. The `confineToDock` config
> key was removed; there is nothing left to switch off.

**Decision: the pet walks the Dock's tiles when they can be measured, and the full width of
`visibleFrame` when they cannot.**

> **[M0], superseded.** This section previously read *"the pet walks the full width of
> `visibleFrame` … this is not a shortcut, it is the only option"*, on the grounds that the
> only remaining route was Accessibility and §4c ruled it out. The first half still holds —
> the window list genuinely cannot answer this. The conclusion did not: §4c's no-permission
> rule was written for *presence*, which must work for everyone at launch, and applying it
> to *extent* cost the feature for no gain. See `PROBE.md` F7.

**The window list is still useless for this.** `PROBE.md` F2: the Dock process owns exactly
three windows on macOS 26.5 — one at layer 20 whose bounds are the **entire screen**
(`0,0 1512×982`, identical to `screen.frame`), and two desktop-wallpaper windows at layer
−2147483624. No per-tile windows exist under any `CGWindowList` option set. The Liquid Glass
Dock is a full-screen surface (§8 trap 8, confirmed).

**The Accessibility API is exact.** `PROBE.md` F7: walk the Dock process's element tree to
its `AXDockItem` elements and union their frames. Measured `381.9..1130.1` on a 1512 pt
screen — the strip drops to under half its old width. Rules:

- **Union the items; never take the enclosing `AXList` rect.** The list is padded well past
  the tiles it holds. Only the union tracks what is actually drawn.
- **Walk to the items, don't index to them.** The Dock's tree has changed shape across
  releases; a hardcoded path breaks silently on the next one.
- **Keep only items inside the Dock's band** — the strip between `frame` and `visibleFrame`
  on the Dock's edge. This is what excludes an open stack's popup, whose items float above
  the Dock and would otherwise stretch the measurement across half the screen.
- **AX reports CG (top-left origin) coordinates.** Flip through `Geometry.flipCGToAppKit`.
  This is the case §4b [M0] kept the flipping code around for.
- **Measure on the 500 ms locator poll, never on the 12 fps animation tick.** The read costs
  7–9 ms (`PROBE.md` F7). The tiles move slowly enough that a half-second-old measurement is
  indistinguishable from a fresh one.
- **Both ends move.** Adding a dock item widens the Dock *and* re-centres it. Track the
  measured origin, not just the width.

**Degrading is not optional.** Every failure — no grant, unreadable tree, a rect that does
not overlap the screen, an empty rect — falls back to the [M0] full-width strip. A pet that
walks too far is a cosmetic miss; a pet parked off-screen is an invisible app. `config.json`
can also turn confinement off outright with `"confineToDock": false`.

**The window list is still used, for one thing only: presence.**


```swift
// true  <=> the Dock is on screen right now
// false <=> autohidden, or vanished (see §8 trap 9) -> go dormant
func isDockOnScreen() -> Bool
```

`PROBE.md` F5/F6: the Dock-owned layer-20 window is present in the on-screen window list
**exactly while the Dock is drawn on screen**, and absent while it is not. With autohide
enabled it comes and goes as the Dock slides in and out — it does not merely reflect the
autohide *setting*. This is the live signal §6 needs to suspend the animation, and it is
what makes §8 trap 9 degrade into the §4d dormant path instead of leaving the pet stranded
in mid-air.

Consequence for behaviour: with autohide on, the pet is visible only while the Dock is,
appearing and disappearing with it rather than being disabled outright. That is the
intended behaviour, not a bug to be smoothed over.

Rules for that call:

- `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)`,
  filter `kCGWindowOwnerName == "Dock"` (still correct on macOS 26 — `PROBE.md` F3) **and**
  `kCGWindowLayer == 20`. The layer test is not optional: the Dock also owns the desktop
  wallpaper windows, which are on screen at all times and would otherwise read as presence.
- Read no other field. No bounds, no titles, no capture. Nothing is coordinate-converted,
  so no flipping is involved and no permission is required.

**Coordinate flipping is still implemented and tested in `Geometry.swift`** even though the
app no longer converts a Dock rect: `dockprobe.swift` reports both spaces, the second
display sits at negative y (`x=1512, y=-98`) which is exactly the case that breaks naive
conversions, and the tests in §4b's original list are cheap insurance if the Dock window
ever regains meaningful bounds.

```swift
// primary = the screen whose frame.origin == .zero (do NOT assume screens[0])
let flippedY = primary.frame.maxY - (cgRect.origin.y + cgRect.height)
```

### 4c. API status — do not "modernise" this

`CGWindowListCreateImage` was deprecated in macOS 14 in favour of ScreenCaptureKit.
**`CGWindowListCopyWindowInfo` was not deprecated** and works on macOS 26. If you see
deprecation chatter, it is about the image-capture function, not the metadata function.

**Do not migrate to ScreenCaptureKit / `SCShareableContent`.** It requires Screen Recording
permission, which this app has no business asking for. `CGWindowListCopyWindowInfo` needs
no permission for owner name and bounds — only window *titles* and pixel capture are gated.
Do not add `NSScreenRecording*` keys or a Screen Recording prompt of any kind.

**[M8] Accessibility is the one exception, and it is strictly opt-in.** This section
previously read *"do not add permission prompts … or TCC handling of any kind"*, which is
why §4b [M0] gave up on the tiles. The rule was right about what it was written for and
wrong as a blanket ban, so it is now scoped:

- **[M9] Launch prompts once when the grant is missing.** This previously read *"nothing at
  launch is allowed to prompt"*, which was correct while confinement was optional: an
  ungranted app still had a working pet, so a dialog would have been an interruption
  demanding nothing. [M9] made confinement unconditional, so an ungranted app has **no
  visible pet at all** — and starting up invisible with no explanation is worse than a
  dialog. `AXIsProcessTrusted()` (non-prompting) is still what every subsequent check uses;
  `AXIsProcessTrustedWithOptions` fires once at launch, from the menu bar's *Grant
  Accessibility…* item, or from `--dock-bounds`. **Self-test modes never prompt** —
  `--render-test`, `--menu-test`, `--settings-test` and `--dock-bounds` are gated on
  `options.isSelfTest`, so running the suite cannot throw a TCC dialog at anyone.
- **[M9] It no longer degrades — it waits.** This previously read *"everything degrades
  without it … Accessibility buys a narrower strip and nothing else"*. That is no longer
  true and the weaker claim would be a trap for the next reader. The pet is now **always**
  confined to the tiles, so without a measurement there is nowhere legitimate to stand and
  the locator returns `.absent(.accessibilityNotGranted)`. Presence (§4b) and position
  (§4a) still work ungranted; what changed is that the app declines to use them on their
  own. This is a deliberate product decision, not an accident: a pet strolling across empty
  desktop is the thing being fixed.
- **The grant is keyed to the code signature, and which signature decides whether it
  survives a rebuild.** `codesign -d -r-` prints the requirement TCC stores:

  | signed with | designated requirement | survives `./bundle.sh`? |
  |---|---|---|
  | nothing / ad-hoc | `cdhash H"…"` | **no** — the hash *is* the code |
  | a certificate | `identifier "com.local.dockpet" and certificate leaf = H"…"` | **yes** — names the certificate, not the code |

  `./makecert.sh` issues the local certificate; `bundle.sh` then signs with it and the grant
  holds. **Verified:** granted once, then rebuilt with a real code change — cdhash went
  `088e5af6…` → `5c99736b…` and `AXIsProcessTrusted` stayed true with no re-approval.

  `bundle.sh` prefers an `Apple Development` identity if one ever exists, falls back to the
  local one, and falls back to ad-hoc only with a warning. `DOCKPET_SIGN_IDENTITY` overrides
  the search. It aborts if an identity was found but the resulting requirement is still
  hash-based, because that failure is otherwise invisible until the grant lapses.

  Two things learned the hard way, both encoded in the scripts:

  - **Sign by SHA-1 hash, not by name.** Two certificates sharing a common name make
    `codesign --sign "<name>"` fail with `ambiguous`, and the fallback silently produced an
    ad-hoc build. `makecert.sh` clears stale certificates before issuing.
  - **Not the login keychain.** macOS gates the login keychain's private keys per use, so
    every `codesign` either raised a GUI dialog or blocked on one — builds hung and twice
    came out ad-hoc mid-run. Fixing that needs `set-key-partition-list`, which needs the
    keychain password, which for the login keychain is the account password and cannot be
    scripted. Hence a dedicated `dockpet-signing.keychain-db` with a known password.

- **Adding the bundle by path in System Settings does not work.** Measured: the entry
  appears and the toggle stays on, but `AXIsProcessTrusted()` still returns false. Use the
  prompt (the menu item, or `--dock-bounds`), which registers the running binary. When the
  requirement changes for any reason — an ad-hoc rebuild, or a reissued certificate — clear
  the stale entry first: `tccutil reset Accessibility com.local.dockpet`.

- **The launch log's `walk area` line is what makes a lapsed grant visible** — it is the
  difference between "the pet is walking the whole screen because a permission lapsed" and
  "the pet is broken". Do not remove it.

### 4d. Polling

Poll every 500 ms via a `Timer` scheduled in `.common` run-loop mode. `visibleFrame`
changes on: tile-size change, orientation change, display connect/disconnect, and menu-bar
changes. **[M0]** It does *not* change on autohide or magnification (`PROBE.md` F4, Run 4),
so each poll must check both `visibleFrame` **and** `isDockOnScreen()` from §4b. If the Dock
is not on screen, or no screen has a Dock-side inset, return `nil` and go dormant — never
guess a position.

## 5. Sprites

I will place a horizontal sprite sheet at `Resources/sprites/cat_walk.png`, frames laid
out left-to-right, uniform size. Read dimensions from a sidecar
`cat_walk.json`: `{"frameWidth":32,"frameHeight":32,"frameCount":8,"fps":10}`.
Do not hardcode frame geometry.

**[M7] Renamed from `dog_*` to `cat_*`.** The pet is a cat, and file names saying otherwise
would be a permanent small lie. All per-state sheets follow: `cat_walk`, `cat_idle`,
`cat_sit`, `cat_sleep`.

**[M7] The walk sheet is now real art, generated by `makesprite.swift`** — an 8-frame
32x32 side-view tabby: four legs on a lateral-sequence gait (paw phases 0, 0.25, 0.5, 0.75),
a body that bobs twice per stride, and a tail that sways through the cycle. Off-side legs
are drawn a shade darker for depth.

It is drawn pixel by pixel rather than as antialiased shapes scaled down, and each body part
is stamped with its own 1 px outline instead of outlining one merged silhouette — that is
what stops the legs dissolving into the body. Like the icon, it is generated rather than
committed as a binary blob, and `bundle.sh` runs the generator when the PNG is missing.

The runtime placeholder generator below still exists as the last-resort fallback for a
missing sheet.

Until I supply art, generate a placeholder sheet at first launch — 8 frames of a solid
rectangle with a cycling colour — so the pipeline is testable without assets.

**[M4] Two notes on the placeholder.**

It is written to `~/Library/Application Support/DockPet/sprites/`, not into the bundle:
`bundle.sh` rebuilds `Contents/Resources` from scratch every run, so a file written there
would disappear on the next build. A sheet in the bundle always wins; the generated one is
the fallback.

Each placeholder frame carries two small markers in addition to the cycling body colour —
a white 6x6 "head" block at the top-left, and a black 4x4 block that slides along the
bottom. A solid rectangle is symmetric, so it cannot show whether the sheet was drawn
upside down or whether the horizontal flip actually happened. The markers make orientation
and flip checkable from rendered pixels, which is the only way to verify §5 on a machine
whose screen I cannot see (§9). Real art replaces all of this.

**[M4] Verifying the drawing.** `--render-test` renders `PetView` into an offscreen bitmap
and asserts against the pixels: the flipped render is an exact mirror of the unflipped one,
the sprite is horizontally asymmetric so the flip is visible at all, scaling introduces no
blended colours, the background is transparent, and every frame differs from its neighbour.
It exits non-zero on failure.

**[M7] Two of those checks were rewritten to be art-independent**, because the originals had
quietly been testing the placeholder rather than the pipeline:

- *Orientation* was "the white head marker is at the top-left". Real art has no such marker.
  It now checks that the sprite reaches the bottom of its frame — which is the M2 acceptance
  criterion restated in terms of artwork, since the window's bottom edge is what rests on the
  Dock. Art that floats, or a sheet decoded upside down, fails. The marker checks still run
  when the placeholder is in use.
- *Nearest-neighbour* was "at most 6 distinct colours", calibrated to the placeholder's four.
  The cat has eight and failed a correct render. It now compares the rendered colour count
  against the *source sheet's* count: nearest-neighbour maps each destination pixel to one
  source pixel and so preserves the count, while interpolation blends neighbours. Verified by
  forcing `interpolationQuality = .high`, which takes the render from 8 colours to **443**.

**[M6] Optional per-state sheets.** `dog_walk.png` is required. `dog_idle.png`,
`dog_sit.png` and `dog_sleep.png` are optional, each with its own sidecar and its own
`frameCount`/`fps`. A state without a sheet renders the walk sheet's first frame as a
still pose, so the pet never blanks out.

All sheets must share `frameWidth` and `frameHeight`. A differing canvas would resize the
window mid-behaviour and change how far the pet may walk; padding the smaller pose to a
common canvas is the standard fix. A mismatched sheet is ignored with a log line naming
both sizes — never fatal, since the walk sheet can always carry the pet.

A state that has its own multi-frame sheet keeps the animation timer running so that
animation plays, even though the pet is not moving. A state falling back to a frozen frame
suspends it (§6).

Rendering rules:
- Nearest-neighbour only. `layer.magnificationFilter = .nearest`, and disable image
  interpolation in the drawing context. Blurry pixel art means this is wrong.
- Integer scale factors only (2x, 3x), accounting for `backingScaleFactor`.
- Flip horizontally for the return trip; do not require a second sheet.

## 6. Energy

Non-negotiable. The app must:
- Animate at **10–12 fps**, not 60.
- Fully suspend the animation timer (not merely skip drawing) when any of these hold:
  - the Dock cannot be located (autohidden)
  - the frontmost app is fullscreen, or the pet's screen shows no Dock — **[M6]** measured:
    entering fullscreen removes the Dock's window from the window list *and* zeroes the
    screen's bottom inset, so this is already covered by "the Dock cannot be located"
    within one 500 ms poll. An earlier draft tracked `NSWindow.occlusionState` for this;
    against a real fullscreen window that check never fired once, and it was removed rather
    than kept as an unverified path.
  - `ProcessInfo.processInfo.isLowPowerModeEnabled` is true
  - **[M5]** the pet is not walking — `idle`, `sit` and `sleep` are stationary, so there is
    nothing to redraw. Three of the four states qualify, and measured over a long run the
    pet is stationary about a third of the time. Same reasoning as the conditions above:
    running a 12 fps timer to redraw an unchanged frame is exactly what this section
    forbids.

> **[M11] Amendment — the stationary rule with two pets (2026-08-25).** With more than one
> pet, the suspend condition above becomes "**every** pet is stationary", not "the pet is".
> One walking cat keeps the timer alive for both, which is correct — but it means the
> measured one-third idle figure is a single-pet number and does not survive a second cat.
> Two independent state machines are both stationary far less often than one is; expect the
> saving to fall to roughly a ninth by the same reasoning, and do not treat the old figure
> as a regression when it does.
>
> There is still exactly **one** animation timer and **one** 500 ms locator poll for the
> whole app, not one of each per pet. `AppDelegate` ticks its `[Pet]` from them. A second
> pet must not double the app's wakeups — only the work done inside a wakeup.
- Keep the 500 ms locator poll running while suspended, so it can wake.
- Never use `CVDisplayLink`. Overkill here.

Add a `--verbose` flag logging once per second: `visibleFrame`, Dock rect (both coordinate
spaces, if used), window frame, current state, timer active/suspended. I read this log to
debug positioning, because you cannot see my screen.

## 7. Milestones

Do these **in order**. Stop after each and tell me how to verify it. Do not start the next
until I confirm.

**M0 — Probe (do this first, before any app code).**
Write `dockprobe.swift`, a standalone script runnable via `swift dockprobe.swift`, printing:
every `Dock`-owned window with its layer, alpha and bounds; and for every `NSScreen`, its
`frame`, `visibleFrame`, and `backingScaleFactor`.
I will run it under five configurations — Dock at bottom, Dock left, autohide on,
magnification on, and with a dozen apps open so tiles shrink — and paste the output into
`PROBE.md`.
Then **read `PROBE.md` and tell me what it implies** for §4b: which Dock window is the real
one, whether its bounds match the visible tiles, and whether the §4a assumption holds.
Amend §4 of this spec with what you learn.

**M1 — Skeleton.** `Package.swift`, `bundle.sh`, `Info.plist`; app launches, prints a line,
shows no Dock icon and no menu bar, quits via `killall DockPet`.
*Verify:* `./bundle.sh && open DockPet.app`; no icon appears.

**M2 — A red square in the right place.** 50×50 opaque red borderless window, bottom edge
resting exactly on the Dock's top edge, positioned at the left end of the walkable strip.
No animation, no sprite. Must survive autohide toggling, Dock repositioning (bottom/left/
right), and Space switching.
*Verify:* visual + `--verbose`. **This is the milestone that matters. Take your time.**

**M3 — Movement.** The square walks left→right across the strip, turns, walks back. ~30 px/s.
Position recomputed against the live strip each tick, never a cached one.

**M4 — Sprite animation.** Replace the square with the animated sheet: transparent
background, nearest-neighbour scaling, horizontal flip on turn.

**M5 — Behaviour.** States: `walk`, `idle`, `sit`, `sleep`, with weighted random transitions
and dwell times. `Behavior.swift` must be a pure, testable type taking elapsed time and
returning a state — no AppKit imports in that file.

**[M5] Notes from building it.**

*Randomness is seeded.* `BehaviorMachine` owns a `SplitMix64` generator rather than calling
the system one, so a given seed replays exactly. Otherwise the state machine would be
unverifiable, and "it looked plausible while I watched it" is not a check (§9). The app
seeds from the system generator at launch, so each run still differs.

*The behaviour clock runs on the 500 ms locator poll, not the animation timer.* The
animation timer is suspended for three of the four states, so it cannot be what decides
when to leave them. The clock is also frozen while the pet is dormant — a pet that spent an
hour behind an autohidden Dock should not wake up mid-nap.

*Dwell length matters as much as weight.* Share of the clock is roughly visit rate times
dwell. The first tuning gave `sleep` a low weight (10) but a 15–45 s dwell, and it still ate
**34%** of the day. Retuned to 5/12–30 s it sits at ~9%, with `walk` at ~67%.
`StateMachineTests` measures the distribution and pins it with wide bands, so a future
retune cannot quietly turn the pet into a sleeping rock.

*One sheet means the stationary states look alike.* §5 specifies a single `dog_walk.png`,
so `idle`, `sit` and `sleep` all render as a frozen frame 0. The behaviour is real — the pet
genuinely stops and stays stopped for the right duration — but telling sitting from sleeping
needs art this spec has not asked for. Worth deciding at M6 whether to add optional
per-state sheets.

**Amended: a stopped pet turns to face you.** Freezing frame 0 left the cat stopped
*mid-stride, in profile*, which read as a stall rather than a rest. `makesprite.swift` now
generates three more sheets — `cat_idle` and `cat_sit` drawn front-on, `cat_sleep` curled —
so every stationary state has a pose of its own and the "telling sitting from sleeping"
gap above is closed. Two consequences worth stating:

* *Only the walk sheet is mirrored.* The flip in §5 exists for the return trip along a
  side-on walk cycle. Mirroring a front-on pose would flip its tail curl, and would make a
  stopped pet's pose depend on which way it happened to be walking a moment earlier, so
  `PetView` flips the walk sheet only. A state falling back to the walk sheet is flipped
  like the walk sheet.
* *The poses are single-frame on purpose.* §6 suspends the animation timer for a stationary
  state whose sheet has nothing to animate, so a still pose costs exactly what the frozen
  walk frame cost. `--render-test` asserts each pose is a still, so adding a blink or a
  breathing cycle later has to be a deliberate act with the timer cost accepted.

**M6 — Polish.** Multi-monitor (pet stays on one configurable screen), Dock magnification
handling, and `~/Library/Application Support/DockPet/config.json` for speed/scale/screen.

**[M6] Horizontal Docks only.** A side Dock produces a vertical strip, and a dog walking up
a wall looks broken, so the pet goes dormant instead — logged as "Dock is on a side edge".
The vertical geometry remains implemented and tested behind `StripPolicy.anyEdge`; only the
app's policy rejects it, so restoring vertical walking is a one-line change.

**[M6] config.json.** Written with defaults on first launch. Every key is optional:

```json
{ "speed": 30, "scale": 2, "screen": null, "confineToDock": true }
```

- `speed` — points per second. Clamped to 0 < speed <= 500.
- `scale` — integer sprite scale (§5). Clamped to 1...8.
- `screen` — `localizedName` of a display to pin to, or `null` to follow the Dock.
  Pinning to a display with no Dock, or one that is not attached, makes the pet dormant
  rather than moving it somewhere unasked.
- **[M10]** `userName` — what the pet calls you in a speech bubble. `null` falls back to
  the first name on the macOS account; `""` means greet me without a name.
- **[M9]** `confineToDock` was **removed**. The pet is always confined to the Dock's tiles;
  the only variable is whether Accessibility has been granted. An older config file still
  carrying the key is accepted and the key ignored, rather than rejected.
  to the full width and this key has no visible effect. Set `false` to keep the full width
  even when the tiles *can* be measured.

Bad values are clamped and logged, never fatal: a config file is hand-edited, and a typo
should cost a log line, not your pet.

**[M6] Magnification needs no handling.** Verified live with magnification on and
`largesize` 128: `visibleFrame` is unchanged, the baseline stays at 80.0, and the pet keeps
walking correctly. Magnification is a hover-time visual effect that never touches the
geometry this app reads. Consistent with §8 trap 10 — there is nothing to compensate for.

**[M7] Menu bar status item.** `LSUIElement` leaves no way to tell DockPet is running, and
no way to reach it short of `killall`. A status item in the menu bar fixes both; it does not
conflict with §2's `LSUIElement` requirement, which suppresses the app's *own* menu bar, not
status items. The menu shows what the pet is doing right now, and offers Pause/Resume, Edit
Configuration, Reveal Sprites Folder, and Quit.

Controlled by `"menuBarIcon"` in config.json, default `true`. Turning it off returns the app
to being reachable only via `killall DockPet`.

**[M7] The icon is a cat**, in both senses: the menu bar item uses the `cat.fill` SF Symbol
as a template image so the system tints it for light and dark menu bars, and the bundle gets
`Resources/AppIcon.icns` — a white cat on an indigo gradient, laid out on Apple's 824/1024
icon grid with a 22.37% corner radius so it sits correctly beside other Mac icons.

The icon is generated by `makeicon.swift` rather than committed as a binary blob. `bundle.sh`
runs it automatically when `Resources/AppIcon.icns` is missing, so a fresh checkout still
produces a bundle with an icon, and a normal rebuild does not pay for it.

**[M7] Reload Sprites & Config.** Re-reads config.json and every sprite sheet without
restarting, rebuilding the pet view and resizing the window if the scale or canvas changed.
Also bound to `SIGHUP`, so `killall -HUP DockPet` reloads from a shell — which is what makes
the path testable from outside the app, since a menu click cannot be scripted (§4c).

Nothing in a reload is fatal, unlike launch: it runs while the pet is on screen, so a typo in
a sidecar keeps the sheets already loaded and costs a log line. Verified live by adding a
sheet and changing the config under a running app: `scale` 2 → 3 resized the window from
64x64 to 96x96, travel was recomputed from 1448 to 1416, a new `sit` sheet was picked up, and
the pet stayed flush on the Dock edge throughout.

Verified two ways, since a menu click cannot be scripted without Accessibility permission
(§4c): the window server shows the menu-bar strip going from 16 to 18 windows on launch
(one item per display), and `--menu-test` drives pause/resume in-process and checks that the
animation timer is suspended, the pet hidden, the locator poll still running, and everything
restored on resume.

Incidentally this confirms §8 trap 7 first-hand: **every** status item, DockPet's included,
reports `kCGWindowOwnerName == "Control Center"` rather than its own app. Harmless here —
`isDockOnScreen()` filters on owner `"Dock"` *and* layer 20 — but it is the documented
macOS 26 behaviour, now measured.

**[M6] A logging defect worth recording.** The location line ("dormant — ...") and the timer
line ("suspended — ...") shared one "last logged" slot, so while dormant each looked like a
change and both printed twice a second. They are now tracked separately and tagged
`[state]` and `[timer]`. 70 s of running produces ~11 transition lines instead of ~280.

**M9 — Always confined.** The pet is confined to the Dock's tiles unconditionally.

- `confineToDock` is gone from `config.json` and from the Settings window. The window shows
  a *Walk area* line reporting whether Accessibility has been granted, because a control
  that cannot be switched off should not look like one.
- No grant means **no pet**: `DockLocator` returns `.absent(.accessibilityNotGranted)` and
  the app is dormant, with the menu bar item reading *Waiting for Accessibility*. The
  animation timer is suspended throughout, per §6.
- The launch path prompts once when the grant is missing (§4c [M9]).
- `.tilesUnmeasurable` is a separate absence reason from `.accessibilityNotGranted`, so the
  log distinguishes "you have not granted this" from "granted, but the read failed" — two
  very different things to debug.

**M10 — Clicking the pet.** The pet answers a short menu of prompts in a speech bubble.

- **The click target is the art, not the window.** The pet's window is a rectangle around a
  32x32 sprite that is mostly transparent, and it sits on top of the Dock. AppKit has no
  per-pixel click-through, so `PetWindow.ignoresMouseEvents` is toggled: it is switched off
  only while the cursor is over solid sprite pixels, and stays on everywhere else, so the
  Dock icon under the cat keeps its own clicks. `AlphaMask` (pure) owns the pixel lookup
  and the view-point-to-art-pixel mapping, including the walk sheet's horizontal flip.
- **Driven from three places, because none of them is enough alone.** A global mouse
  monitor catches the cursor moving; the 12 fps animation tick catches the cat moving; the
  500 ms locator poll catches both, and is the only one that always runs — the animation
  timer is suspended for three of the four states (§6), so without it a sleeping cat would
  depend entirely on the monitor.
- **A click tolerance of 2 art pixels.** The tail and ears are one or two pixels thick. A
  pixel-exact hit test makes them unclickable in practice; 2 px is 4 pt at the default 2x.
- **`--interaction-test` prints the silhouette.** Per §9: a hit test that is wrong by a row
  is invisible on screen — the cat still looks right, it just stops taking clicks where you
  aim. The test prints the mask as text and derives its own click-through sample from it,
  so it asserts nothing about which sheet happened to load (the generated placeholder fills
  its frame; the shipped cat does not).
- **The cursor is the only affordance.** There is no button, no hover highlight and no
  tooltip on a 64 pt sprite, so hovering the cat shows `NSCursor.pointingHand`. It is
  driven by an `NSTrackingArea` with `.cursorUpdate` and **`.activeAlways`**: `NSCursor.set()`
  alone does not survive the mouse moving — the system resets the cursor from the cursor
  rects of the window under the pointer — and every activation mode other than
  `.activeAlways` would leave the cursor alone forever, because the pet's window can never
  be key (§3) and DockPet is never the active app. The area is installed in `init`, not on
  AppKit's first layout pass: on a fresh install the pet is hidden until Accessibility is
  granted, so that pass can be a long way off. `cursor(at:)` uses the same `AlphaMask` the
  click does — a pointing hand over a spot that does not take clicks is a worse lie than no
  cursor change at all, and `--interaction-test` samples 1024 points to confirm the two
  agree everywhere rather than at the one point it is easy to check.
- **The bubble is a second window.** Not a bigger pet window: `Geometry.petFrame` derives
  the pet's frame from the sheet metadata and rests it exactly on the Dock's edge, and every
  positional check in the app is written against that. `BubbleGeometry` (pure) clamps the
  bubble inside `visibleFrame` and keeps the tail pointing at the cat after it has been
  shoved sideways — the pet spends much of its life at one end of the Dock.
- **Drawn with antialiasing off**, like the sprite. That is also what gives the tail its
  stepped diagonal for free. The text is the one thing antialiased; 12 pt glyphs are
  unreadable otherwise, and nobody expects the words themselves to be pixel art.
- **The behaviour clock stops while the pet talks**, so it holds the pose it answered in
  rather than wandering out from under its own sentence. `BehaviorMachine.force` sets the
  state and rolls a fresh dwell, so a forced nap is a nudge rather than a mode the user has
  to click their way back out of.
- **`userName` is new in `config.json`**, with a *Call me* field in Settings. `nil` falls
  back to the first name on the macOS account, so a fresh install greets you properly. Every
  phrase is written to read correctly with the name removed — `Phrasebook.render` drops the
  slot along with the comma that introduced it, and hands the sentence its capital letter
  back when the slot came first.

**M11 — Two cats, and the gift layer.** A second pet walks the same Dock, the two meet and
talk, and the app survives being handed to someone who has never seen it.

This milestone has a fixed external deadline, so it is ordered cheap-and-certain first. Each
step below must leave the app shippable: if the work stops after any one of them, what has
already landed is complete, not half-built.

**11a — Launch at login, and onboarding.**

- `SMAppService.mainApp.register()`, available since macOS 13, so §1's deployment target
  holds. `launchAtLogin` is a new `config.json` key with a toggle in Settings. A registration
  failure is logged and clamped to "off", never fatal — §1's rule about bad values applies to
  the login item too.
- `OnboardingWindow` appears **only** when Accessibility has not been granted at launch. It
  is not a wizard and not a welcome tour: one sentence saying what the cat is, one button
  that opens the Accessibility pane, and a live status line that flips to *Found your Dock*
  and closes itself when `DockTiles` first reads successfully.
- It exists because of the M9 rule that no grant means no pet. That is the right behaviour
  for me, who knows why the Dock is empty; it is indistinguishable from a broken app for
  anyone else. The window is the whole difference between "it doesn't work" and "it needs
  one permission".
- It reuses `MenuBarItem`'s existing grant path rather than issuing its own prompt. Two code
  paths that ask for the same permission will drift.

> **Uncertainty, per §9 — `SMAppService` on this build.** `SMAppService.mainApp.register()`
> is documented to require a signed bundle. `bundle.sh` does sign, but with the *local*
> self-signed identity from `makecert.sh` — an identity that exists only on my machine and
> on no other Mac. Whether registration succeeds under a signature whose certificate the
> target machine does not trust is **not known and must not be assumed**.
>
> Probe this before writing the Settings toggle: build, register, then check
> `SMAppService.mainApp.status`. It costs minutes.
>
> If it fails, the fallback is a `launchd` property list written to
> `~/Library/LaunchAgents/com.local.dockpet.plist` with `RunAtLoad`. Older, still supported,
> and indifferent to the signature. Take the fallback rather than dropping the feature: a
> pet that does not survive a reboot is gone within the week. Whichever path is used, the
> Settings toggle and the `launchAtLogin` config key are identical — only the mechanism
> behind them differs.

**11b — The gift layer.**

- Two new `config.json` keys: `birthday` (`"MM-DD"`, or `null`) and `dedication` (a single
  line, or `null`). Both optional, both clamped to nothing on a bad value.
- On a date matching `birthday`, the greeting pool is replaced by a birthday pool. Date
  matching is a pure function over `(month, day)` in `Meeting.swift` and is **tested against
  a passed-in date**, never `Date()` read inside the function — the same rule that keeps
  `BehaviorMachine` deterministic.
- `dedication` is said on the **first click of the day**, then not again until the date
  changes. This needs one persisted value, `lastGreetedDay`, written next to `config.json`
  rather than into it: `config.json` is a file a human edits, and app-written state does not
  belong in a file the user owns.
- Every birthday line follows the M10 name-slot rule: it must read correctly with the name
  removed.

**11c — The `Pet` extraction.**

- `Pet` owns what `AppDelegate` currently holds one of: `PetWindow`, `PetView`, `Walker`,
  `BehaviorMachine`, `PetInteraction`, and its own identity — `name`, `color`, `userName`.
  `AppDelegate` owns `[Pet]` and drives them from the single timer and single poll (§6
  [M11] amendment).
- **This step ships on its own with one cat.** The array has one element, nothing about the
  app changes visibly, and `swift build` is warning-clean. That is the checkpoint: if the
  refactor is wrong, it is wrong here, where there is still time.
- `--render-test`, `--menu-test` and `--interaction-test` are extended to address a pet by
  index. A test that can only see pet 0 will pass while the second cat is broken.
- `AppDelegate.swift` is 1297 lines before this step. It is expected to be substantially
  smaller after, and that is a goal of the step, not a side effect.

**11d — The second cat.**

- `config.json` gains `pets`, an array of `{ name, color, userName }`, **capped at two**.
  `speed`, `scale`, `screen` and `menuBarIcon` stay global — they describe the stage, not
  the actor.
- The legacy flat `color` and `userName` keys are read as pet 0 when `pets` is absent, so an
  existing `config.json` keeps working untouched. A `pets` array that is present but empty
  falls back the same way.
- The cap is two. This is not the plugin system §8.5 forbids: it is a second hardcoded cat,
  and a third is a feature request, not a config change.
- Each pet gets its own `BehaviorMachine` seed. Two cats that idle and sleep in lockstep
  look like one cat drawn twice.

**11e — The meeting.**

- `Meeting.swift` is pure, in `DockPetCore`, and owns the decision: given two pets' walk
  distances, their sprite sizes and the strip, have they met? It takes elapsed time as a
  parameter and its randomness is a seeded SplitMix64, exactly as `Behavior.swift` does.
  `AppDelegate` applies the decision; it does not make it.
- The sequence: overlap → both stop → both flip to face each other → both `sit` → pet A
  says a line → pet B replies after a short beat → both stand, **turn around**, and walk
  back the way they came.
- **They turn around rather than passing through.** Two pets that pass through each other
  overlap for several consecutive ticks and would re-trigger the meeting every one of them.
  Turning around separates them monotonically and needs no special-case suppression.
- A **cooldown** (60 s, in `Meeting.swift`, tested) stops them talking on every pass. A pair
  of cats that chat every fifteen seconds is noise by the second hour.
- The `meeting` phrase pool holds **pairs** — a line and its reply — not two independent
  draws. A reply that does not answer the line is worse than no reply.
- **No new art.** Facing is the horizontal flip M4 already does; `sit` already has a sheet.
  If this step needs a new sprite sheet, the step has been designed wrong.
- The M10 rule that the behaviour clock stops while a pet talks applies to both pets for the
  whole exchange, so neither wanders off mid-sentence.

**Verification.** Per §9, most of this is visual and I cannot show you my screen, so:
`MeetingTests` covers overlap, the cooldown, the pairing and the birthday date; `ConfigTests`
covers the `pets` array, the cap, and the legacy fallback; `--verbose` gains a per-pet line
so two cats can be told apart in the log; and `--interaction-test --shot=` renders both.

**If the deadline arrives first, cut 11e.** Two cats simply coexisting on the Dock is
already the thing that was being built. A ragged meeting is worse than no meeting.

**M12 — The kiss.** One meeting in five, and any time you ask for it, the two cats walk to
each other and kiss instead of trading a line.

- `Kiss.swift` is pure, in `DockPetCore`, and owns both halves that can be checked without a
  screen: `KissRoutine` — the phases and their clock — and `HeartDrift` — where each heart is
  and how solid, at a moment in the kiss. `AppDelegate` applies them; it decides nothing
  about timing itself.
- The sequence: **approach** (both walk to the point between them, facing each other) →
  **announce** (the left-hand cat says *"Bisou, bisou!"* in the ordinary bubble) → **kiss**
  (bubble down, four hearts rise and fade) → **declare** (hearts down, the left-hand cat says
  *"I love you"*) → **reply** (that bubble down, the right-hand cat answers *"And I love
  youu"*) → **part** (both turn around and walk away, still under the routine, so the overlap
  they are standing in is not read as a fresh meeting). One bubble at a time throughout, and
  never a bubble while the hearts are up — two cats standing against each other have room
  for one thing on screen above them.
- **Walking to a place is a new primitive**, `Walker.walk(toward:by:maxDistance:)`, and it is
  deliberately not built on `advance`: that method's whole job is turning round at the ends,
  which is the one thing a cat crossing the Dock to meet another must not do. It shares the
  bounded step and the clamp to the strip, because a stalled timer and a shrinking Dock are
  no less real during a kiss.
- **The approach has a ten-second ceiling.** The strip can move, shrink or vanish under the
  pair mid-walk, and a routine with no way to give up would hold both cats out of their own
  behaviour machine forever. An abandoned kiss says so in the log.
- **The animation timer must not suspend mid-kiss.** Both cats sit through the line and the
  hearts, so §6's "stationary" test would suspend the timer on the frame they sit down —
  taking the clock that ends the kiss with it. A kiss in progress is now something to
  animate; the other suspension reasons still win, and the kiss is released rather than left
  hanging when they do.
- **The hearts own a timer of their own**, for a second and a half, and invalidate it
  themselves. §6 is about steady-state wakeups; this adds none. They are a window of the
  pair's rather than of either cat's, for the reason the bubble is its own window (§7 M10):
  the pet's frame is the sprite's frame and every position check is written against it.
- **No new art.** The hearts are an emoji; the kiss itself is the M4 flip and the `sit` sheet
  M11 already uses. If this milestone needs a sprite sheet, it has been designed wrong.
- `kisses` is a new `config.json` key, defaulting to `true`, with a *Let them kiss* checkbox
  beside the second cat's coat. One flag governs both the spontaneous kiss and the click
  menu's *Kiss the other cat*: a menu item that still works after the feature is switched off
  is a bug report waiting to be filed.

**Verification.** Per §9: `KissTests` covers the steering, every phase transition, the
stalled-tick bound, the abandonment ceiling, the heart drift and the one-in-five rate;
`--verbose` gains `kiss=`, `kissClock=` and `hearts=` on the stage line, because a kiss is
otherwise six seconds of two cats whose only log line says `behavior=sit`; and `--kiss-test`
drives the whole sequence in-process, checking the line, the sitting, the hearts and the
parting, then puts the real config back.


## 8. Known traps

1. **Coordinate flipping.** §4b. Write it once, test it, never inline it.
2. **Reaching for the window list when `visibleFrame` suffices.** §4a is the default path.
3. **`Timer` in `.default` mode stalls** during menu tracking and live resize, freezing the
   pet at random. Schedule in `.common`.
4. **Retina.** A 32×32-point window showing a 32 px sprite at 2x backing scale looks wrong
   unless you are deliberate. Name variables `pxWidth` vs `ptWidth`.
5. **Don't build a plugin system.** One hardcoded dog.
6. **No sandboxing, entitlements, code signing, or notarisation.** Local personal build;
   unsigned is fine and I will right-click-open it. **[M8] amended this in practice:** the
   bundle *is* signed, with the self-signed local identity from `makecert.sh`, because the
   Accessibility grant is keyed to the signature and an ad-hoc one changes on every rebuild.
   **[M11]:** that identity exists on my machine only. On any other Mac the app is an app
   signed by an unknown authority — Gatekeeper will need an explicit override, and the
   Accessibility grant must be given again there. Neither is a bug; both need a human
   present the first time, which is why the hand-over is done in person.

### macOS 26 (Tahoe) specifics

7. **Window ownership was reshuffled in macOS 26.** Menu bar status items now report as
   owned by Control Center rather than their own apps. That is the menu bar, not the Dock —
   but it means "owner name == Dock" is an assumption to *verify against `PROBE.md`*, not
   to inherit from this document.
8. **The Liquid Glass Dock has a full-width glass bar** behind the tiles that persists even
   when the Dock is hidden. The Dock-owned window rect therefore may not match the visible
   tiles. M0 exists to settle this empirically.
9. **Tahoe has a known bug where the Dock vanishes after screensaver wake** until
   `killall Dock`. The §4d "return nil and go dormant" rule already covers it. Do not try
   to work around it.
10. **Dock magnification has a known 10–15 px popup jitter bug in Tahoe.** Apple's problem,
    not ours. Do not compensate for it.

## 9. Working agreement

- **Stop at each milestone and wait for my confirmation.** Do not chain M0→M6 in one go.
- **No placeholder implementations.** No `// TODO: implement`, no stubbed functions
  returning dummy values, no "you'll need to fill this in". If a milestone is too large,
  say so and propose a split — do not emit a skeleton and call it done.
- **You cannot see my screen.** Anything positional must be verifiable from `--verbose`
  output or a unit test. When success is purely visual, tell me exactly what to look for
  and what the log should say if it is correct.
- **State your uncertainty.** If you doubt that an API behaves as described here —
  especially §4b — say so and propose a probe rather than coding on an assumption.
- **`swift build` must be warning-clean** at every milestone.
- If you find a genuine error in this spec, edit `SPEC.md`, and tell me what changed and why.

## 10. Prior art

- `oneko` — the original cat-chases-cursor X11 toy; tiny, clean behaviour loop.
- Shimeji — desktop mascot with a richer action system; useful reference for what an idle
  pet should actually *do*, so M5 is not guesswork.

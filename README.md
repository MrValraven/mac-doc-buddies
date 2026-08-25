# DockPet

A tiny macOS background app that walks an animated pixel-art pet along the top edge of
the Dock. Purely decorative — nothing to click, nothing to configure to get started.

The pet walks back and forth across the Dock's strip, occasionally stopping to idle, sit
or sleep, and disappears when the Dock does (autohide, fullscreen apps, or a screen with
no Dock). It runs as an agent app: no Dock icon of its own, just an optional cat in the
menu bar.

- Swift + AppKit, Swift Package Manager, **no third-party dependencies**
- Deployment target macOS 13.0 (developed and measured on macOS 26.5 Tahoe)
- Animates at 10–12 fps and fully suspends its timer whenever the pet is stationary,
  hidden, or Low Power Mode is on

The full design — including what was measured about the Tahoe Dock rather than assumed —
lives in [SPEC.md](SPEC.md), with the raw probe output in [PROBE.md](PROBE.md).

## Build and run

```sh
./bundle.sh && open DockPet.app
```

`bundle.sh` does a release build, assembles `DockPet.app`, generates the app icon on
first run, and prints the bundle path. It's idempotent — re-run it after any change.

The build is signed with a local, self-signed identity (`./makecert.sh`, run once) rather
than left ad-hoc or unsigned. That matters because the Accessibility grant a Dock-aware pet
needs (see below) is recorded against the code signature: signed ad-hoc, that signature is a
hash of the compiled code, so it changes — and the grant silently drops — on every rebuild.
Signed with a certificate, it doesn't. On this machine that's invisible; you only notice it
when moving the app elsewhere, below.

To quit: use the menu bar item, or `killall DockPet`.

### Installing it on someone else's Mac

The `makecert.sh` identity exists only on the machine it was created on, so on any other Mac
DockPet is a **signed app from an unrecognised developer** — not unsigned, just not trusted
there. Two separate things follow from that:

- **Gatekeeper.** First launch needs a right-click → Open rather than a double-click. If
  macOS refuses outright instead of offering that, allow it explicitly in System Settings ›
  Privacy & Security — there's an "Open Anyway" button there right after the refusal.
- **Accessibility.** The grant is per machine, so it has to be given again there — the grant
  made while building doesn't travel with the app. DockPet asks for this itself: on first
  launch, if Accessibility isn't granted, a small window explains what the cat needs and why,
  with a button that opens the Accessibility pane directly *and* asks the system to prompt.
  Both, because the system prompt only ever appears while no answer has been recorded — after
  a Deny, or a dismissal, opening the pane is the only thing left that does anything. The same
  button lives in the menu bar as **Grant Accessibility…**. Once it's granted, the cat appears
  within about half a second — the same 500 ms poll that locates the Dock notices the grant on
  its own.

Because the grant follows the code signature rather than the exact build, it survives a later
update: rebuild and hand over a new `.app` signed with the same `makecert.sh` identity, and
Accessibility does not need to be granted a second time on that machine.

### Useful flags

Run the binary directly (`DockPet.app/Contents/MacOS/DockPet`) with:

| Flag | What it does |
| --- | --- |
| `--verbose` / `-v` | Logs the visible frame, window frame, current state and timer status once a second |
| `--render-test` | Renders the pet offscreen and asserts against the pixels; exits non-zero on failure |
| `--menu-test` | Drives pause/resume in-process and checks the timers and visibility |
| `--interaction-test` | Clicks the pet in-process, prints the clickable silhouette, and checks every prompt's bubble |
| `--dedication-test` | Clicks the pet in-process and checks the dedication says itself once a day and then stops |
| `--kiss-test` | Sends two cats to each other and checks every phase of the kiss, then restores your settings |
| `--scene-test` | Runs the birthday scene now, whatever the date, and checks every phase of it. Writes neither once-a-day stamp, so rehearsing it does not spend the real one |
| `--shot=PATH` | With `--settings-test` or `--interaction-test`, writes a PNG of what was rendered |

Tests are an executable target rather than XCTest (this machine has Command Line Tools
but no Xcode, so `swift test` can't run — see the M1 amendment in SPEC §2):

```sh
swift build          # must be warning-clean
swift run GeometryTests
```

## Configuration

Written with defaults on first launch to
`~/Library/Application Support/DockPet/config.json`. Every key is optional:

```json
{ "speed": 30, "scale": 2, "screen": null, "menuBarIcon": true, "color": "olive",
  "userName": null, "launchAtLogin": true, "birthday": null, "dedication": null,
  "kisses": true, "reactions": true, "attention": true }
```

- `speed`: points per second (clamped to `0 < speed <= 500`)
- `scale`: integer sprite scale (clamped to `1...8`)
- `screen`: `localizedName` of a display to pin the pet to, or `null` to follow the Dock
- `menuBarIcon`: show the menu bar item
- `color`: coat colour: `olive` (the default — a bicolour cat, roughly 60% olive coat
  to 40% white), `orange`, `grey`, `black`, `white`, `tuxedo` or `siamese`. The white
  comes from the sprite sheet's belly region rather than from the palette, so every coat
  is bicolour; `orange` is the palette the art is drawn in, and the only one that costs
  no recolour at load.
- `userName`: what the pet calls you in its speech bubbles. `null` falls back to the first
  name on your macOS account; set it to `""` to be greeted without a name
- `launchAtLogin`: start DockPet automatically when you log in, via `SMAppService`.
  Defaults to `true` — a pet that does not survive a reboot is gone within the week. A
  registration failure is logged and left off, never fatal
- `pets`: one or two cats to put on the Dock, each `{ "name", "color", "userName" }` (all
  optional, same rules as above). A third entry is dropped, with a log line saying so. When
  `pets` is absent or empty, the flat `color` and `userName` above describe the one cat that
  walks — so an existing `config.json` keeps working untouched
- `birthday`: `"MM-DD"`, or `null`. On that date the greeting pool becomes a birthday pool
  instead of the usual one
- `kisses`: whether two cats may kiss: both the occasional kiss when they meet and the
  **Kiss the other cat** menu item. Defaults to `true`; it governs nothing with one cat
- `dedication`: one line, said once, on the first click of the day, and not again until the
  date changes. `null` means nothing extra to say. Kept under 120 characters; longer is
  truncated and logged. On the birthday the scene says it instead, and that spends the day's
  dedication, so it is not repeated on the next click
- `reactions`: whether a cat may remark on the app you just brought to the front. Defaults
  to `true`; see **Reacting to apps** below
- `attention`: whether a cat turns to watch the pointer when it comes near the Dock.
  Defaults to `true`; see **Noticing the cursor** below

Bad values are clamped and logged, never fatal. Reload without restarting via the menu
bar's **Reload Sprites & Config**, or from a shell:

```sh
killall -HUP DockPet
```

## Clicking the pet

Click the cat and a small menu opens next to it:

| Prompt | What happens |
| --- | --- |
| Say hello | Greets you by name — "Hello, Tiago!" |
| Encourage me | One of six encouragements |
| Tell me a fact | A cat fact |
| Take a nap | Puts the pet to sleep |
| Kiss the other cat | Only with a second cat, and only while `kisses` is on — see **Two cats** below |
| Settings… | Opens the Settings window |

The pet answers in a speech bubble above its head, which takes itself down after a few
seconds — longer for a longer line. It stops walking while it talks, then carries on.

The name comes from `userName` in `config.json`, or the **Call me** field in Settings. With
no name set it uses the first name on your macOS account, so it works without configuring
anything; clear the field and every line still reads correctly without a name.

Hovering the cat turns the pointer into a hand, so it looks clickable — and since that
follows the same mask the click does, the cursor is also a live map of where the pet's
hit region actually is.

**Only the cat takes clicks.** The pet's window is a rectangle around a mostly-transparent
sprite, and it floats over the Dock. Clicks that land in that transparent margin go to the
Dock icon underneath, not to the pet — the window only accepts mouse events while the
cursor is genuinely over the art. `--interaction-test` prints the exact region:

```
....++++###############+++.......
....+++################++.......      # art   + click tolerance   . falls through
```

## Two cats

Give `pets` two entries and both walk the Dock:

```json
{ "pets": [ { "name": "Mochi", "color": "olive", "userName": "Sam" },
            { "name": "Tigre", "color": "tuxedo", "userName": "Alex" } ] }
```

Each cat has its own coat, its own name and its own behaviour clock, so they don't idle and
sleep in lockstep. Each also answers only for itself: clicking one greets you with *that*
cat's `userName`, not the other one's, and **Take a nap** puts only the clicked cat to sleep.

When their paths cross, both stop, turn to face each other, sit, and trade a line — one
speaks, the other replies a beat later. Then both stand, turn around and walk back the way
they came, rather than passing through each other. They then leave each other alone for a
minute, even though they'll pass each other again well before that — so a meeting stays an
occasional event rather than a running commentary.

### Kissing

Roughly one meeting in five becomes a kiss instead of a conversation, and you can ask for
one at any time from either cat's click menu — **Kiss the other cat**.

The two walk to the point between them, whatever else they were doing, and stop when they
touch. The left-hand one says *"Bisou, bisou!"*, the bubble comes down, and four hearts rise
and fade over the pair. Then the same cat says *"I love you"*, the other answers *"And I love
youu"*, and both turn around and walk away. About nine seconds end to end.

Set `"kisses": false` — or clear **Let them kiss** in Settings — to switch off both the
spontaneous kiss and the menu item. If the pair cannot reach each other within ten seconds
(a Dock that moved, a strip that shrank) the kiss is abandoned and both cats simply walk
on; the log says so.

Because the whole sequence takes six seconds of screen and leaves nothing behind, it has a
self-test of its own:

```sh
DockPet.app/Contents/MacOS/DockPet --kiss-test
```

It builds a second cat if you only have one, runs the kiss through every phase — checking
the line, the sitting, the hearts and the parting — and puts your settings back before it
exits. It needs Accessibility, like the pet itself.

## Being noticed

Four things the cats now do without being asked.

### The time of day

*Say hello* draws from the pool for the hour rather than one pool all day, so being greeted
at eight in the morning and at one in the morning are different events. The boundaries are
morning at 5, afternoon at 12, evening at 17, and night from 22 through 04:59.

On the birthday the birthday greeting still wins: the swap happens before the phrasebook is
asked, so the clock never reaches the hello pool that day.

### Holding the cat

**Press and hold** the cat and it sits and purrs for as long as you hold it, with a note
rising over its head. Let go and it carries on.

A quick click still opens the prompt menu, exactly as before. The threshold is 0.35 s, about
three times an ordinary click: below roughly 0.2 s a slow click would be swallowed, and much
above half a second the hold feels like nothing happened. The menu now opens on mouse *up*,
because until the button comes up there is no way to tell a click from the start of a hold.

### Noticing the cursor

Move the pointer near the Dock and the nearest cat stops, turns to face it, and sits a beat
later. It does **not** chase the pointer: a cat walking toward the cursor turns a decoration
into something moving under your hand while you work.

It gives up after 12 seconds however long the pointer stays, so a mouse that simply lives
near the Dock cannot freeze a cat in a sit all afternoon. Set `"attention": false` to switch
it off.

### Sleeping on a Dock icon

When a cat decides to sleep it walks to a Dock tile first and sleeps on top of that icon. A
random tile each time, and no setting: the variety is the point, and a configured favourite
would break silently the day that app left the Dock.

It gives up after 8 seconds of walking and sleeps where it stands. That is deliberate rather
than a failure: the Dock is wide, the cat walks at 30 pt/s, and a cat that drew a far tile
would otherwise spend its whole nap walking and never be seen asleep on anything. Without
Accessibility there are no tiles to read, so the cat sleeps where it stands, as it always did.

### Reacting to apps

Bring an app to the front and a cat occasionally says something about it. Sixteen apps are
covered out of the box, keyed on bundle identifier rather than name so a non-English macOS
still matches. An app with no entry gets silence rather than a generic line.

Rate limiting is the whole of this feature: about an hour between remarks of any kind, four
hours before the same app may speak again, and switching away and back within a few seconds
counts as one action. A cat that is kissing, talking, asleep or being petted says nothing,
and a suppressed remark costs no cooldown. Set `"reactions": false` to switch it off.

## The birthday

Set `birthday` to `"MM-DD"` and, on that morning, the first time the app finds the Dock, the
two cats stop what they are doing and walk to each other with nothing clicked. They sit, one
gives the birthday line, confetti falls and hearts rise over the pair, the other answers, and
then both turn round and walk away. About ten seconds end to end.

The answer is your `dedication` if you have written one, because that is the line actually
meant to be read. Saying it spends the day's dedication, so the first click of the morning
does not repeat it.

It happens once. The day is stamped in `state.json` when the scene begins rather than when it
ends, so a scene interrupted half way does not retry every half second for the rest of the day.

With one cat, or without Accessibility, there is no scene: it needs two cats and a strip to
walk on.

Because it is ten seconds of screen on one morning a year, it has a self-test:

```sh
DockPet.app/Contents/MacOS/DockPet --scene-test
```

It runs the whole scene now, whatever the date, checks all six phases, and asserts that it
wrote neither once-a-day stamp, so rehearsing it in August cannot silence the real one.

## Sprites

Sheets are **horizontal strips**: frames laid out left to right, all the same size, with a
transparent background. Each `.png` needs a sidecar `.json` next to it:

```json
{ "frameWidth": 32, "frameHeight": 32, "frameCount": 8, "fps": 10 }
```

Frame geometry is never hardcoded — it's read from that file.

Drop your art in either place (the bundle wins if both exist):

- `Resources/sprites/` in this repo — copied into the bundle by `bundle.sh`
- `~/Library/Application Support/DockPet/sprites/`: survives rebuilds; reachable from
  the menu bar's **Reveal Sprites Folder**

| File | Required | Notes |
| --- | --- | --- |
| `dog_walk.png` + `dog_walk.json` | yes | The only sheet the pet actually needs |
| `dog_idle.png` / `dog_sit.png` / `dog_sleep.png` | no | Each with its own sidecar, own `frameCount` and `fps` |

All sheets must share the same `frameWidth` and `frameHeight` — a mismatched one is
ignored with a log line naming both sizes, never a crash. A state with no sheet of its own
renders frame 0 of the walk sheet as a still pose, so the pet never blanks out.

Rendering is nearest-neighbour at integer scale only, and the return trip is drawn by
flipping the sheet horizontally — you never need a mirrored second sheet.

Until you supply art, a placeholder sheet is generated at first launch: 8 frames of a
cycling colour with a white "head" block and a sliding black block, which exist so
orientation and flipping are checkable from rendered pixels.

### Where to find sprites

Free and cheap pixel-art sheets that suit a small side-on walking animal. Check each
asset's own licence before shipping anything beyond your own desktop.

**Asset libraries**

- [itch.io — free pixel-art game assets](https://itch.io/game-assets/free/tag-pixel-art) —
  the biggest pool; search "cat sprite sheet", "dog walk cycle", "pet". Filter by licence.
- [OpenGameArt.org](https://opengameart.org/art-search-advanced?field_art_tags_tid=sprite%20sheet) —
  CC0 / CC-BY / GPL, long-established, searchable by licence.
- [Kenney.nl](https://kenney.nl/assets) — public domain (CC0), very consistent style,
  large packs including animal and character sheets.
- [Liberated Pixel Cup (LPC)](https://lpc.opengameart.org/) — CC-BY-SA / GPL sets built to
  a shared spec, so frames line up across packs.
- [Craftpix free assets](https://craftpix.net/freebies/) — free tier with a permissive
  licence for personal use; lots of animal walk cycles.
- [Game-icons / Piskel gallery](https://www.piskelapp.com/explore) — community sprites,
  many small animals.

**Inspiration and prior art** (see SPEC §10)

- [oneko](https://github.com/eliot-akira/oneko) — the classic cat-chases-cursor toy; its
  sprite sheet is a good size reference for a Dock-scale pet.
- [Shimeji](https://kilkakon.com/shimeji/) — desktop mascots with rich idle actions;
  useful for deciding what a pet should *do* while stationary.

**Making your own**

- [Aseprite](https://www.aseprite.org/) — the standard pixel-art/animation editor (paid,
  open source); exports horizontal strips plus a JSON sidecar directly.
- [Piskel](https://www.piskelapp.com/) — free, browser-based, exports sprite sheets.
- [LibreSprite](https://libresprite.github.io/) — free fork of an older Aseprite release.

A 32×32 frame at `scale: 2` gives a 64 pt pet on the Dock edge, which is roughly Dock-tile
height — a good starting point.

## Layout

```
Sources/DockPetCore/   pure logic, no AppKit — geometry, behaviour, sheet metadata, config
Sources/DockPet/       the executable — window, view, sprite loading, Dock locator, menu bar
Tests/DockPetTests/    the GeometryTests executable and its hand-rolled assertion harness
Resources/sprites/     your art goes here
dockprobe.swift        standalone Dock/screen diagnostic (`swift dockprobe.swift`)
makeicon.swift         standalone icon generator, run by bundle.sh when the icon is missing
```

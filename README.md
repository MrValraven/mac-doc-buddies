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

The build is unsigned and unnotarised on purpose (local personal build), so the first
launch needs a right-click → Open.

To quit: use the menu bar item, or `killall DockPet`.

### Useful flags

Run the binary directly (`DockPet.app/Contents/MacOS/DockPet`) with:

| Flag | What it does |
| --- | --- |
| `--verbose` / `-v` | Logs the visible frame, window frame, current state and timer status once a second |
| `--render-test` | Renders the pet offscreen and asserts against the pixels; exits non-zero on failure |
| `--menu-test` | Drives pause/resume in-process and checks the timers and visibility |
| `--interaction-test` | Clicks the pet in-process, prints the clickable silhouette, and checks every prompt's bubble |
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
{ "speed": 30, "scale": 2, "screen": null, "menuBarIcon": true, "color": "orange",
  "userName": null }
```

- `speed` — points per second (clamped to `0 < speed <= 500`)
- `scale` — integer sprite scale (clamped to `1...8`)
- `screen` — `localizedName` of a display to pin the pet to, or `null` to follow the Dock
- `menuBarIcon` — show the menu bar item
- `color` — coat colour: `orange`, `grey`, `black`, `white`, `tuxedo` or `siamese`
- `userName` — what the pet calls you in its speech bubbles. `null` falls back to the first
  name on your macOS account; set it to `""` to be greeted without a name

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

## Sprites

Sheets are **horizontal strips**: frames laid out left to right, all the same size, with a
transparent background. Each `.png` needs a sidecar `.json` next to it:

```json
{ "frameWidth": 32, "frameHeight": 32, "frameCount": 8, "fps": 10 }
```

Frame geometry is never hardcoded — it's read from that file.

Drop your art in either place (the bundle wins if both exist):

- `Resources/sprites/` in this repo — copied into the bundle by `bundle.sh`
- `~/Library/Application Support/DockPet/sprites/` — survives rebuilds; reachable from
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

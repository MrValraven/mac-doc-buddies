# DockPet hand-over checklist

For the birthday on **2026-08-27**. Everything here needs a human — none of it could be
verified by any agent, because Accessibility is not granted in the environment they run in,
so `DockLocator.locate()` returns `.accessibilityNotGranted` and **no cat is ever placed on
screen**. The code is reviewed and tested; it has never been watched.

Work top to bottom. The first three are the ones that would actually ruin the day.

---

## 1. Watch the onboarding window. Ten minutes, and the highest-value check here.

This is the first thing Philippine will see, and nobody has ever seen it render. It has a
`fittingSize`-derived height and a 380 pt width constraint that were verified numerically
but never visually.

```sh
./bundle.sh
```

Then: System Settings → Privacy & Security → Accessibility → **remove DockPet** (or untick
it). Launch the app.

- [ ] The window appears, and the text **wraps** rather than being clipped by the window edge
- [ ] It says what the cat is in one sentence, without looking like an error
- [ ] The button opens System Settings at the Accessibility pane
- [ ] After granting, the status line turns green and reads *Found your Dock*
- [ ] The window closes itself a couple of seconds later
- [ ] The cat appears
- [ ] Relaunch with the grant already in place → **no window at all**

**Also test the unhappy path**, because it is the one that was broken until the final fix:
revoke the grant again, launch, and this time **click Deny** or close the window. Then
reopen the app and press the button again. It must still open System Settings. (Before the
fix, the button went permanently dead after the first dismissal, while the status line still
said "Waiting for permission…" — indistinguishable from a broken app.)

## 2. Watch two cats meet. Nobody has seen this either.

`considerMeeting()` has **no integration test** — the coordinator underneath it is
thoroughly tested, but the wiring that drives it is not. A regression that faced both cats
the same way, reversed one walker, or showed the reply on the wrong cat would pass every
test in the project.

Set a two-cat config with a high speed so a meeting happens soon:

```json
{ "speed": 200, "scale": 2, "menuBarIcon": true,
  "pets": [ { "name": "Mochi", "color": "orange", "userName": "Philippine" },
            { "name": "Tigre", "color": "tuxedo", "userName": "Tiago" } ] }
```

`killall -HUP DockPet`, then watch:

- [ ] Two cats, **different coats**, at opposite ends of the Dock at launch — not stacked
- [ ] They move independently, not in lockstep
- [ ] On meeting: both stop, **face each other**, sit
- [ ] One speaks; the other replies about 1.5 s later — **one bubble at a time**, not two
      overlapping
- [ ] Both turn around and walk back the way they came
- [ ] They do **not** meet again for at least a minute, even passing each other several times
- [ ] Click each cat → each greets you with **its own** `userName`
- [ ] *Take a nap* on the second cat → the **second** cat sleeps

Then put `speed` back to `30`.

## 3. Test a first launch on a machine with no config

This was a genuine silent-death bug found in the final review, and it is exactly the
hand-over scenario — the app exited with `exit(1)` and no window at all, and the *second*
launch worked, so retrying hides it.

```sh
mv ~/Library/Application\ Support/DockPet ~/Desktop/DockPet-backup
open DockPet.app
```

- [ ] The cat appears (or the onboarding window does) — **it does not silently die**
- [ ] `~/Library/Application Support/DockPet/config.json` is created

```sh
rm -rf ~/Library/Application\ Support/DockPet
mv ~/Desktop/DockPet-backup ~/Library/Application\ Support/DockPet
```

---

## 4. Write her config — do this LAST

Do this **after** the last self-test run. `--settings-test` writes a placeholder birthday and
dedication into the real `config.json` and restores them at the end; if it bails early it
does not restore. Quit DockPet before hand-editing, or the running app will overwrite you.

```json
{
  "speed": 30, "scale": 2, "screen": null, "menuBarIcon": true, "launchAtLogin": true,
  "pets": [
    { "name": "…",  "color": "…", "userName": "Philippine" },
    { "name": "…",  "color": "…", "userName": "Philippine" }
  ],
  "birthday": "08-27",
  "dedication": "…one line, said on the first click of each day…"
}
```

- [ ] `birthday` is `"08-27"` — **`MM-DD`, not `DD-MM`**
- [ ] `dedication` is under 120 characters (longer is truncated with a log line)
- [ ] Both `userName`s are hers — on **her** machine both cats should call *her* by name
- [ ] The two coats are different
- [ ] `killall -HUP DockPet`, click a cat → the **first** click of the day says the dedication
- [ ] Click again → an ordinary reply
- [ ] Temporarily set `birthday` to today, `killall -HUP DockPet`, click → a birthday line.
      Set it back to `08-27` afterwards.

## 5. Install on her Mac — you are doing this in person, which removes most of the risk

The app is signed with the **local self-signed identity** from `makecert.sh` (SPEC §8.6 as
amended). No other Mac trusts that certificate, so:

- [ ] Copy `DockPet.app` across (or run `install.sh` there — it builds from source and needs
      the Swift toolchain, so copying the built app is simpler)
- [ ] **Right-click → Open**, then **Open** again at the warning
- [ ] If macOS refuses outright: System Settings → Privacy & Security → **Open Anyway**
- [ ] Grant Accessibility when the onboarding window asks
- [ ] Confirm the cat appears within about half a second of the grant
- [ ] Reboot her Mac once and confirm the cat comes back by itself (`launchAtLogin`)

The Accessibility grant is keyed to the code signature, so it survives rebuilds **as long as
you rebuild with the same identity**. If you ever regenerate the certificate, she has to
grant it again.

---

## Two things I did not fix, that are yours to decide

**The README documents a coat that does not exist on this branch.** `README.md` describes
`olive` as the default coat, but `CatPalette` has no `olive` here — that palette lives only
in your other Claude session's uncommitted work. Anyone following the README and setting
`"color": "olive"` gets a log line saying the value is out of range, and an orange cat.
Either land that session's work, or revert those README lines. I did not overwrite its prose.

**A fresh clone does not build clean art.** `Resources/sprites/` is gitignored, so the art is
regenerated by `makesprite.swift` on a fresh checkout — and the committed `makesprite.swift`
produces sprites whose colours no longer match the committed `CatPalette.base`. On this
machine it does not show, because the art on disk was generated by the modified version.
`--render-test` fails 14 of 44 on a clean clone as a result, identically at the M10 baseline,
so it is not from this milestone. It clears when that session commits a matching
generator/palette pair. **The gift itself is unaffected** — you hand over the built `.app`,
which bundles the art already on disk.

## Worth doing after the birthday, not before

- A `--meeting-test` that plants two pets at overlapping distances on a synthetic strip and
  asserts the whole sequence. `considerMeeting()` is the headline feature and the only major
  piece with no integration coverage.
- `resetToDefaults()` still rebuilds the config and re-copies `birthday`/`dedication` by
  hand, so a *future* gift-layer key would be wiped by the Reset button. `currentValues()`
  already has the safe shape; make Reset match it.
- The menu bar's status line describes only the first cat.
- One global mouse monitor per pet rather than one app-level monitor fanning out.

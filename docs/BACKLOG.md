# DockPet Product Backlog

Ideas beyond M12, with what each one is, what it cost, and where it stands.

**Last updated:** 2026-08-25, after M13 shipped items 8 through 14.

**The constraint everything is sorted by:** `config.json` has `"birthday": "08-27"`. This
file was first written on 2026-08-25, two days out. Tier 0 and Tier 1 are what can land
before that date. Tier 2 and Tier 3 are what keeps the app alive after it.

**Cost** is S / M / L, judged against what already exists in the repo, not in the abstract.

**Status** is one of:

| Status | Meaning |
| --- | --- |
| `Done` | Shipped, and seen working on a real Dock. |
| `Built, unseen` | Shipped and unit tested, but never yet watched running. See the note below. |
| `Ready` | Nothing to build. A config edit or a rehearsal. Just not done yet. |
| `Proposed` | Wanted, not yet designed or approved. |
| `Deferred` | Deliberately not now, with a reason. |
| `Needs decision` | Blocked on a call only the owner can make (money, art, taste). |

> **Why `Built, unseen` exists.** There is no DockPet signing identity in the keychain, so
> `bundle.sh` signs ad-hoc, and an ad-hoc signature is a hash of the compiled code. It
> changes on every rebuild, and the Accessibility grant is recorded against it, so the grant
> drops every time. Without the grant the app cannot find the Dock's tiles, and anything
> that needs a strip to walk on cannot be exercised at all.
>
> The fix is the one-time step already in the README:
>
> ```sh
> ./makecert.sh     # creates the local identity, once
> ./bundle.sh       # re-sign with it
> open DockPet.app  # then grant Accessibility in System Settings
> ```
>
> This is not only a testing problem. Until it is done, **every rebuild between now and the
> 27th silently un-grants the app**, and the README's handover promise (rebuild, hand over a
> new `.app`, no second grant needed) does not hold on her Mac either.

---

## What M13 shipped

Thirteen commits, `6cbaf7b` through `198ff39`. Unit checks went from 572 to **1414**, and
`swift build` stayed warning clean throughout.

| Commit | What |
| --- | --- |
| `6cbaf7b` | `PetOccupancy`: one tested table deciding which feature owns a cat |
| `22c5fc6` | `BirthdayScene`, written as `KissRoutine`'s sibling |
| `98c9409` | Confetti, as `HeartDrift`'s sibling that falls |
| `af7ea0c` | Hold the cat and it purrs |
| `59e3162` | Time-of-day greetings |
| `16f64f7` | Napping on a Dock icon |
| `1ce07f1` | Reacting to the frontmost app |
| `0269d05` | The cats notice the cursor |
| `0db2157` | Wiring the scene, plus `--scene-test` |
| `e0982b9` | Wiring the cursor, the nap spot and the reactions |
| `198ff39` | README and SPEC |

**The thing that had to come first.** Through M12 exactly one feature could take a cat away
from its behaviour machine, and one guard said so: `guard kiss == nil`. M13 adds four more
claimants that can want the same cat in the same tick. As guards that is a pile of
`kiss == nil && !isTalking && ...` across five call sites, each failing *silently* when it
disagrees with the others. `PetOccupancy` holds the priority order instead, and it is tested
rather than conventional. Everything below plugs into it.

---

## Tier 0: no code at all

| # | Item | Cost | Status |
| --- | --- | --- | --- |
| 1 | Write the `dedication` line | none | `Ready` |
| 2 | Name both cats | none | `Ready` |
| 3 | Set `userName` back to Philippine | none | `Ready`, and newly urgent |
| 4 | Grant Accessibility, and rehearse on her Mac | none | `Ready`, blocks everything |

### 1. Write the `dedication` line: `Ready`

Still `null` in the live config. The feature is built, tested, shipping, and saying nothing.

M13 raised the stakes on this one: the birthday scene now says the dedication as the second
cat's answer, because that is the line actually meant to be read. With none set, the scene
falls back to a second stock birthday line. **Writing this is the single highest-value edit
available, and it costs one line of JSON.**

### 2. Name both cats: `Ready`

`pets[0]` and `pets[1]` still have no `name`. The second cat answers as nobody.

### 3. Set `userName` back to Philippine: `Ready`, newly urgent

**This regressed during the session.** The live config no longer has `userName` at any level,
so the fallback kicks in and every greeting, every encouragement and the whole birthday scene
will address her as **Tiago**, the macOS account's first name.

```json
"pets": [ { "name": "...", "color": "orange", "userName": "Philippine" },
          { "name": "...", "color": "olive",  "userName": "Tiago" } ]
```

### 4. Grant Accessibility, and rehearse on her Mac: `Ready`

See the box at the top. Run `makecert.sh`, rebuild, grant, then:

```sh
DockPet.app/Contents/MacOS/DockPet --scene-test
```

Until that passes, nobody has watched the birthday scene run.

---

## Tier 1: shipped in M13

| # | Item | Cost | Status |
| --- | --- | --- | --- |
| 5 | Special dates, generalized | S | `Proposed`, not built |
| 6 | A letter, one line a day | S | `Proposed`, not built |
| 7 | French lines | S | `Proposed`, not built |
| 8 | Time-of-day awareness | S | `Done` |
| 9 | The birthday morning scene | M | `Built, unseen` |
| 10 | Hold to pet | M | `Done` |
| 11 | Confetti | S | `Built, unseen` |

### 5. Special dates, generalized: `Proposed`, cost S

Not built. Still the best value per line in this file, and now cheaper than when it was
written: `BirthdayScene.shouldRun` already takes the date as a parameter and stamps a day in
`state.json`, so a list of dates is a change to what feeds it rather than new machinery.

### 6. A letter, one line a day: `Proposed`, cost S

Not built. Also cheaper now: `StateStore` gained `lastSceneDay` alongside `lastGreetedDay`,
so the once-a-day pattern has two users and an obvious third.

### 7. French lines: `Proposed`, cost S

Not built. The phrasebook was warmed up separately during the session, so the pools are
larger and better than they were, but they are still English.

### 8. Time-of-day awareness: `Done`

*Say hello* draws from the pool for the hour. Morning at 5, afternoon at 12, evening at 17,
night from 22 through 04:59, both sides of every boundary tested plus the midnight rollover.
Pools are deliberately equal in size so the existing reachability check behaves identically
at any hour, and the suite is run under three timezones to prove it.

The birthday greeting still wins on the day: the swap happens before the phrasebook is asked,
so the clock never reaches the hello pool.

One latent bug fixed on the way: `"{name}! I was hoping you'd click."` rendered as
`"! I was hoping you'd click."` with no name, because `render` only eats a *comma* after a
leading slot.

### 9. The birthday morning scene: `Built, unseen`

Six phases: approach, gather, announce, celebrate, wish, part. Both cats walk to each other
with nothing clicked, sit, one gives the birthday line, confetti and hearts go up together,
the other answers with the dedication, both walk away. About ten seconds.

Written as `KissRoutine`'s sibling so it inherits the four properties the kiss already got
right: a bounded step, one phase per call, a ceiling on the approach, and both endings
spelled `.done` with the abandoned one flagged separately.

The day is stamped when the scene *begins*, not when it ends. A scene interrupted half way
has still had its turn, and retrying every 500 ms for the rest of her birthday would be far
worse than missing it once.

**Unseen.** 31 unit checks cover all six phases, the abandon path and the once-a-day gate,
and `--scene-test` exists to run the whole thing on any date. It has never run, because of
the Accessibility blocker. This is the deadline-critical item and the one still unproven.

### 10. Hold to pet: `Done`

Press and hold for 0.35 s and the cat sits and purrs. The risk was never the purr, it was
breaking the app's only interaction: the menu had to move to mouse *up*, because until the
button comes up a click and a hold are the same event. Two sweeps pin both halves, 70 samples
below the threshold that must all open the menu and 1000 across ten seconds that must never.

### 11. Confetti: `Built, unseen`

24 pieces over 2.4 s, five flat inks, seeded so a given burst is reproducible frame for
frame. Real gravity was tried and rejected: it left pieces hanging at the top and whipping
past the cats. Only reachable through the birthday scene, so it inherits that item's
unseen status.

---

## Tier 2: three of six shipped in M13

| # | Item | Cost | Status |
| --- | --- | --- | --- |
| 12 | The cats notice the cursor | M | `Built, unseen` |
| 13 | Sleeping on a Dock icon | M | `Built, unseen` |
| 14 | Reacting to apps | M | `Done` |
| 15 | A third cat / a kitten | L | `Deferred` |
| 16 | A small "us" panel | M | `Proposed` |
| 17 | Uninstall menu item | S | `Proposed` |

### 12. The cats notice the cursor: `Built, unseen`

Turn and watch, never chase. Chasing was rejected outright: it turns a decoration into
something moving under her hand while she works.

Hysteresis turned out to be three separate problems needing three separate fixes: which cat
(stickiness, 24 pt), in or out of the zone (asymmetric bounds, 120 in / 150 out), and which
way it faces (a 12 pt dead zone, the easy one to miss). Each has a test that jiggles the
pointer across the exact boundary 60 times and asserts zero transitions, and each was
confirmed load-bearing by zeroing its margin and watching 30, 59 and 30 flips appear.

A 12 second episode ceiling regardless of how long the pointer stays, so a mouse that simply
lives near the Dock cannot freeze a cat in a sit all afternoon.

Switchable with `"attention": false`.

### 13. Sleeping on a Dock icon: `Built, unseen`

A random tile each time, no config key. `DockTiles` grew `tileFrames`, and `measure` and
`inspect` were folded onto one shared Accessibility read; the nil contract is unchanged, so
an ungranted app behaves exactly as before.

The 8 second ceiling is not the kiss's 10 and not for the kiss's reason. Crossing the
measured 748 pt Dock at 30 pt/s takes 25 s, longer than the longest sleep dwell, so without a
ceiling a cat that drew a far tile would spend its whole nap walking and never be seen asleep
on anything. Roughly half of naps reach their tile; the rest sleep where they stand.

### 14. Reacting to apps: `Done`

Sixteen apps, 48 lines, keyed on bundle identifier rather than display name because display
names are localised and a French macOS would match nothing.

Rate limiting is the correctness of this feature rather than a nicety, and it is most of the
tests: an hour between remarks of any kind, four hours per app, and a six second return
window so switching away and back is one action. A suppressed remark spends no cooldown, so
the next switch is judged as if it never happened.

Switchable with `"reactions": false`.

### 15. A third cat / a kitten: `Deferred`, cost L

Unchanged, and now slightly cheaper: `PetOccupancy` is written for N cats rather than two.
The pair logic in `Meeting`, `Kiss` and the new `SceneDirector` is still written for exactly
two, so this is still a real refactor and still not a two-days-out job.

### 16. A small "us" panel: `Proposed`, cost M

Unchanged. `StateStore` now holds two day stamps, so there is a little more to show.

### 17. Uninstall menu item: `Proposed`, cost S

Unchanged.

---

## Tier 3: blocked on a decision

| # | Item | Cost | Status |
| --- | --- | --- | --- |
| 18 | Notarization | $99/yr + ~1 day | `Needs decision`, and more pressing |
| 19 | Anything needing new sprite art | L | `Deferred` |
| 20 | A photo in the bubble | L | `Deferred` |

### 18. Notarization: `Needs decision`, and more pressing than it was

The recommendation stands for Thursday: do not pay, sit next to her for the sixty seconds.

But the signing situation is worse than this entry assumed. The app is not merely "signed by
an unrecognised developer", it is **ad-hoc signed**, because `makecert.sh` has never been run
here. That is a different and worse problem, and it is free to fix. See the box at the top.

### 19. Anything needing new sprite art: `Deferred`

Unchanged, and M13 held the line: seven features, no new sheet. The confetti is drawn
rectangles and the purr indicator is a text glyph, both for this reason.

### 20. A photo in the bubble: `Deferred`, cost L

Unchanged.

---

## Known gaps left open

Small, deliberate, and worth writing down rather than rediscovering.

- **No Settings UI** for `reactions` or `attention`. Config file only. Seven new checkboxes
  is a day better spent on the scene working.
- **`HeartsWindow.dismiss()` does not run its `onFinish`**, while the new
  `ConfettiWindow.dismiss()` does. A real gap in the hearts, but nothing in the kiss depends
  on it, and this is not the week to touch a working sequence.
- **`CursorWatcher` runs its own global mouse monitor** alongside the one each
  `PetInteraction` already has. Built that way so two agents could work in parallel without
  fighting over one file. Worth consolidating; costs nothing today.
- **The README still has 42 em dashes** in sections M13 did not touch. A full pass is worth
  doing and is not worth doing two days before the birthday.

---

## Recommended order from here

1. **Now, and it is four lines of JSON:** items 1, 2 and 3. The dedication, the cats' names,
   and `userName` back to Philippine. Without number 3 the scene calls her Tiago.
2. **Then item 4**, which is the real blocker: `makecert.sh`, rebuild, grant Accessibility,
   and run `--scene-test` until it passes. Nothing about the 27th is proven until it does.
3. **Then, if there is an evening left:** items 5 and 7. Both are pure logic, test first, and
   each ships alone.

That leaves the 27th with a scene somebody has actually watched, and a mechanism that keeps
producing surprises long after it. Thursday is not the goal; it is the deadline.

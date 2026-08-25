# DockPet — Product Backlog

Ideas beyond M12, with what each one is, what it would cost, and where it stands.

**The constraint everything is sorted by:** `config.json` has `"birthday": "08-27"`. This
file was written on 2026-08-25 — two days out. Tier 0 and Tier 1 are what can land before
that date. Tier 2 and Tier 3 are what keeps the app alive after it.

**Cost** is S / M / L, judged against what already exists in the repo, not in the abstract.

**Status** is one of:

| Status | Meaning |
| --- | --- |
| `Ready` | Nothing to build — a config edit or a rehearsal. Just not done yet. |
| `Proposed` | Wanted, not yet designed or approved. |
| `Deferred` | Deliberately not now, with a reason. |
| `Needs decision` | Blocked on a call only the owner can make (money, art, taste). |
| `Done` | Shipped. |

---

## Tier 0 — no code at all

| # | Item | Cost | Status |
| --- | --- | --- | --- |
| 1 | Write the `dedication` line | — | `Ready` |
| 2 | Name both cats | — | `Ready` |
| 3 | Rehearse the birthday | — | `Ready` |
| 4 | Rehearse on her Mac | — | `Ready` |

### 1. Write the `dedication` line — `Ready`

`dedication` is currently `null` in the live config. The feature is built, tested and
shipping, and saying nothing. One sentence, said on the first click of each day, not
repeated until the date changes. The highest-value line in the app; it costs zero code.

### 2. Name both cats — `Ready`

`pets[1]` has no `name` and no `userName`. The second cat answers as nobody. Naming the
pair is what turns "an app" into "us".

### 3. Rehearse the birthday — `Ready`

Temporarily set `birthday` to today, click, confirm the birthday pool replaces the greeting
pool, then set it back. Do not discover on the 27th that the date match is off by a
timezone.

### 4. Rehearse on her Mac — `Ready`

Gatekeeper right-click -> Open, then the Accessibility grant. This is the highest-risk part
of the whole gift and it is not a feature — it is a dress rehearsal. See README,
*Installing it on someone else's Mac*.

---

## Tier 1 — buildable before the 27th, each ships standalone

| # | Item | Cost | Status |
| --- | --- | --- | --- |
| 5 | Special dates, generalized | S | `Proposed` — recommended first |
| 6 | A letter, one line a day | S | `Proposed` |
| 7 | French lines | S | `Proposed` |
| 8 | Time-of-day awareness | S | `Proposed` |
| 9 | The birthday morning scene | M | `Proposed` |
| 10 | Hold to pet | M | `Proposed` |
| 11 | Confetti | S–M | `Proposed` |

### 5. Special dates, generalized — `Proposed`, cost S

Replace the single `birthday: "MM-DD"` with a list:
`dates: [{ "on": "10-14", "say": "Two years today." }]`. Pure logic in `Phrasebook` /
`Meeting`, tested against a passed-in date like the existing birthday match, no AppKit.

Why it goes first: it is the difference between a gift that peaks on Thursday and one that
ambushes her on an anniversary next April. Everything seasonal later — a Christmas hat, her
name day — becomes config rather than code.

### 6. A letter, one line a day — `Proposed`, cost S

`messages: ["...", "...", ...]`. The pet says the next one on the first click of each day,
in order, and stops when the list runs out. `dedication` already implements the once-a-day
mechanic and `lastGreetedDay` already persists in `StateStore`; this is that plus an index.

Effect: a thirty-day love letter delivered by a cat.

### 7. French lines — `Proposed`, cost S

The kiss already says *"Bisou, bisou!"* and it is the most charming string in the app. A
French pool, or a `language` key. Pure data in `Sources/DockPetCore/Phrasebook.swift`, zero
risk. The highest emotion-per-line-of-code available anywhere in this file.

### 8. Time-of-day awareness — `Proposed`, cost S

"Bonjour" before eleven, "It's 1am, {name}" after midnight. A pure function of the hour,
tested against a passed-in date exactly as the birthday match is. The cheapest way to make
the pet feel alive rather than random.

### 9. The birthday morning scene — `Proposed`, cost M

On 08-27, first launch of the day: both cats stop whatever they are doing, walk to centre,
hearts, and the birthday line — with nothing clicked. Reuses `KissRoutine`'s approach
steering and `HeartsWindow` wholesale. A new trigger on existing machinery, not new
machinery.

This is the "moment", if there is to be one.

### 10. Hold to pet — `Proposed`, cost M

Press and hold the cat: it sits, and a small heart or note bubble appears for as long as
the hold lasts. `PetInteraction` already owns the click and `AlphaMask` already owns the hit
region. Turns a menu into a relationship.

### 11. Confetti — `Proposed`, cost S–M

`HeartsWindow` is already a transparent, rising, fading particle window over the pair. A
confetti variant for the birthday is close to a copy with a different particle. It is cheap
only because the hearts were built first.

---

## Tier 2 — the week after; what stops this being a three-day toy

| # | Item | Cost | Status |
| --- | --- | --- | --- |
| 12 | The cats notice the cursor | M | `Proposed` |
| 13 | Sleeping on a Dock icon | M | `Proposed` |
| 14 | Reacting to apps | M | `Proposed` — needs a hard cap |
| 15 | A third cat / a kitten | L | `Deferred` |
| 16 | A small "us" panel | M | `Proposed` |
| 17 | Uninstall menu item | S | `Proposed` |

### 12. The cats notice the cursor — `Proposed`, cost M

When the pointer enters the Dock strip, the nearest cat turns to face it, briefly.
`KissRoutine` already proves the walker can be steered to an arbitrary point. This is the
oneko instinct (SPEC §10) and it is the thing that makes people keep a desktop pet
installed.

### 13. Sleeping on a Dock icon — `Proposed`, cost M

`DockTiles` already hands back per-tile rects (SPEC §4b, M8). A cat that naps *on top of
Spotify* is specific in a way that napping at a random x is not.

### 14. Reacting to apps — `Proposed`, cost M

`NSWorkspace` frontmost-app notifications; no new permission beyond what M8 already needs.
"Figma again?" when she opens Figma.

Risk, and the reason this is not Tier 1: it tips from charming into surveillance-y very
fast. Any design must cap it hard — once an hour at most, and only over a handful of apps
named in config.

### 15. A third cat / a kitten — `Deferred`, cost L

Today the third `pets` entry is dropped with a log line. A kitten trailing one parent is the
obvious emotional extension.

Deferred because the pair logic in `Meeting.swift` and `Kiss.swift` is written for exactly
two, and generalizing it is a real refactor — not something to start two days out.

### 16. A small "us" panel — `Proposed`, cost M

Kisses counted, naps taken, days together. `StateStore` already exists to hold it. Pure
upside, no risk to the pet loop.

### 17. Uninstall menu item — `Proposed`, cost S

Removes the login item registration and the app, cleanly. It is manners, and it is what
makes the app safe to install on someone else's machine.

---

## Tier 3 — blocked on a decision, not on time

| # | Item | Cost | Status |
| --- | --- | --- | --- |
| 18 | Notarization | $99/yr + ~1 day | `Needs decision` |
| 19 | Anything needing new sprite art | L | `Deferred` |
| 20 | A photo in the bubble | L | `Deferred` |

### 18. Notarization — `Needs decision`

On any Mac that is not the build machine, DockPet is a signed app from an *unrecognised*
developer: right-click -> Open, then a manual Accessibility grant. A paid Apple Developer ID
removes the frightening dialog entirely.

Recommendation for the 27th: do not. Sit next to her for the sixty seconds it takes.
Revisit only if the app is still installed a month later.

### 19. Anything needing new sprite art — `Deferred`

A wrapped gift box on the Dock that opens; a party hat; kitten frames. All good, all gated
on art that does not exist.

SPEC §7 M12 already states the rule: *if this milestone needs a sprite sheet, it has been
designed wrong.* Hold that line through Thursday.

### 20. A photo in the bubble — `Deferred`, cost L

`BubbleWindow` draws text. Images mean scaling, aspect handling and a second content path
through the bubble geometry. Real work, not a Tier 1 flourish.

---

## Recommended order

1. **Tonight:** 1, 2, 3, 4 — config only, about an hour including the rehearsal on her Mac.
2. **Tomorrow:** 5, 7, 8 — all three pure-logic, test-first, warning-clean, and each ships
   alone if the evening runs out.
3. **Only if tomorrow goes fast:** 9.

That leaves the 27th with a real moment, a cat that speaks her language, and a mechanism
that keeps producing surprises long after the birthday — which is the actual product goal.
Thursday is not.

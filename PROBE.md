# PROBE.md — measured Dock/screen geometry (SPEC.md §7, M0)

Machine: MacBook Pro, macOS 26.5.2 (25F84), two displays
(Built-in Retina 1512×982 @2x = primary at origin 0,0; 27G2G4 1920×1080 @1x at x=1512, y=−98).

Captured by `swift dockprobe.swift --deep`. Each configuration was applied by writing
`com.apple.dock` defaults *while the Dock process was dead*, then restarting it — the
Dock flushes its own prefs on quit, so a plain `defaults write && killall Dock` gets
clobbered and the change lands one restart late. Every run below was verified by reading
the pref back before probing.

Original settings were exported to `dock-backup.plist` and restored afterwards.

---

## Run 1 — Dock bottom, autohide off, magnification off (baseline)

```

=== DOCKPROBE ===================================================
date            : 2026-08-25 13:48:16
os              : Version 26.5.2 (Build 25F84)
host            : tiagos-macbook-pro.local
low power mode  : false

=== DOCK PREFERENCES (com.apple.dock) ===========================
orientation     : bottom (default)
autohide        : unset (false)
magnification   : unset (false)
tilesize        : 54.0
largesize       : unset

=== SCREENS (2) =================================================

screen[0]  <-- PRIMARY (origin 0,0)
  name              : Built-in Retina Display
  frame             : x=0.0 y=0.0 w=1512.0 h=982.0
  visibleFrame      : x=0.0 y=80.0 w=1512.0 h=869.0
  backingScaleFactor: 2.0
  insets (frame -> visibleFrame): bottom=80.0 top=33.0 left=0.0 right=0.0

screen[1]
  name              : 27G2G4
  frame             : x=1512.0 y=-98.0 w=1920.0 h=1080.0
  visibleFrame      : x=1512.0 y=-98.0 w=1920.0 h=1050.0
  backingScaleFactor: 1.0
  insets (frame -> visibleFrame): bottom=0.0 top=30.0 left=0.0 right=0.0

=== OWNER CENSUS (on-screen windows) ============================
    16  Control Center
     2  Code
     2  Notification Center
     2  Window Server
     1  Beekeeper Studio
     1  Brave Browser
     1  Bruno
     1  Dock
     1  Finder
     1  Slack
     1  Spotify
     1  System Settings
     1  Warp

=== WINDOWS OWNED BY "Dock" (1) =================================

  #46708  owner="Dock" pid=63718 layer=20 alpha=1.00 onscreen=true
     CG   (top-left origin): x=0.0 y=0.0 w=1512.0 h=982.0   area=1484784.0
     AppKit (bottom-left) : x=0.0 y=0.0 w=1512.0 h=982.0   maxY=982.0
     vs screen[0].visibleFrame: (win.maxY - vf.minY)=902.0  (win.minX - vf.minX)=0.0  (win.maxX - vf.maxX)=0.0
     vs screen[1].visibleFrame: (win.maxY - vf.minY)=1080.0  (win.minX - vf.minX)=-1512.0  (win.maxX - vf.maxX)=-1920.0

  --> largest-area Dock window is #46708, x=0.0 y=0.0 w=1512.0 h=982.0

=== WINDOWS AT LAYER 20 (Dock level), ANY OWNER (1) =============

  #46708  owner="Dock" pid=63718 layer=20 alpha=1.00 onscreen=true
     CG   (top-left origin): x=0.0 y=0.0 w=1512.0 h=982.0   area=1484784.0
     AppKit (bottom-left) : x=0.0 y=0.0 w=1512.0 h=982.0   maxY=982.0
     vs screen[0].visibleFrame: (win.maxY - vf.minY)=902.0  (win.minX - vf.minX)=0.0  (win.maxX - vf.maxX)=0.0
     vs screen[1].visibleFrame: (win.maxY - vf.minY)=1080.0  (win.minX - vf.minX)=-1512.0  (win.maxX - vf.maxX)=-1920.0

=== DEEP PROBE — Dock windows under different CGWindowList option sets 

--- .optionOnScreenOnly + .excludeDesktopElements
    total windows=31  Dock-owned=1
    #46708 layer=20 alpha=1.00 onscreen=true  x=0.0 y=0.0 w=1512.0 h=982.0

--- .optionOnScreenOnly
    total windows=39  Dock-owned=3
    #46708 layer=20 alpha=1.00 onscreen=true  x=0.0 y=0.0 w=1512.0 h=982.0
    #46710 layer=-2147483624 alpha=1.00 onscreen=true  x=1512.0 y=0.0 w=1920.0 h=1080.0
    #46709 layer=-2147483624 alpha=1.00 onscreen=true  x=0.0 y=0.0 w=1512.0 h=982.0

--- .optionAll
    total windows=190  Dock-owned=3
    #46710 layer=-2147483624 alpha=1.00 onscreen=true  x=1512.0 y=0.0 w=1920.0 h=1080.0
    #46709 layer=-2147483624 alpha=1.00 onscreen=true  x=0.0 y=0.0 w=1512.0 h=982.0
    #46708 layer=20 alpha=1.00 onscreen=true  x=0.0 y=0.0 w=1512.0 h=982.0

--- .optionAll + .excludeDesktopElements
    total windows=176  Dock-owned=1
    #46708 layer=20 alpha=1.00 onscreen=true  x=0.0 y=0.0 w=1512.0 h=982.0

=== END =========================================================

```

---

## Run 2 — Dock on the LEFT

Relevant excerpt (full window list identical in shape to Run 1):

```
screen[0]  <-- PRIMARY (origin 0,0)
  name              : Built-in Retina Display
  frame             : x=0.0 y=0.0 w=1512.0 h=982.0
  visibleFrame      : x=80.0 y=0.0 w=1432.0 h=949.0
  backingScaleFactor: 2.0
  insets (frame -> visibleFrame): bottom=0.0 top=33.0 left=80.0 right=0.0
  #46643  owner="Dock" pid=61664 layer=20 alpha=1.00 onscreen=true
  #46643  owner="Dock" pid=61664 layer=20 alpha=1.00 onscreen=true
```

`visibleFrame` becomes `x=80.0 y=0.0 w=1432.0 h=949.0` — the inset moves to the **left**
edge (80 pt) and the bottom inset drops to 0. §4a's left/right note holds.

---

## Run 3 — Dock bottom, AUTOHIDE ON  (the important one)

Verified `orientation=bottom autohide=1` before probing.

```
screen[0]  <-- PRIMARY (origin 0,0)
  name              : Built-in Retina Display
  frame             : x=0.0 y=0.0 w=1512.0 h=982.0
  visibleFrame      : x=0.0 y=80.0 w=1512.0 h=869.0
  backingScaleFactor: 2.0
  insets (frame -> visibleFrame): bottom=80.0 top=33.0 left=0.0 right=0.0
=== WINDOWS OWNED BY "Dock" (1) =================================
```

`visibleFrame` is **unchanged from Run 1**: bottom inset still exactly 80.0. Sampled once
per second for 8 s with the cursor verified to be mid-screen (y≈460–500, nowhere near the
bottom edge), it never moved:

```
t=0s  mouse=(2922,941)  visibleFrame.minY=80.0  bottomInset=80.0
t=1s  mouse=(2913,938)  visibleFrame.minY=80.0  bottomInset=80.0
t=2s  mouse=(1448,502)  visibleFrame.minY=80.0  bottomInset=80.0
t=3s  mouse=(1148,487)  visibleFrame.minY=80.0  bottomInset=80.0
t=4s  mouse=(1159,462)  visibleFrame.minY=80.0  bottomInset=80.0
t=5s  mouse=(1159,462)  visibleFrame.minY=80.0  bottomInset=80.0
t=6s  mouse=(1159,462)  visibleFrame.minY=80.0  bottomInset=80.0
t=7s  mouse=(2052,498)  visibleFrame.minY=80.0  bottomInset=80.0
```

The Dock-owned layer-20 window, however, **disappears from the window list entirely**
while autohide is on — including with the cursor warped to the bottom edge:

```
[A] cursor parked mid-screen
  hidden? bottomInset=80.0   NO Dock window on screen
  hidden? bottomInset=80.0   NO Dock window on screen
  hidden? bottomInset=80.0   NO Dock window on screen
[B] cursor warped to bottom edge (y=1)
  shown?  bottomInset=80.0   NO Dock window on screen
  shown?  bottomInset=80.0   NO Dock window on screen
  shown?  bottomInset=80.0   NO Dock window on screen
  shown?  bottomInset=80.0   NO Dock window on screen
[C] cursor back mid-screen
  hidden? bottomInset=80.0   NO Dock window on screen
  hidden? bottomInset=80.0   NO Dock window on screen
  hidden? bottomInset=80.0   NO Dock window on screen
```

**Control** — setting `autohide=false` and restarting brings it straight back:

```
  visibleFrame      : x=0.0 y=80.0 w=1512.0 h=869.0
  insets (frame -> visibleFrame): bottom=80.0 top=33.0 left=0.0 right=0.0
  #46690  owner="Dock" pid=63641 layer=20 alpha=1.00 onscreen=true
```

So: **Dock-owned layer-20 window present ⟺ Dock is on screen.** `visibleFrame` cannot
tell you; the window list can.

---

## Run 4 — Magnification ON (largesize 128)

Verified `magnification=1` before probing.

```
  visibleFrame      : x=0.0 y=80.0 w=1512.0 h=869.0
  insets (frame -> visibleFrame): bottom=80.0 top=33.0 left=0.0 right=0.0
  #46696  owner="Dock" pid=63664 layer=20 alpha=1.00 onscreen=true
```

Identical to Run 1. Magnification does not affect `visibleFrame` or the Dock window rect
(it is a hover-time visual effect only). Nothing to compensate for — consistent with
SPEC §8 trap 10.

---

## Run 5 — Large tiles (tilesize 128)

Used in place of "a dozen apps open": both change tile geometry, and this one is
deterministic and reversible.

```
  visibleFrame      : x=0.0 y=125.0 w=1512.0 h=824.0
  insets (frame -> visibleFrame): bottom=125.0 top=33.0 left=0.0 right=0.0
  #46702  owner="Dock" pid=63685 layer=20 alpha=1.00 onscreen=true
```

Bottom inset tracks tile size: **54 → 80 pt, 128 → 125 pt**. The Dock window rect stays
full-screen (`1512×982`) regardless. So `visibleFrame.minY` follows the Dock's real top
edge, and the window rect never does.

---

## Run 6 — Dock tile bounds via the Accessibility API (M8)

Run with the grant in place (`AXIsProcessTrusted: true`), via
`./DockPet.app/Contents/MacOS/DockPet --dock-bounds`. Same machine, tilesize 54.

```
  visibleFrame : x=0.0 y=80.0 w=1512.0 h=869.0
  tiles        : x=381.9 y=10.0 w=748.2 h=74.0  (8.9 ms)
  dock items   : 14 in band, 0 filtered out
      381.9..439.9   Finder
      439.9..497.9   Brave Browser
      ...
      845.9..872.0   (separator, 26.1 pt)
      872.0..930.0   Beekeeper Studio
      988.0..1046.0  System Settings
      1046.0..1072.1 (separator, 26.1 pt)
      1072.1..1130.1 Trash
```

Then with Calculator launched — one extra tile:

```
  tiles        : x=352.9 y=10.0 w=806.2 h=74.0
  dock items   : 15 in band, 0 filtered out
```

**Second display**: `tiles: n/a (no Dock inset on this screen)`, consistent with Run 1.

---

## Findings

**F1 — §4a holds, and is the only geometry source that works.**
`visibleFrame.minY` is the Dock's top edge, tracks tile size, is unaffected by
magnification, and moves to `minX`/`maxX` for a side Dock. Bottom inset on the
Dock-less second display is 0, so the inset also identifies *which* screen has the Dock.

**F2 — the *window list* carries no horizontal information. (Amended by F7.)**
The Dock process owns exactly three windows:

| # | layer | bounds | what it is |
|---|---|---|---|
| 31 | 20 | `0,0 1512×982` | the Dock — **full screen**, not the tiles |
| 45648 | −2147483624 | `0,0 1512×982` | desktop wallpaper, screen 0 |
| 46071 | −2147483624 | `1512,0 1920×1080` | desktop wallpaper, screen 1 |

Checked under all four `CGWindowList` option sets (`--deep`); no per-tile windows exist at
any of them. "Largest area" does select the right window, but its rect equals
`screen.frame`. This is SPEC §8 trap 8, confirmed: the Liquid Glass Dock is a full-screen
surface. Note the Dock also owns the wallpaper windows — any filter must exclude the huge
negative layer.

**F7 — [M8] the Accessibility API does give the tile extent, and it is exact.**
Run 6. `AXUIElementCreateApplication(dockPID)` → walk to the `AXDockItem` elements → union
their frames. That yields `381.9..1130.1` against a 1512 pt screen: the strip drops to
**49.5% of its old width**, which is the whole visible difference.

Details that matter:

- **Union the items, not the enclosing `AXList`.** The list element is padded well past the
  tiles it contains; only the union tracks what is drawn.
- **Separators are dock items too** (the two 26.1 pt blanks above). They sit between the
  tiles, so including them changes nothing — but a filter on "has a title" would have to
  special-case them, so there is no filter.
- **It tracks live.** Launching one app: 14 items → 15, width 748.2 → 806.2, and origin
  381.9 → 352.9. The Dock re-centres, so **both** ends move. Tracking width alone would
  drift the pet leftward.
- **Cost is 7–9 ms per read.** Fine at the 500 ms locator poll (~1.6% of one core), which is
  why §4b [M8] measures there and never on the 12 fps animation tick.
- **The grant is keyed to the code signature.** `./bundle.sh` produces a new hash, so every
  rebuild silently drops the grant and the pet reverts to full width. Ad-hoc signing gives
  the entry a stable *name* but not a stable *hash*; only a real signing identity would
  survive. Adding the bundle by path in System Settings did not take — the working route is
  the system prompt (`AXIsProcessTrustedWithOptions`), which registers the running binary.
  After a rebuild: `tccutil reset Accessibility com.local.dockpet`, then re-approve.
- **A running app picks the grant up without a restart** — observed going from
  `tiles=unmeasured` to `tiles=[381.9...1130.1]` mid-run, on the next 500 ms poll.

**F3 — `kCGWindowOwnerName == "Dock"` still holds.** SPEC §8 trap 7's ownership reshuffle
is menu-bar-only; the census shows 16 windows under "Control Center" but the Dock is
still its own owner.

**F4 — SPEC §4a's autohide claim is wrong for Tahoe.** `visibleFrame` does **not** reclaim
the Dock's space when autohidden; the inset stays at its full value. An app relying on
`visibleFrame` alone would place the pet floating 80 pt above the desktop with no Dock
under it, and would never know.

**F5 — The window list is still required, as a liveness signal.** Presence of a
Dock-owned layer-20 window is a live, permission-free boolean for "is the Dock on
screen right now". This is what §6 needs to suspend on autohide, and it is also what makes
§8 trap 9 (Tahoe's Dock vanishing after screensaver wake) degrade correctly into the
§4d dormant path.

**F6 — [M2 correction] F5 tracks the Dock's *drawn* state, not the autohide setting.**
The Run 3 wording above ("absent whenever autohide is on") was measured correctly but
generalised too far. Re-tested during M2 with `autohide=1` held constant throughout:

```
phase 1: cursor untouched (Dock revealed after a Dock restart)
  idle           mouse.y=  172.3  dockWindowPresent=YES  vf.minY=80.0
  idle           mouse.y=  102.5  dockWindowPresent=YES  vf.minY=80.0
phase 2: cursor glided down to the bottom edge
  gliding y=50   mouse.y=   50.0  dockWindowPresent=YES  vf.minY=80.0
  gliding y=0    mouse.y=    0.9  dockWindowPresent=no   vf.minY=80.0
phase 3/4: Dock now hidden; stays absent
  held at edge   mouse.y=  411.8  dockWindowPresent=no   vf.minY=80.0
  away           mouse.y=  179.9  dockWindowPresent=no   vf.minY=80.0
```

So the correct rule is **present ⟺ the Dock is currently drawn on screen**. With autohide
enabled the window comes and goes as the Dock slides in and out. `vf.minY` stays pinned at
80.0 across every one of those samples, which re-confirms F4 independently.

This is a strictly better signal than F5 claimed: the pet tracks the Dock itself rather
than a static preference, so it rides along with the reveal/hide animation instead of
being disabled outright whenever autohide is switched on.

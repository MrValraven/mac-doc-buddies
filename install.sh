#!/bin/bash
#
# install.sh — build DockPet from source on this Mac and install it to /Applications.
#
# This is the hand-over path for a Mac that is not the development machine (SPEC §8.6
# [M11]). Building locally rather than copying a prebuilt .app avoids both distribution
# traps in one move:
#
#   * Gatekeeper never sees it. A bundle produced on the machine it runs on carries no
#     com.apple.quarantine attribute, so there is no "unidentified developer" prompt and
#     no right-click-Open dance. A copied .app signed by the local identity from
#     makecert.sh would be an app from an unknown authority here, and be refused.
#   * The binary matches the chip. `swift build` targets the host, so this produces a
#     native arm64 or x86_64 build without anyone having to remember which Mac is which.
#
# What it cannot do is grant Accessibility. DockPet needs it to read the Dock's tile
# bounds (§4b), macOS requires a human to click it, and no installer can do that on the
# user's behalf. The app ships an OnboardingWindow ([M11]) for exactly this moment; the
# closing message below points at it.
#
#     ./install.sh
#
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_NAME="DockPet"
readonly BUNDLE_ID="com.local.dockpet"
readonly MIN_MAJOR=13

cd "$ROOT"

# ── 1. macOS version ─────────────────────────────────────────────────────────
# Info.plist sets LSMinimumSystemVersion, but Launch Services only reports that as a
# vague failure at open time. Checking here names the actual problem.
OS_VERSION="$(sw_vers -productVersion)"
if (( ${OS_VERSION%%.*} < MIN_MAJOR )); then
    echo "error: DockPet needs macOS ${MIN_MAJOR}.0 or later; this Mac runs ${OS_VERSION}." >&2
    exit 1
fi

# ── 2. Swift toolchain ───────────────────────────────────────────────────────
# The Command Line Tools are enough — a full Xcode is not required, and neither is
# XCTest (the test target is an executable for precisely that reason, see Package.swift).
# `xcode-select --install` is a GUI installer that cannot be driven from here, so this
# stops and hands over the command rather than pretending it can continue.
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    echo "error: the Swift toolchain is not installed." >&2
    echo "       Run this, complete the installer, then re-run ./install.sh:" >&2
    echo >&2
    echo "           xcode-select --install" >&2
    exit 1
fi
echo "==> macOS ${OS_VERSION}, $(swift --version 2>/dev/null | head -1)"

# ── 3. Local signing identity ────────────────────────────────────────────────
# Idempotent by design: makecert.sh exits early when the identity already exists, and
# re-issuing would be actively harmful because a new certificate means a new designated
# requirement, which drops the Accessibility grant it exists to protect.
echo "==> ensuring the local signing identity exists"
"${ROOT}/makecert.sh" | sed 's/^/    /'

# ── 4. Build and bundle ──────────────────────────────────────────────────────
# bundle.sh regenerates Resources/ (icon and sprite sheets) when missing, which is what
# makes a bare `git clone` sufficient — those artefacts are gitignored, not committed.
echo "==> building"
"${ROOT}/bundle.sh" | sed 's/^/    /'

readonly BUILT_APP="${ROOT}/${APP_NAME}.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "error: bundle.sh finished but ${APP_NAME}.app is not there." >&2
    exit 1
fi

# ── 5. Choose a destination ──────────────────────────────────────────────────
# /Applications needs admin rights on a managed or multi-user Mac. Rather than demand
# sudo for a personal menu bar app, fall back to the per-user ~/Applications, which
# Launch Services treats identically.
DEST_DIR="/Applications"
if [[ ! -w "$DEST_DIR" ]]; then
    DEST_DIR="${HOME}/Applications"
    mkdir -p "$DEST_DIR"
    echo "==> /Applications is not writable — installing to ${DEST_DIR} instead"
fi
readonly DEST="${DEST_DIR}/${APP_NAME}.app"

# ── 6. Stop any running copy ─────────────────────────────────────────────────
# Replacing the bundle underneath a running process leaves it with half-swapped
# resources; it also keeps the old build's menu bar item alive next to the new one.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "==> quitting the running ${APP_NAME}"
    osascript -e "quit app id \"${BUNDLE_ID}\"" 2>/dev/null || pkill -x "$APP_NAME" || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
        /bin/sleep 0.3
    done
    pkill -9 -x "$APP_NAME" 2>/dev/null || true
fi

# ── 7. Install ───────────────────────────────────────────────────────────────
# Remove first so a resource dropped between versions cannot survive in the installed
# copy. Guarded so a bad expansion can never point the rm somewhere else.
if [[ -d "$DEST" && "$DEST" == "${DEST_DIR}/${APP_NAME}.app" ]]; then
    rm -rf "$DEST"
fi
echo "==> installing to ${DEST}"
cp -R "$BUILT_APP" "$DEST"

# A locally built bundle should have no quarantine attribute. If the *source* arrived by
# AirDrop or download it can inherit one, and it would then propagate to the copy, so
# clear it rather than leave a Gatekeeper prompt for a self-built app.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# Confirm the signature survived the copy. cp -R preserves it, but a broken signature
# here would cost the Accessibility grant later, and that failure is invisible until the
# pet silently refuses to find the Dock.
if ! codesign --verify --deep --strict "$DEST" 2>/dev/null; then
    echo "error: the installed bundle does not verify. Not launching it." >&2
    exit 1
fi
echo "    requirement: $(codesign -d -r- "$DEST" 2>&1 | sed -n 's/^#* *designated => //p')"

# ── 8. Launch ────────────────────────────────────────────────────────────────
echo "==> launching"
open "$DEST"

cat <<'DONE'

==> installed

DockPet is a menu bar app (LSUIElement) — look for it in the menu bar, not the Dock.

One manual step is left, and it cannot be scripted: DockPet needs Accessibility
permission to read the Dock's icon positions. On first launch it shows a window
explaining this with a button that opens the right settings pane. You can also grant
it from the menu bar item's "Grant Accessibility…" entry, or by hand at:

    System Settings > Privacy & Security > Accessibility

Until it is granted the pet stays hidden and the menu bar item reads
"Waiting for Accessibility". That is expected, not a failure.

To start it automatically at login:
    System Settings > General > Login Items > "+"  and pick DockPet.

DONE

#!/bin/bash
#
# bundle.sh — build DockPet and assemble a runnable .app bundle.
#
# SPEC §2. Idempotent and safe to re-run.  Target loop:
#
#     ./bundle.sh && open DockPet.app
#
# No code signing, no notarisation (SPEC §8.6) — this is a local personal build.
#
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_NAME="DockPet"
readonly BUNDLE_ID="com.local.dockpet"
readonly VERSION="0.1.0"
readonly MIN_OS="13.0"

readonly APP="${ROOT}/${APP_NAME}.app"
readonly CONTENTS="${APP}/Contents"
readonly MACOS_DIR="${CONTENTS}/MacOS"
readonly RES_DIR="${CONTENTS}/Resources"

cd "$ROOT"

# The app icon is generated rather than committed as a binary blob; regenerate it only
# when missing, so a normal rebuild does not pay for it.
if [[ ! -f "${ROOT}/Resources/AppIcon.icns" ]]; then
    echo "==> generating Resources/AppIcon.icns"
    swift "${ROOT}/makeicon.swift"
fi

# All four sheets come out of one generator run, so a single missing pose regenerates the
# set rather than leaving the pet with a walk cycle and no way to sit down.
MISSING_SHEET=""
for SHEET in cat_walk cat_idle cat_sit cat_sleep; do
    if [[ ! -f "${ROOT}/Resources/sprites/${SHEET}.png" ]]; then MISSING_SHEET="$SHEET"; break; fi
done
if [[ -n "$MISSING_SHEET" ]]; then
    echo "==> generating Resources/sprites/ (${MISSING_SHEET}.png is missing)"
    swift "${ROOT}/makesprite.swift"
fi

echo "==> swift build -c release"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: expected binary not found at ${BIN_PATH}" >&2
    exit 1
fi

# Remove any previous bundle so stale resources cannot survive a rebuild. Guarded so a
# bad expansion can never point this at something else.
if [[ -d "$APP" && "$APP" == "${ROOT}/${APP_NAME}.app" ]]; then
    echo "==> removing previous ${APP_NAME}.app"
    rm -rf "$APP"
fi

echo "==> assembling bundle"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN_PATH" "${MACOS_DIR}/${APP_NAME}"
chmod +x "${MACOS_DIR}/${APP_NAME}"

# Copy Resources/ contents (sprites etc.) into Contents/Resources/, if any exist.
if [[ -d "${ROOT}/Resources" ]]; then
    # -R on the *contents* so we get Resources/sprites, not Resources/Resources/sprites.
    shopt -s nullglob dotglob
    entries=("${ROOT}/Resources"/*)
    if (( ${#entries[@]} )); then
        cp -R "${entries[@]}" "$RES_DIR"/
        echo "    copied $(( ${#entries[@]} )) item(s) from Resources/"
    else
        echo "    Resources/ is empty (sprites arrive at M4) — nothing to copy"
    fi
    shopt -u nullglob dotglob
fi

echo "==> writing Info.plist"
cat > "${CONTENTS}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Fail loudly if the plist is malformed, rather than letting Launch Services silently
# refuse to open the bundle.
plutil -lint "${CONTENTS}/Info.plist" > /dev/null

# Sign the bundle. SPEC §8.6 still holds — no Developer ID, no notarisation — but [M8]'s
# Accessibility grant is recorded against the code signature, so *what* we sign with decides
# whether that grant survives a rebuild:
#
#   ad-hoc (no certificate)  -> designated requirement is `cdhash H"..."`, a hash of the
#                               compiled code. Every rebuild changes it and TCC silently
#                               drops the grant.
#   a real certificate       -> requirement is identifier + certificate, which does not
#                               change when the code does. Grant survives rebuilds.
#
# So: sign with a certificate whenever one is available. `./makecert.sh` creates a local
# one; an Apple Development identity is preferred if this machine ever gets one, since its
# requirement matches on the certificate's name and so survives renewal too.
# DOCKPET_SIGN_IDENTITY overrides the search.
echo "==> signing"
SIGN_IDENTITY="${DOCKPET_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
    # `-v` filters to identities that are actually usable; an untrusted or expired one
    # would fail the codesign below anyway.
    # Match by SHA-1 hash, never by name. Two certificates sharing a common name make
    # `codesign --sign "<name>"` fail with "ambiguous" — measured, after a re-run of
    # makecert.sh left a second "DockPet Local Signing" behind. The hash is unique.
    IDENTITIES="$(security find-identity -v -p codesigning || true)"
    SIGN_IDENTITY="$(sed -n 's/^ *[0-9]*) \([0-9A-F]*\) "Apple Development: .*/\1/p' <<< "$IDENTITIES" | head -1)"
    if [[ -z "$SIGN_IDENTITY" ]]; then
        SIGN_IDENTITY="$(sed -n 's/^ *[0-9]*) \([0-9A-F]*\) "DockPet Local Signing".*/\1/p' <<< "$IDENTITIES" | head -1)"
    fi
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "    identity: ${SIGN_IDENTITY}"
    codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
    echo "    identity: none found — falling back to ad-hoc"
    echo "    !! the Accessibility grant (SPEC §4b [M8]) will not survive this rebuild."
    echo "       Run ./makecert.sh once to make it permanent."
    codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

# A signature that quietly came out ad-hoc when an identity *was* available is the failure
# mode that costs the Accessibility grant, and it is invisible unless you look. Look.
REQUIREMENT="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"
if [[ -n "$SIGN_IDENTITY" && "$REQUIREMENT" != *"certificate"* ]]; then
    echo "error: signed with ${SIGN_IDENTITY} but the requirement is still hash-based:" >&2
    echo "       ${REQUIREMENT}" >&2
    echo "       The Accessibility grant would not survive this build. Not shipping it." >&2
    exit 1
fi

# Print the requirement TCC will key the grant to, so a lapsed grant is always explainable.
# Ad-hoc prints this line commented ("# designated => "), a certificate prints it bare.
echo "    requirement: $(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')"

# Touching the bundle nudges Launch Services to re-read Info.plist after a rebuild;
# without it a changed LSUIElement can be ignored until logout.
touch "$APP"

echo "==> done"
echo "$APP"

#!/bin/bash
#
# makecert.sh — create the local code-signing identity DockPet is signed with.
#
# Why this exists (SPEC §4c [M8]): the Accessibility grant that confines the pet to the
# Dock is stored against the app's *designated requirement*. Signed ad-hoc, that
# requirement is `cdhash H"..."` — a hash of the compiled code — so every ./bundle.sh
# produces a different app as far as TCC is concerned and the grant silently lapses.
# Signed with a certificate, the requirement names the certificate instead, and the grant
# survives any number of rebuilds.
#
# This is a *local* identity: self-signed, this machine only, no Apple Developer account,
# no notarisation (SPEC §8.6 still holds). The trust setting it installs is scoped to the
# codeSign policy alone.
#
# Idempotent: re-running when the identity already exists does nothing. Run once.
#
#     ./makecert.sh && ./bundle.sh
#
# To undo completely:
#     security delete-keychain ~/Library/Keychains/dockpet-signing.keychain-db
#   (the trust setting goes with the certificate)
#
set -euo pipefail

readonly CN="DockPet Local Signing"

# A dedicated keychain rather than the login keychain.
#
# Measured the login-keychain route first and it does not work unattended: macOS gates the
# private key per use, so every codesign either raised a GUI "wants to access key" dialog
# or blocked on one — bundle.sh hung, and twice fell back to ad-hoc mid-run. Fixing that
# needs `set-key-partition-list`, which needs the keychain's password, which for the login
# keychain is the user's account password and cannot be scripted.
#
# So: our own keychain, with a password we know, so the ACL can be set non-interactively.
# The password is not a secret and is not treated as one — the protection here is file
# permissions plus being logged in, and the only capability the key grants is signing local
# builds of this app.
readonly KEYCHAIN="${HOME}/Library/Keychains/dockpet-signing.keychain-db"
readonly KEYCHAIN_PASSWORD="dockpet"

# Already have it? Then there is nothing to do, and re-issuing would be actively harmful:
# a new certificate means a new requirement, which would drop the grant we are protecting.
if security find-identity -v -p codesigning | grep -qF "$CN"; then
    echo "==> \"${CN}\" already exists — nothing to do"
    security find-identity -v -p codesigning | grep -F "$CN" | sed 's/^/    /'
    exit 0
fi

# A second certificate with the same common name makes `codesign --sign "<name>"` fail
# outright ("ambiguous"), and bundle.sh would fall back to ad-hoc. Clear any stale ones
# before issuing — reaching here means no *valid* identity exists, so nothing is in use.
if [[ -f "$KEYCHAIN" ]]; then
    while read -r stale; do
        [[ -n "$stale" ]] || continue
        echo "==> removing a stale \"${CN}\" certificate (${stale:0:8}…)"
        security delete-certificate -Z "$stale" "$KEYCHAIN" 2>/dev/null || true
    done < <(security find-certificate -a -c "$CN" -Z "$KEYCHAIN" 2>/dev/null \
             | sed -n 's/^SHA-1 hash: //p')
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> preparing ${KEYCHAIN##*/}"
if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
fi
# No lock timeout and no lock-on-sleep: a keychain that re-locks turns signing into an
# intermittent failure, which is exactly the class of bug this whole exercise is about.
security set-keychain-settings "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

echo "==> generating a self-signed code-signing certificate"
cat > "${WORK}/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = ${CN}
[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
CNF

# 10 years: this is a local identity with no revocation story, and an expiry would drop the
# Accessibility grant on a day nobody would connect to the cause.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "${WORK}/key.pem" -out "${WORK}/cert.pem" -config "${WORK}/cert.cnf" 2>/dev/null

openssl pkcs12 -export -out "${WORK}/id.p12" \
    -inkey "${WORK}/key.pem" -in "${WORK}/cert.pem" \
    -passout pass:dockpet -name "$CN" 2>/dev/null

echo "==> importing the key"
security import "${WORK}/id.p12" -k "$KEYCHAIN" -P dockpet -A -T /usr/bin/codesign >/dev/null

# The part that actually stops the prompting. `-A` at import sets the ACL, but the
# partition list is a separate gate and is what codesign trips over.
security set-key-partition-list -S apple-tool:,apple:,codesign: \
    -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1

# codesign only searches keychains on the user's search list.
if ! security list-keychains -d user | grep -qF "$KEYCHAIN"; then
    EXISTING="$(security list-keychains -d user | sed 's/[" ]//g')"
    security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi

echo "==> trusting it for code signing"
echo "    macOS will ask you to authorise this — it is the trust setting, and it is the"
echo "    one interactive step. Scoped to the codeSign policy only."
# Without this, codesign refuses the identity outright: CSSMERR_TP_NOT_TRUSTED.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "${WORK}/cert.pem"

echo "==> verifying"
if ! security find-identity -v -p codesigning | grep -qF "$CN"; then
    echo "error: \"${CN}\" is still not a valid signing identity." >&2
    echo "       If you cancelled the authorisation dialog, re-run this script." >&2
    exit 1
fi
security find-identity -v -p codesigning | grep -F "$CN" | sed 's/^/    /'

echo
echo "==> done. Now:"
echo "      ./bundle.sh && open DockPet.app"
echo "    then grant Accessibility once (menu bar → Confine Pet to the Dock…)."
echo "    That grant will survive every rebuild from here on."

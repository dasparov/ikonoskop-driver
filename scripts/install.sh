#!/bin/bash
# Install the Ikonoskop A-Cam dII Express Card Reader kext (Apple silicon).
# Uses the IkonoskopCardReader.kext next to this script (release download), otherwise the
# source build in kext/build (`make install`).
# Prerequisite (one-time, in Recovery): Startup Security Utility -> Reduced Security with
# "Allow user management of kernel extensions from identified developers", then in Terminal
# `csrutil enable --without kext`, then restart.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/IkonoskopCardReader.kext"
[ -d "$SRC" ] || SRC="$SCRIPT_DIR/../kext/build/IkonoskopCardReader.kext"
DEST="/Library/Extensions/IkonoskopCardReader.kext"

[ -d "$SRC" ] || { echo "No IkonoskopCardReader.kext next to this script. From source, run: make install"; exit 1; }

if ! csrutil status | grep -q -E 'status: disabled|Kext Signing: disabled'; then
    echo "SIP kext protection is still on. Boot to Recovery and run: csrutil enable --without kext"
    exit 1
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")"

sudo rm -rf "$DEST"
sudo cp -R "$SRC" "$DEST"
sudo chown -R root:wheel "$DEST"
sudo chmod -R go-w "$DEST"
# A downloaded release carries com.apple.quarantine; drop it from the installed copy.
sudo xattr -dr com.apple.quarantine "$DEST"

echo "Staging $BUNDLE_ID into the auxiliary kext collection..."
# kmutil exits non-zero here even when staging works ("requires a reboot", "not approved to load"):
# the new collection only takes effect after approval and a restart.
sudo kmutil load -p "$DEST" || true

# macOS approves ad-hoc signed kexts by CDHash (UnsignedKernelExtensions in UAKL.plist), so every
# changed binary needs its own approval (the link is reproducible: unchanged source keeps its CDHash).
# Without it, a restart keeps loading the previously approved build.
CDHASH="$(codesign -dvvv "$DEST" 2>&1 | sed -n 's/^CDHash=//p')"
UAKL=/var/db/SystemPolicyConfiguration/UAKL.plist
if plutil -extract UnsignedKernelExtensions xml1 -o - "$UAKL" 2>/dev/null | grep -q "<string>$CDHASH</string>"; then
    APPROVE="  1. This build (CDHash $CDHASH) is already approved."
else
    APPROVE="  1. Approve this build (CDHash $CDHASH): System Settings > Privacy & Security >
     \"Some system software requires your attention\" > Details..., enable the Ikonoskop
     extension and authenticate. Every changed binary needs this; a restart without it keeps
     loading the previous build. Approved once listed by:
     plutil -extract UnsignedKernelExtensions xml1 -o - $UAKL | grep $CDHASH"
    open "x-apple.systempreferences:com.apple.preference.security?General" || true
fi

cat <<EOF

Next:
$APPROVE
  2. Restart the Mac. The driver loads on the next boot.
  3. After restarting: power the reader, insert a card, connect Thunderbolt.
     The card mounts read-only in Finder; footage is in the IMAGE folder.
Check status any time with: kmutil showloaded --bundle-identifier $BUNDLE_ID
EOF

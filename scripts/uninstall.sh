#!/bin/bash
# Remove the rebuilt Ikonoskop card reader kext. Takes effect after a restart.
# Afterwards you can restore full security in Recovery: `csrutil enable`, then
# Startup Security Utility -> Full Security.
set -euo pipefail

DEST="/Library/Extensions/IkonoskopCardReader.kext"
[ -d "$DEST" ] || { echo "Not installed."; exit 0; }

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist")"
sudo kmutil unload -b "$BUNDLE_ID" || true
sudo rm -rf "$DEST"
sudo kmutil install --update-all || true
echo "Removed $BUNDLE_ID. Restart the Mac to drop it from the kernel."

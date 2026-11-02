#!/bin/bash
# Dumps the virtual disk produced by ik::VirtualCard (mock card), then checks it with the
# real macOS tools: hdiutil (raw image, read-only), fsck_msdos -n, msdosfs mount, sips.
set -euo pipefail

WORK=${1:?usage: run_fs_test.sh <workdir> [scenario]}
SCENARIO=(--scenario "${2:-0}")
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=$WORK/virtual_card.img
MNT=$WORK/mnt
mkdir -p "$WORK"
DEV=

detach() {
    if [ -n "$DEV" ]; then
        hdiutil detach "$DEV" -force >/dev/null 2>&1 || true
        DEV=
    fi
}
trap detach EXIT

attach() {
    # $@: extra hdiutil attach options; sets DEV to the whole-disk node.
    DEV=$(hdiutil attach -readonly -imagekey diskimage-class=CRawDiskImage "$@" "$IMG" | awk 'NR==1 {print $1}')
    [ -n "$DEV" ] || { echo "hdiutil attach failed"; exit 1; }
}

echo "== dump"
"$HERE/ik_harness" dump "$IMG" "${SCENARIO[@]}"
ls -lsh "$IMG"

echo "== fsck_msdos -n"
attach -nomount
echo "attached as $DEV"
set +e
fsck_msdos -n "${DEV/disk/rdisk}"
FSCK=$?
set -e
detach
echo "fsck_msdos exit status: $FSCK"
[ "$FSCK" -eq 0 ] || { echo "FAIL: fsck_msdos reported problems"; exit 1; }

echo "== mount read-only and verify"
rm -rf "$MNT"
mkdir -p "$MNT"
attach -mountpoint "$MNT"
echo "mounted $DEV at $MNT"
diskutil info "$DEV" | grep -E 'File System Personality|Volume Name|Read-Only Volume|Disk Size' || true
ls -la "$MNT" "$MNT/IMAGE"
"$HERE/ik_harness" verify "$MNT" "${SCENARIO[@]}"
DNGS=("$MNT"/IMAGE/*/*.DNG)
FIRST=${DNGS[0]}
echo "== sips -g all $FIRST"
sips -g all "$FIRST"
detach
rm -f "$IMG"
echo "fs test: PASS"

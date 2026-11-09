#!/bin/bash
# Exercises CastOff against throwaway disk images. It touches no real drives
# and stops no real services: the "indexer" here is a tiny program named mdworker.
#
# Usage: Tests/disk-image-tests.sh [path to the CastOff executable]

set -uo pipefail

BIN="${1:-$HOME/Applications/CastOff.app/Contents/MacOS/CastOff}"
WORK="$(mktemp -d)"
PASS=0
FAIL=0
HOLDERS=()

cleanup() {
    for pid in "${HOLDERS[@]:-}"; do
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
    done
    for volume in /Volumes/CastOffTest*; do
        [ -d "$volume" ] && hdiutil detach -quiet -force "$volume" 2>/dev/null
    done
    rm -rf "$WORK"
}
trap cleanup EXIT

check() {
    if [[ "$3" == *"$2"* ]]; then
        echo "ok    $1"
        PASS=$((PASS + 1))
    else
        echo "FAIL  $1: expected '$2', got '$3'"
        FAIL=$((FAIL + 1))
    fi
}

attach() {
    hdiutil create -quiet -size 40m -fs APFS -volname "$1" "$WORK/$1.dmg"
    hdiutil attach -quiet "$WORK/$1.dmg"
    sleep 1
    echo held > "/Volumes/$1/held.txt"
}

hold() {
    "$1" -f "$2" >/dev/null 2>&1 &
    LAST_HOLDER=$!
    HOLDERS+=("$LAST_HOLDER")
    sleep 1
}

mounted() {
    if [ -d "/Volumes/$1" ]; then echo mounted; else echo gone; fi
}

# A drive nothing is using ejects normally.
attach CastOffTestPlain
check "lists the drive" "CastOffTestPlain" "$("$BIN" --list)"
check "free drive ejects" "Asked to quit: nothing" "$("$BIN" --eject CastOffTestPlain)"
check "free drive is gone" "gone" "$(mounted CastOffTestPlain)"

# A drive held only by a process on the stop list gets that process stopped.
attach CastOffTestIndexer
cc -x c -o "$WORK/mdworker" - <<'SOURCE'
#include <fcntl.h>
#include <unistd.h>
int main(int argc, char **argv) { int file = open(argv[argc - 1], O_RDONLY); pause(); return file; }
SOURCE
hold "$WORK/mdworker" /Volumes/CastOffTestIndexer/held.txt
check "indexer can be stopped" "can be stopped" "$("$BIN" --list)"
check "indexer is asked to quit" "Asked to quit: mdworker" "$("$BIN" --eject CastOffTestIndexer)"
check "indexer-held drive is gone" "gone" "$(mounted CastOffTestIndexer)"

# A drive held by anything else is left alone and the process survives.
attach CastOffTestApp
hold /usr/bin/tail /Volumes/CastOffTestApp/held.txt
APP_HOLDER=$LAST_HOLDER
check "other process blocks eject" "In use by: tail" "$("$BIN" --eject CastOffTestApp)"
check "blocked drive stays mounted" "mounted" "$(mounted CastOffTestApp)"
if kill -0 "$APP_HOLDER" 2>/dev/null; then alive=alive; else alive=dead; fi
check "other process is not stopped" "alive" "$alive"

# Eject when free waits for the other process to finish.
( sleep 7; kill "$APP_HOLDER" 2>/dev/null ) &
check "waits until the drive is free" "Ejected" "$("$BIN" --eject CastOffTestApp --wait)"
check "waited drive is gone" "gone" "$(mounted CastOffTestApp)"

# Volumes on one physical disk are shown and ejected together.
hdiutil create -quiet -size 200m -layout GPTSPUD -fs JHFS+ -volname CastOffTestFirst "$WORK/split.dmg"
hdiutil attach -quiet "$WORK/split.dmg"
sleep 1
DISK="$(diskutil info -plist /Volumes/CastOffTestFirst | plutil -extract ParentWholeDisk raw -o - -)"
diskutil partitionDisk "$DISK" 2 GPT JHFS+ CastOffTestFirst 50% JHFS+ CastOffTestSecond R >/dev/null
sleep 1
check "groups volumes by disk" "CastOffTestFirst, CastOffTestSecond" "$("$BIN" --list)"
check "multi-volume drive ejects" "Ejected" "$("$BIN" --eject CastOffTestFirst)"
check "first volume is gone" "gone" "$(mounted CastOffTestFirst)"
check "second volume is gone" "gone" "$(mounted CastOffTestSecond)"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/bin/bash
#
#  build_press_kit.sh
#  CatchMatch
#
#  Created by Michel Storms on 04/10/2026.
#
# Collect the press kit into one zip: the icon, the screenshots and the copy. #122
#
# Usage:
#   Scripts/build_press_kit.sh
#
# Reads the latest capture under Scripts/screenshots/output/ — run
# Scripts/generate_screenshots.sh first if there is none, or if the app's
# window has changed since. The copy is docs/PRESS_KIT.md, which takes its
# wording from docs/POSITIONING.md and goes into the zip as it is.
#
# Not in the kit yet: the 30-second demo and an iPhone screenshot of a synced
# track, both still to be made by hand.
#
# Output: build/press-kit/CatchMatch-press-kit.zip  (git-ignored)

set -euo pipefail
cd "$(dirname "$0")/.."

ICON="dlp2music/dlp2music/Assets.xcassets/AppIcon.appiconset/mac1024.png"
COPY="docs/PRESS_KIT.md"
SHOTS_ROOT="Scripts/screenshots/output"

LATEST=""
if [ -d "$SHOTS_ROOT" ]; then
    # Folder names are timestamps, so the last one in sort order is the newest.
    LATEST=$(find "$SHOTS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)
fi
if [ -z "$LATEST" ] || [ ! -d "$LATEST/raw" ] || [ ! -d "$LATEST/gumroad" ]; then
    echo "❌ ERROR: no complete capture under $SHOTS_ROOT (it needs raw/ and gumroad/). Run Scripts/generate_screenshots.sh first." >&2
    exit 1
fi
for f in "$ICON" "$COPY"; do
    if [ ! -f "$f" ]; then
        echo "❌ ERROR: missing $f" >&2
        exit 1
    fi
done

OUT="build/press-kit"
KIT="$OUT/CatchMatch-press-kit"
ZIP="$OUT/CatchMatch-press-kit.zip"

rm -rf "$KIT" "$ZIP"
mkdir -p "$KIT/screenshots/window" "$KIT/screenshots/framed"

cp "$ICON" "$KIT/CatchMatch-icon-1024.png"
cp "$COPY" "$KIT/CatchMatch-press-kit.md"

# nullglob: a folder with no PNGs in it is an error to report, not a literal
# "*.png" handed to cp.
shopt -s nullglob
WINDOW=("$LATEST"/raw/*.png)
FRAMED=("$LATEST"/gumroad/*.png)
shopt -u nullglob
if [ ${#WINDOW[@]} -eq 0 ] || [ ${#FRAMED[@]} -eq 0 ]; then
    echo "❌ ERROR: $LATEST has no screenshots in raw/ or gumroad/. Run Scripts/generate_screenshots.sh again." >&2
    exit 1
fi
cp "${WINDOW[@]}" "$KIT/screenshots/window/"
cp "${FRAMED[@]}" "$KIT/screenshots/framed/"

# -X leaves out Finder metadata, so the zip opens clean on any system.
(cd "$OUT" && zip -qrX "CatchMatch-press-kit.zip" "CatchMatch-press-kit")
rm -rf "$KIT"

echo "✔ Press kit: $ZIP"
echo "  Screenshots from: $LATEST"
unzip -l "$ZIP"

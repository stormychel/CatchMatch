#!/bin/bash
#
#  generate_screenshots.sh
#  CatchMatch
#
#  Created by Michel Storms on 19/09/2026.
#
# Capture the marketing scenes and render the Gumroad / landing-page images. #105
# Modelled on HoverCalc's Scripts/generate_screenshots.sh.
#
# Usage:
#   Scripts/generate_screenshots.sh           # capture + compose
#   Scripts/generate_screenshots.sh compose   # compose only, from the latest capture
#
# Output: Scripts/screenshots/output/<timestamp>/  (git-ignored)
#   raw/            window captures from the UI test
#   gumroad/        cover (1280x720 @2x), thumbnail (600x600 @2x), gallery images

set -euo pipefail
cd "$(dirname "$0")/.."

RESULT_BUNDLE="/tmp/catchmatch-screenshots.xcresult"

if [[ "${1:-}" != "compose" ]]; then
    echo "==> Capturing screenshots…"
    rm -rf "$RESULT_BUNDLE"
    # Set CM_DERIVED_DATA to build somewhere other than the shared DerivedData:
    # Xcode resolving packages in the same folder at the same time can leave a
    # half-extracted Sparkle.xcframework behind and fail the build.
    DD_ARGS=()
    [ -n "${CM_DERIVED_DATA:-}" ] && DD_ARGS=(-derivedDataPath "$CM_DERIVED_DATA")

    xcodebuild test \
        -project dlp2music/CatchMatch.xcodeproj \
        -scheme CatchMatch \
        -destination 'platform=macOS' \
        -only-testing CatchMatchUITests/ScreenshotTests \
        -resultBundlePath "$RESULT_BUNDLE" \
        ${DD_ARGS[@]+"${DD_ARGS[@]}"} \
        2>&1 | tail -5

    echo ""
    echo "==> Extracting from xcresult…"
    python3 Scripts/screenshots/extract_screenshots.py "$RESULT_BUNDLE"
fi

echo ""
echo "==> Composing…"
OUT=$(python3 Scripts/screenshots/compose_screenshots.py)
echo ""
echo "==> Done: $OUT"
open "$OUT"

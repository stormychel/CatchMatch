#!/usr/bin/env bash

################################################################################
# CatchMatch Release Script — publishes to GitHub Pages (#121)
#
# Modelled on the BlueSender-FE Scripts/release_to_cdn.sh flow: build → archive
# → export → notarize → DMG + ZIP → Sparkle EdDSA sign → appcast scrape/update →
# release notes → confirm → publish. That last step differs: BlueSender-FE
# uploads to its own S3 bucket, which isn't ours. CatchMatch publishes to
# GitHub Pages instead, by committing into the michelstorms.com site repo (#121).
#
# USAGE:
#   release_to_cdn.sh --version /path/to/CatchMatch.app   # Full release
#   release_to_cdn.sh --build /path/to/CatchMatch.app     # DMG only
#   release_to_cdn.sh --test --version /path/to/app       # Dry run
#   release_to_cdn.sh --version -m "Custom message" /path/to/app
#   release_to_cdn.sh --version -m "" /path/to/app        # Generic message
#
# MODES:
#   --version   Full release: DMG + ZIP + Sparkle appcast (user-facing changes)
#   --build     DMG only: no Sparkle auto-update (internal changes)
#
# OPTIONS:
#   -m, --message   Custom release message ("" for generic "Bug fixes and improvements")
#   --ai-notes      Generate user-facing release notes via Claude based on all
#                   commits since the last appcast version. -m wins if both set;
#                   falls back to latest git commit message if Claude fails.
#
# Publishing (GitHub Pages, #121):
#   The feed lives under michelstorms.com/catchmatch/sparkle/, served straight
#   out of the site repo. Defaults need no environment at all; override with:
#     CM_SITE_REPO     path to the site checkout (default ~/Source/stormychel.github.io)
#     CM_SITE_BRANCH   publishing branch (default main)
#     CM_CDN_BASE      public base URL (default https://michelstorms.com/catchmatch/sparkle)
#   SUFeedURL is compiled into every shipped copy, so CM_CDN_BASE must keep
#   matching the Info.plist. Changing it strands everyone already running.
#
# REQUIREMENTS:
# - Xcode + command line tools
# - "Developer ID Application: MICHEL STORMS (4VYV5C3L3Y)" in the keychain
# - Stored notarytool keychain profile (default "notary-profile",
#   override with CM_NOTARY_PROFILE). Create once with:
#     xcrun notarytool store-credentials notary-profile
# - For --version: the "catchmatch" Sparkle EdDSA key in the login Keychain
#   (override the account with CM_SPARKLE_ACCOUNT), and Sparkle's sign_update
#   binary in DerivedData (built by SPM
#   once Sparkle is added — see docs/RELEASE.md)
# - For publishing: a clean-enough checkout of stormychel.github.io on its
#   publishing branch, with push rights (the script commits and pushes)
#
# PUBLISHED LAYOUT (inside the site repo, served at CM_CDN_BASE):
#     catchmatch/sparkle/appcast-v2.xml
#     catchmatch/sparkle/releases/CatchMatch_v{version}_{build}.zip
#     catchmatch/sparkle/releases/CatchMatch_latest.dmg
#     catchmatch/sparkle/notes/catchmatch-{version}.html
################################################################################

set -e

TEST_MODE=0
RELEASE_TYPE=""
CUSTOM_MESSAGE=""
USE_CUSTOM_MESSAGE=0
USE_AI_NOTES=0

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --test)
            TEST_MODE=1
            shift
            ;;
        --version)
            RELEASE_TYPE="version"
            shift
            ;;
        --build)
            RELEASE_TYPE="build"
            shift
            ;;
        -m|--message)
            USE_CUSTOM_MESSAGE=1
            CUSTOM_MESSAGE="$2"
            shift 2
            ;;
        --ai-notes)
            USE_AI_NOTES=1
            shift
            ;;
        *)
            APP_PATH="$1"
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$RELEASE_TYPE" ]; then
    echo "❌ ERROR: Release type required"
    echo ""
    echo "Usage: release_to_cdn.sh [options] --version|--build [/path/to/CatchMatch.app]"
    echo ""
    echo "RELEASE TYPES (required):"
    echo "  --version       Full release: DMG + Sparkle auto-update (for user-facing changes)"
    echo "  --build         DMG only: no Sparkle update (for internal/non-user-facing changes)"
    echo ""
    echo "OPTIONS:"
    echo "  --test          Dry run, no uploads"
    echo "  -m, --message   Custom release message for Sparkle notes"
    echo "                  • Omit flag entirely: uses git commit message"
    echo "                  • -m \"text\": uses \"New version X.Y.Z - text\""
    echo "                  • -m \"\": uses \"New version X.Y.Z - Bug fixes and improvements\""
    echo "  --ai-notes      Generate user-facing release notes via Claude based on"
    echo "                  all commits since the last appcast version. -m wins"
    echo "                  if both are set; falls back to latest git commit"
    echo "                  message if Claude fails."
    echo ""
    echo "APP PATH (optional):"
    echo "  Pass an existing built CatchMatch.app as the last positional arg."
    echo "  When omitted, the script archives + exports a fresh Release build"
    echo "  (and notarizes it, unless --test is set)."
    echo ""
    echo "EXAMPLES:"
    echo "  release_to_cdn.sh --version                           # Build fresh + notarize + ship"
    echo "  release_to_cdn.sh --version -m \"New feature\""
    echo "  release_to_cdn.sh --version -m \"\"                     # Generic message"
    echo "  release_to_cdn.sh --version --ai-notes                # Claude-generated notes"
    echo "  release_to_cdn.sh --build                             # DMG only, no Sparkle"
    echo "  release_to_cdn.sh --test --version --ai-notes         # Dry run, no notarize/upload"
    echo "  release_to_cdn.sh --version /path/to/prebuilt.app     # Skip build, use existing"
    exit 1
fi

# Resolve symlinks so SCRIPT_DIR points at the real script's directory —
# ExportOptions.plist lives next to the canonical release_to_cdn.sh, and
# invoking via a symlink would otherwise land in the symlink's directory.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"

# Resolve from the script, not the cwd: under set -e a failing rev-parse in an
# unrelated directory would otherwise kill the script without a message.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
    echo "❌ ERROR: not in a git repository — cannot locate CatchMatch.xcodeproj" >&2
    exit 1
fi

# ── Build (when no APP_PATH was passed) ─────────────────────────────────────

if [ -z "$APP_PATH" ]; then
    # The Xcode project still lives at dlp2music/CatchMatch.xcodeproj — the
    # repo subdir kept its historical name even though the shipped product is
    # CatchMatch.app.
    XCODE_PROJECT="$REPO_ROOT/dlp2music/CatchMatch.xcodeproj"
    SCHEME="CatchMatch"
    ARCHIVE_PATH="/tmp/CatchMatch.xcarchive"
    EXPORT_PATH="/tmp/CatchMatchExport"
    EXPORT_OPTIONS="$SCRIPT_DIR/ExportOptions.plist"

    if [ ! -f "$EXPORT_OPTIONS" ]; then
        echo "❌ ERROR: ExportOptions.plist not found at $EXPORT_OPTIONS" >&2
        exit 1
    fi

    echo ""
    echo "🔨 Archiving (Release)…"
    rm -rf "$ARCHIVE_PATH"
    xcodebuild archive \
        -project "$XCODE_PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        | tail -3
    echo "✔ Archive created"

    echo ""
    echo "📤 Exporting…"
    rm -rf "$EXPORT_PATH"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS" \
        | tail -3

    APP_PATH="$EXPORT_PATH/CatchMatch.app"
    if [ ! -d "$APP_PATH" ]; then
        echo "❌ ERROR: Exported app not found at $APP_PATH" >&2
        exit 1
    fi
    echo "✔ Export complete"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "❌ ERROR: App bundle not found at: $APP_PATH"
    exit 1
fi

# ── Notarize + staple (always, unless --test) ───────────────────────────────
# Runs for both freshly-built and prebuilt .app inputs so the prebuilt path
# (release_to_cdn.sh --version /path/to/CatchMatch.app) can't ship an
# unnotarized bundle. Idempotent: a bundle that's already stapled
# (`xcrun stapler validate` succeeds) is left alone, so re-running the script
# against an export that was already notarized in a previous run doesn't
# re-submit it to Apple.

NOTARY_PROFILE="${CM_NOTARY_PROFILE:-notary-profile}"

if [ "$TEST_MODE" -eq 1 ]; then
    echo ""
    echo "⚠ TEST MODE — skipping notarization"
elif xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
    echo ""
    echo "✔ Bundle is already stapled — skipping notarization"
else
    echo ""
    echo "🔏 Notarizing (profile: $NOTARY_PROFILE)…"
    NOTARIZE_ZIP="/tmp/catchmatch_notarize_$$.zip"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARIZE_ZIP"

    if ! xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait; then
        rm -f "$NOTARIZE_ZIP"
        echo "❌ ERROR: notarization failed" >&2
        echo "   Hint: ensure the profile exists with:" >&2
        echo "     xcrun notarytool store-credentials $NOTARY_PROFILE" >&2
        exit 1
    fi
    rm -f "$NOTARIZE_ZIP"

    xcrun stapler staple "$APP_PATH"
    echo "✔ Notarized + stapled"
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"

MARKETING_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
BUILD_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")

ZIP_NAME="CatchMatch_v${MARKETING_VERSION}_${BUILD_VERSION}.zip"
DMG_NAME="CatchMatch_latest.dmg"

APP_DIR=$(dirname "$APP_PATH")
ZIP_PATH="$APP_DIR/$ZIP_NAME"
DMG_PATH="$APP_DIR/$DMG_NAME"

# Where the feed is published. The default is the real one — this URL is baked
# into every shipped copy as SUFeedURL and can never move (#121).
CDN_BASE="${CM_CDN_BASE:-https://michelstorms.com/catchmatch/sparkle}"
SITE_REPO="${CM_SITE_REPO:-$HOME/Source/stormychel.github.io}"
SITE_BRANCH="${CM_SITE_BRANCH:-main}"
SITE_PREFIX="catchmatch/sparkle"

if [ -n "$CDN_BASE" ]; then
    ZIP_URL="$CDN_BASE/releases/$ZIP_NAME"
    NOTES_FILE="catchmatch-${MARKETING_VERSION}.html"
    NOTES_URL="$CDN_BASE/notes/$NOTES_FILE"
else
    ZIP_URL=""
    NOTES_FILE="catchmatch-${MARKETING_VERSION}.html"
    NOTES_URL=""
fi

###############################################################################
# ZIP
###############################################################################

echo ""
echo "📦 CatchMatch Release"
echo "---------------------------------------------"
echo "Version: $MARKETING_VERSION ($BUILD_VERSION)"
echo "Type:    $RELEASE_TYPE"
echo "Test:    $TEST_MODE"
if [ "$RELEASE_TYPE" = "version" ]; then
    echo "ZIP:     $ZIP_NAME"
    if [ "$USE_CUSTOM_MESSAGE" -eq 1 ]; then
        if [ -z "$CUSTOM_MESSAGE" ]; then
            echo "Message: (generic) Bug fixes and improvements"
        else
            echo "Message: $CUSTOM_MESSAGE"
        fi
    else
        echo "Message: (from git commit)"
    fi
fi

if [ "$RELEASE_TYPE" = "version" ]; then
    echo ""
    echo "🧳 Creating ZIP…"
    rm -f "$ZIP_PATH"
    ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    echo "✔ ZIP created"
fi

###############################################################################
# DMG
###############################################################################

echo ""
echo "💿 Creating DMG…"

BG_IMAGE="$REPO_ROOT/dmg_assets/catchmatch-dmg-background.png"
if [ ! -f "$BG_IMAGE" ]; then
    echo "❌ Background image not found: $BG_IMAGE"
    echo "   Regenerate with:"
    echo "     swiftc -parse-as-library Scripts/generate_dmg_background.swift -o /tmp/generate_dmg_background && /tmp/generate_dmg_background"
    exit 1
fi

hdiutil detach "/Volumes/CatchMatch" 2>/dev/null || true

TMP_DMG_DIR=$(mktemp -d)
cp -R "$APP_PATH" "$TMP_DMG_DIR/CatchMatch.app"
ln -s /Applications "$TMP_DMG_DIR/Applications"

mkdir "$TMP_DMG_DIR/.background"
cp "$BG_IMAGE" "$TMP_DMG_DIR/.background/background.png"

TMP_DMG="/tmp/catchmatch_temp_$$.dmg"
# Create an EMPTY read/write image (no -srcfolder), attach it, then copy the
# payload into the mounted volume. Mirroring the BlueSender-FE fix:
# `hdiutil create -srcfolder` races with Spotlight/Gatekeeper still scanning
# the freshly notarized+stapled .app in the source dir and intermittently
# fails with "hdiutil: create failed - Resource busy".
hdiutil create -volname "CatchMatch" \
    -fs HFS+ \
    -size 200m \
    "$TMP_DMG"

DEVICE=$(hdiutil attach "$TMP_DMG" -readwrite -noverify -noautoopen | egrep '^/dev/' | sed 1q | awk '{print $1}')
sleep 2

cp -R "$TMP_DMG_DIR"/. "/Volumes/CatchMatch/"
rm -rf "$TMP_DMG_DIR"

ICON_SRC="$APP_PATH/Contents/Resources/AppIcon.icns"
if [ -f "$ICON_SRC" ]; then
    cp "$ICON_SRC" "/Volumes/CatchMatch/.VolumeIcon.icns"
    SetFile -c icnC "/Volumes/CatchMatch/.VolumeIcon.icns"
    SetFile -a C "/Volumes/CatchMatch"
fi

SetFile -a V "/Volumes/CatchMatch/.background"

osascript <<EOF
tell application "Finder"
  tell disk "CatchMatch"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 100, 900, 700}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 100
    set background picture of viewOptions to file ".background:background.png"
    set position of item "CatchMatch.app" of container window to {350, 160}
    set position of item "Applications" of container window to {350, 400}
    update without registering applications
    delay 2
    close
  end tell
end tell
EOF

hdiutil detach "$DEVICE"
# hdiutil convert refuses to overwrite an existing output file. Re-runs against
# the same APP_DIR (notably the prebuilt-app path) leave the previous
# CatchMatch_latest.dmg behind, so clear it first.
rm -f "$DMG_PATH"
hdiutil convert "$TMP_DMG" -format UDZO -o "$DMG_PATH"

codesign --sign "Developer ID Application: MICHEL STORMS (4VYV5C3L3Y)" --timestamp --force "$DMG_PATH"
rm -f "$TMP_DMG"

# The DMG is what customers download, so it needs its own ticket: a stapled
# app inside a signed-but-unnotarized DMG is still refused by Gatekeeper when
# the quarantined image is opened ("Apple cannot check it…").
if [ "$TEST_MODE" -eq 1 ]; then
    echo "⚠ TEST MODE — skipping DMG notarization"
else
    echo "🔏 Notarizing DMG (profile: $NOTARY_PROFILE)…"
    if ! xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait; then
        echo "❌ ERROR: DMG notarization failed" >&2
        exit 1
    fi
    xcrun stapler staple "$DMG_PATH"
    echo "✔ DMG notarized + stapled"
fi

echo "✔ DMG created"

###############################################################################
# Sparkle signing + appcast (--version only)
###############################################################################

if [ "$RELEASE_TYPE" = "version" ]; then
    # Taken from the app we are actually shipping rather than hardcoded: an
    # appcast claiming a higher minimum than the binary silently withholds the
    # update from everyone in between, and nothing would report that (#124).
    # Only a --version release has an appcast, so a --build release is never
    # stopped over a value it does not consult.
    MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$INFO_PLIST" 2>/dev/null)
    if [ -z "$MIN_OS" ]; then
        echo "❌ ERROR: the app declares no LSMinimumSystemVersion; refusing to guess one for the appcast" >&2
        exit 1
    fi

    echo ""
    echo "🔍 Locating Sparkle sign_update…"
    # Prefer CatchMatch's own DerivedData so we don't pick up an older Sparkle
    # checked out by another project.
    SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData/CatchMatch-* -type f -name "sign_update" -not -path "*/old_dsa_scripts/*" 2>/dev/null | head -n 1)
    [ -z "$SIGN_UPDATE" ] && SIGN_UPDATE=$(find ~/Library/Developer/Xcode/DerivedData -type f -name "sign_update" -not -path "*/old_dsa_scripts/*" 2>/dev/null | head -n 1)
    if [ -z "$SIGN_UPDATE" ]; then
        echo "❌ sign_update not found in DerivedData."
        echo "   Build the app at least once in Xcode after adding the Sparkle SPM"
        echo "   dependency — see docs/RELEASE.md for the one-time setup."
        exit 1
    fi

    echo ""
    echo "🔐 Signing ZIP…"
    # CatchMatch has its own EdDSA key (Keychain account "catchmatch"), matching
    # SUPublicEDKey in dlp2music/CatchMatch-Info.plist. #100
    SIGN_OUTPUT=$("$SIGN_UPDATE" --account "${CM_SPARKLE_ACCOUNT:-catchmatch}" "$ZIP_PATH")

    SIG=$(echo "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
    LEN=$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')

    ###############################################################################
    # Release notes
    ###############################################################################

    NOTES_TMP_PATH="/tmp/$NOTES_FILE"

    # ── Helpers ─────────────────────────────────────────────────────────────

    # Last shipped version from the live appcast; empty string on miss.
    # Returns empty when CDN_BASE is unset (no feed to scrape).
    last_appcast_version() {
        if [ -z "$CDN_BASE" ]; then
            return 0
        fi
        curl -fsS "$CDN_BASE/appcast-v2.xml" 2>/dev/null \
            | sed -n 's/.*sparkle:shortVersionString="\([^"]*\)".*/\1/p' \
            | head -1
    }

    # Commit SHA for "New version X.Y.Z - …" or fallback to "New build N - …".
    commit_for_release() {
        local v="$1"
        local sha
        sha=$(git log --all --oneline --grep="^New version $v " --format="%H" | head -1)
        if [ -z "$sha" ]; then
            sha=$(git log --all --oneline --grep="^New build $v " --format="%H" | head -1)
        fi
        echo "$sha"
    }

    # Pipe commits since $1 (commit SHA, exclusive) through Claude.
    # Echoes markdown bullets on success, empty on failure.
    generate_ai_notes() {
        local since_sha="$1"
        local commit_log
        commit_log=$(git log --no-merges --reverse --pretty=format:"%h %s" "${since_sha}..HEAD")
        if [ -z "$commit_log" ]; then
            return 0
        fi

        if ! command -v claude >/dev/null 2>&1; then
            echo "⚠ claude CLI not on PATH — skipping AI notes" >&2
            return 0
        fi

        local prompt
        prompt=$(cat <<'PROMPT_EOF'
You are writing user-facing Sparkle release notes for the CatchMatch macOS app, which adds recordings, purchases and openly licensed media to their Apple Music and Apple TV libraries. Never name a streaming service or video site in the notes.

Below is the git commit log between the last shipped version and this new release. Produce 3–7 markdown bullet points describing what changed for end users.

Rules:

ALWAYS INCLUDE — these are human-curated release summaries and are by definition user-facing:
- Any commit whose subject starts with "New version X.Y.Z - <desc>"
- Any commit whose subject starts with "New build N - <desc>"
Use the text after the dash as the basis for your bullet. Never drop these commits.

May skip — purely internal work that doesn't affect what users see or do:
- Refactors, tests, CI, dependency-pin bumps, build/release scripts, code-style fixes
- Doc-only edits (README, CLAUDE.md, docs/*.md), unless the doc change reflects a user-visible behavior change
- Non-release version/build number bumps that aren't paired with a "New version"/"New build" subject

Other rules:
- One bullet per user-visible change, or a tight grouping of related changes
- Plain user-facing language. No jargon. No issue or PR numbers
- Each bullet under 100 characters where reasonable
- Output ONLY the bullets, one per line, no preamble, no trailing summary, no headers

Commits (oldest first):
PROMPT_EOF
)

        local full_prompt
        full_prompt=$(printf "%s\n%s\n" "$prompt" "$commit_log")

        echo "Calling Claude (this can take a few seconds)…" >&2
        # Don't let claude failures (auth, quota, network) abort the release —
        # set -e would otherwise kill the script before the git fallback runs.
        local out
        out=$(claude -p "$full_prompt" --output-format text < /dev/null 2>/dev/null) || out=""

        echo "$out" | sed -e '/./,$!d'
    }

    # ── Determine release header / body ─────────────────────────────────────
    HEADER=""
    BODY=""

    if [ "$USE_CUSTOM_MESSAGE" -eq 1 ]; then
        # Explicit -m always wins.
        if [ -z "$CUSTOM_MESSAGE" ]; then
            HEADER="New version $MARKETING_VERSION - Bug fixes and improvements"
        else
            HEADER="New version $MARKETING_VERSION - $CUSTOM_MESSAGE"
        fi
        BODY=""
    elif [ "$USE_AI_NOTES" -eq 1 ]; then
        echo ""
        echo "🤖 Generating AI release notes…"
        LAST_VER=$(last_appcast_version)
        if [ -z "$LAST_VER" ]; then
            echo "⚠ Could not determine last appcast version — falling back to git commit." >&2
        else
            echo "   last shipped: $LAST_VER"
            SINCE_SHA=$(commit_for_release "$LAST_VER")
            if [ -z "$SINCE_SHA" ]; then
                echo "⚠ No commit found for 'New version $LAST_VER' — falling back to git commit." >&2
            else
                AI_BODY=$(generate_ai_notes "$SINCE_SHA")
                if [ -n "$AI_BODY" ]; then
                    HEADER="New version $MARKETING_VERSION"
                    BODY="$AI_BODY"
                else
                    echo "⚠ Claude returned empty notes — falling back to git commit." >&2
                fi
            fi
        fi
    fi

    # Final fallback — use latest git commit message
    if [ -z "$HEADER" ]; then
        FULL_COMMIT_MSG=$(git log -1 --pretty=%B)
        HEADER=$(echo "$FULL_COMMIT_MSG" | sed -n '1p')
        BODY=$(echo "$FULL_COMMIT_MSG" | sed '1d')
    fi

    # ── Preview release notes before writing/uploading ──────────────────────
    echo ""
    echo "📝 Release notes preview:"
    echo "─────────────────────────────────────────────"
    echo "Title: $HEADER"
    echo ""
    if [ -z "$BODY" ]; then
        echo "(no body)"
    else
        echo "$BODY"
    fi
    echo "─────────────────────────────────────────────"

    cat > "$NOTES_TMP_PATH" <<EOF
<!DOCTYPE html>
<html><body>
<h1>$HEADER</h1>
<pre>$BODY</pre>
</body></html>
EOF

    ###############################################################################
    # Appcast v2
    ###############################################################################

    APPCAST_FILE="appcast-v2.xml"

    if [ -n "$CDN_BASE" ]; then
        echo ""
        echo "🔽 Downloading the live ${APPCAST_FILE}…"

        HTTP_STATUS=$(curl -s -w "%{http_code}" -o appcast_existing.xml "$CDN_BASE/$APPCAST_FILE")

        if [ "$HTTP_STATUS" = "200" ]; then
            echo "✔ Found existing $APPCAST_FILE"
            cp appcast_existing.xml appcast_new.xml
        else
            # Don't seed from $REPO_ROOT/appcast.xml — the committed copy is a
            # bare <channel> skeleton with no <item>/<enclosure>, so the sed
            # substitutions below would noop and we'd publish an empty feed.
            # Always start from the inline template on first seed.
            echo "⚠ $APPCAST_FILE not live yet (HTTP $HTTP_STATUS), creating fresh appcast"
            cat > appcast_new.xml <<APPCAST_TEMPLATE
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="https://sparkle-project.org/xmlns/sparkle"
     xmlns:dc="http://purl.org/dc/elements/1.1/">

  <channel>
    <title>CatchMatch Updates</title>
    <link>$CDN_BASE/$APPCAST_FILE</link>
    <description>Release feed for CatchMatch</description>
    <language>en</language>
    <lastBuildDate>$(date -u '+%a, %d %b %Y %H:%M:%S +0000')</lastBuildDate>

    <item>
      <title>PLACEHOLDER</title>
      <sparkle:releaseNotesLink>PLACEHOLDER</sparkle:releaseNotesLink>
      <pubDate>$(date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>

      <enclosure
          url="PLACEHOLDER"
          sparkle:shortVersionString="0.0.0"
          sparkle:version="0"
          sparkle:minimumSystemVersion="$MIN_OS"
          sparkle:os="macos"
          sparkle:edSignature="PLACEHOLDER"
          length="0"
          type="application/octet-stream" />

      <sparkle:minimumAutoupdateVersion>2.0</sparkle:minimumAutoupdateVersion>
    </item>

  </channel>
</rss>
APPCAST_TEMPLATE
        fi

        sed -i "" \
          -e "/<title>.*Updates.*<\/title>/!s|<title>.*</title>|<title>$HEADER</title>|" \
          -e "s|url=\"[^\"]*\"|url=\"$ZIP_URL\"|" \
          -e "s|<sparkle:releaseNotesLink>.*</sparkle:releaseNotesLink>|<sparkle:releaseNotesLink>$NOTES_URL</sparkle:releaseNotesLink>|" \
          -e "s|sparkle:edSignature=\"[^\"]*\"|sparkle:edSignature=\"$SIG\"|" \
          -e "s|length=\"[^\"]*\"|length=\"$LEN\"|" \
          -e "s|sparkle:shortVersionString=\"[^\"]*\"|sparkle:shortVersionString=\"$MARKETING_VERSION\"|" \
          -e "s|sparkle:version=\"[^\"]*\"|sparkle:version=\"$BUILD_VERSION\"|" \
          -e "s|sparkle:minimumSystemVersion=\"[^\"]*\"|sparkle:minimumSystemVersion=\"$MIN_OS\"|" \
          appcast_new.xml
    else
        # Only reachable if someone deliberately empties CM_CDN_BASE; the
        # default is the live feed. Without a base URL the enclosure would
        # point nowhere, so build no appcast at all rather than a broken one.
        echo ""
        echo "⚠ CM_CDN_BASE is empty — skipping appcast scrape/update."
        echo "   The DMG and ZIP are still produced; nothing will be published."
    fi
fi

###############################################################################
# TEST MODE STOP
###############################################################################

if [ "$TEST_MODE" -eq 1 ]; then
  echo ""
  echo "🧪 TEST MODE — no uploads"
  echo "DMG:      $DMG_PATH"
  if [ "$RELEASE_TYPE" = "version" ]; then
    echo "ZIP:      $ZIP_PATH"
    echo "NOTES:    $NOTES_TMP_PATH"
    [ -n "$CDN_BASE" ] && echo "APPCAST:  appcast_new.xml → appcast-v2.xml"
  fi
  exit 0
fi

###############################################################################
# Site repo gate
###############################################################################
#
# Publishing means committing into the site repo, so bail out before the
# confirmation prompt if that checkout isn't usable. Stopping here still leaves
# every local artifact in place — nothing is lost, the build just isn't live.

site_not_ready() {
    echo ""
    echo "🚧 Not published — local artifacts are ready, but the site repo isn't usable."
    echo "   Reason: $1"
    echo ""
    echo "   DMG:   $DMG_PATH"
    if [ "$RELEASE_TYPE" = "version" ]; then
        echo "   ZIP:   $ZIP_PATH"
        echo "   Notes: $NOTES_TMP_PATH"
    fi
    echo ""
    echo "   Fix that and re-run, or publish by hand into $SITE_PREFIX/."
    exit 0
}

if [ "$RELEASE_TYPE" = "version" ] && [ -z "$CDN_BASE" ]; then
    # No base URL means the appcast step above was skipped, so there is nothing
    # coherent to publish — the feed would advertise an empty enclosure URL.
    # A --build release has no appcast either way, so this doesn't apply to it.
    site_not_ready "CM_CDN_BASE is empty, so no appcast was built"
fi

# Not `-d .git`: in a linked worktree that's a file pointing at the real gitdir.
if ! git -C "$SITE_REPO" rev-parse --git-dir >/dev/null 2>&1; then
    site_not_ready "no git checkout at $SITE_REPO (override with CM_SITE_REPO)"
fi

SITE_CURRENT_BRANCH=$(git -C "$SITE_REPO" rev-parse --abbrev-ref HEAD)
if [ "$SITE_CURRENT_BRANCH" != "$SITE_BRANCH" ]; then
    # Committing onto a feature branch would publish nothing and quietly mix the
    # release into unrelated work.
    site_not_ready "$SITE_REPO is on '$SITE_CURRENT_BRANCH', not the publishing branch '$SITE_BRANCH'"
fi

# A merge, rebase, cherry-pick or revert left half-finished would be *completed*
# by our commit, under our message, silently taking someone's unrelated work
# with it — and the conflicts needn't be under our prefix for that to happen.
SITE_GIT_DIR=$(git -C "$SITE_REPO" rev-parse --absolute-git-dir)
for marker in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG \
              rebase-merge rebase-apply; do
    if [ -e "$SITE_GIT_DIR/$marker" ]; then
        site_not_ready "$SITE_REPO has an operation in progress ($marker); finish or abort it first"
    fi
done

# Only our own prefix is ever staged, so unrelated edits in that checkout are
# left alone — but a half-finished edit *inside* the prefix would be swept into
# the release commit. --porcelain catches untracked files too, so leftovers from
# an aborted run block a retry rather than riding along with it.
if [ -n "$(git -C "$SITE_REPO" status --porcelain -- "$SITE_PREFIX")" ]; then
    site_not_ready "$SITE_REPO has uncommitted changes under $SITE_PREFIX/"
fi

###############################################################################
# Upload confirmation
###############################################################################

SITE_DIR="$SITE_REPO/$SITE_PREFIX"

echo ""
echo "📦 Ready to publish to GitHub Pages:"
echo "   Repo:   $SITE_REPO ($SITE_BRANCH)"
echo "   • DMG:     $DMG_PATH"
echo "             → $SITE_PREFIX/releases/$DMG_NAME"
if [ "$RELEASE_TYPE" = "version" ]; then
    echo "   • ZIP:     $ZIP_PATH"
    echo "             → $SITE_PREFIX/releases/$ZIP_NAME"
    echo "   • Notes:   $NOTES_TMP_PATH"
    echo "             → $SITE_PREFIX/notes/$NOTES_FILE"
    echo "   • Appcast: appcast_new.xml"
    echo "             → $SITE_PREFIX/appcast-v2.xml"
fi
echo ""
echo "   This commits and pushes to $SITE_BRANCH — it goes live."
read -r -p "Proceed with publish? [y/N] " UPLOAD_CONFIRM
case "$UPLOAD_CONFIRM" in
    y|Y|yes|Yes|YES) ;;
    *)
        echo "✋ Publish cancelled — nothing was committed."
        exit 0
        ;;
esac

###############################################################################
# Publish (commit into the Pages site repo)
###############################################################################

echo ""
echo "📤 Copying into ${SITE_REPO}…"

mkdir -p "$SITE_DIR/releases" "$SITE_DIR/notes"
cp "$DMG_PATH" "$SITE_DIR/releases/$DMG_NAME"

if [ "$RELEASE_TYPE" = "version" ]; then
    cp "$ZIP_PATH"       "$SITE_DIR/releases/$ZIP_NAME"
    cp "$NOTES_TMP_PATH" "$SITE_DIR/notes/$NOTES_FILE"
    # The appcast is written last: until it names the new ZIP, no installed copy
    # can be told about a file that isn't uploaded yet.
    cp appcast_new.xml   "$SITE_DIR/appcast-v2.xml"
fi

# Staged by prefix, so anything else in flight in that checkout stays out of it.
git -C "$SITE_REPO" add -- "$SITE_PREFIX"

if git -C "$SITE_REPO" diff --cached --quiet -- "$SITE_PREFIX"; then
    echo "⚠ Nothing changed under $SITE_PREFIX/ — already published?"
    exit 0
fi

if [ "$RELEASE_TYPE" = "version" ]; then
    SITE_COMMIT_MSG="- catchmatch: publish $MARKETING_VERSION ($BUILD_VERSION) — appcast, ZIP, DMG and notes"
else
    SITE_COMMIT_MSG="- catchmatch: publish the $MARKETING_VERSION ($BUILD_VERSION) DMG (no auto-update)"
fi

git -C "$SITE_REPO" commit -q -m "$SITE_COMMIT_MSG"
echo "✔ Committed $(git -C "$SITE_REPO" rev-parse --short HEAD) in $SITE_REPO"

if git -C "$SITE_REPO" push -q origin "$SITE_BRANCH"; then
    echo "✔ Pushed — Pages usually serves it within a minute"
else
    echo ""
    echo "⚠ Push rejected. The release is committed locally but is NOT live."
    echo "   Most likely the branch is behind; in $SITE_REPO run:"
    echo "     git pull --rebase && git push"
    exit 1
fi

echo ""
echo "🔗 Verify once Pages has deployed:"
if [ "$RELEASE_TYPE" = "version" ]; then
    echo "   $CDN_BASE/appcast-v2.xml"
fi
echo "   $CDN_BASE/releases/$DMG_NAME"

echo ""
if [ "$RELEASE_TYPE" = "version" ]; then
    echo "🎉 DONE — Full release published (DMG + Sparkle auto-update)"
else
    echo "🎉 DONE — Build published (DMG only, no auto-update)"
fi

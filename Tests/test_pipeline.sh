#!/bin/bash
#
#  test_pipeline.sh
#  CatchMatch
#
#  Created by Michel Storms on 21/09/2026.
#
# End-to-end tests for dlp2music.sh, run against stub yt-dlp / ffmpeg / ffprobe
# and temporary import folders (CM_TOOL_PATH, CM_MUSIC_IMPORT, CM_TV_IMPORT).
# Nothing is downloaded and the real Music and TV libraries are never touched.
#
# Usage: bash Tests/test_pipeline.sh [-v]     (#109)

set -u

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../dlp2music/dlp2music/Resources/dlp2music.sh"
# The app runs the script with /bin/bash — bash 3.2 on macOS — so the tests do
# too. With a newer bash first on PATH, a bash-4-only construct would pass here
# and fail on every customer's Mac (#80).
VERBOSE=0
[[ "${1:-}" == "-v" ]] && VERBOSE=1

PASS=0
FAIL=0
TEMP_DIRS=()
cleanup() { for d in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do rm -rf "$d"; done; }
trap cleanup EXIT INT TERM
LAST_OUTPUT=""
LAST_STATUS=0

# run <env assignments…> -- <script args…>
run() {
    local env_pairs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do env_pairs+=("$1"); shift; done
    shift || true

    MUSIC_DIR=$(mktemp -d)
    TV_DIR=$(mktemp -d)
    DOWNLOADS_DIR=$(mktemp -d)
    TEMP_DIRS+=("$MUSIC_DIR" "$TV_DIR" "$DOWNLOADS_DIR")
    LAST_OUTPUT=$(env "${env_pairs[@]+"${env_pairs[@]}"}" \
        CM_TOOL_PATH="$DIR/stubs" \
        CM_MUSIC_IMPORT="$MUSIC_DIR" \
        CM_TV_IMPORT="$TV_DIR" \
        CM_DOWNLOADS="$DOWNLOADS_DIR" \
        /bin/bash "$SCRIPT" "$@" 2>&1)
    LAST_STATUS=$?
    [[ $VERBOSE -eq 1 ]] && printf '%s\n' "$LAST_OUTPUT"
    return 0
}

ok()   { PASS=$((PASS+1)); printf '  ✓ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ✗ %s\n     %s\n' "$1" "$2"; }

# count_files <dir> <extension>
count_files() {
    local n
    n=$(find "$1" -maxdepth 1 -type f -name "*.$2" 2>/dev/null | wc -l)
    echo "$((n))"
}

expect_count() { # expect_count <dir> <ext> <expected> <label>
    local actual; actual=$(count_files "$1" "$2")
    if [[ "$actual" -eq "$3" ]]; then ok "$4"; else bad "$4" "expected $3 .$2 file(s), found $actual"; fi
}

expect_output() { # expect_output <needle> <label>
    if grep -qF -- "$1" <<<"$LAST_OUTPUT"; then ok "$2"; else bad "$2" "output did not contain: $1"; fi
}

expect_status() { # expect_status <code> <label>
    if [[ "$LAST_STATUS" -eq "$1" ]]; then ok "$2"; else bad "$2" "expected exit $1, got $LAST_STATUS"; fi
}

echo "Destinations"
run -- --music-audio "https://example.test/one"
expect_count "$MUSIC_DIR" m4a 1 "--music-audio imports the song"
expect_count "$MUSIC_DIR" mp4 0 "--music-audio imports no music video"
expect_count "$TV_DIR"    mp4 0 "--music-audio leaves Apple TV alone"

run -- --music-video "https://example.test/one"
expect_count "$MUSIC_DIR" mp4 1 "--music-video imports the music video"
expect_count "$MUSIC_DIR" m4a 0 "--music-video imports no song"

run -- --music "https://example.test/one"
expect_count "$MUSIC_DIR" m4a 1 "--music imports the song"
expect_count "$MUSIC_DIR" mp4 1 "--music imports the music video"

run -- --tv "https://example.test/one"
expect_count "$TV_DIR"    mp4 1 "--tv imports to Apple TV"
expect_count "$MUSIC_DIR" mp4 0 "--tv leaves Apple Music alone"

run -- --music-audio --tv "https://example.test/one"
expect_count "$MUSIC_DIR" m4a 1 "song and TV together: song lands in Music"
expect_count "$TV_DIR"    mp4 1 "song and TV together: video lands in TV"

echo "Long-form guard (#83)"
run STUB_DURATION=3600 -- --music --tv "https://example.test/film"
expect_count "$MUSIC_DIR" m4a 0 "a long item keeps its audio out of Music"
expect_count "$MUSIC_DIR" mp4 0 "a long item keeps its music video out of Music"
expect_count "$TV_DIR"    mp4 1 "a long item still reaches Apple TV"
expect_output "too long for the Music library" "it says why"

run STUB_DURATION=3600 -- --music --allow-long-music "https://example.test/film"
expect_count "$MUSIC_DIR" m4a 1 "--allow-long-music overrides the guard"

run STUB_DURATION=1199 -- --music-audio "https://example.test/almost"
expect_count "$MUSIC_DIR" m4a 1 "just under twenty minutes is still a song"

echo "Title override (#50)"
run -- --music-audio --item-title "Given Title" --item-artist "Given Artist" "https://example.test/one"
if find "$MUSIC_DIR" -maxdepth 1 -name "Given Artist - Given Title.m4a" | grep -q .; then
    ok "an accepted name is used for the file"
else
    bad "an accepted name is used for the file" "found: $(ls "$MUSIC_DIR")"
fi

run STUB_ITEMS=3 -- --music-audio --item-title "Given Title" "https://example.test/playlist"
expect_count "$MUSIC_DIR" m4a 3 "a playlist imports every item"
if find "$MUSIC_DIR" -maxdepth 1 -name "Given Title.m4a" | grep -q .; then
    bad "one title is not applied to a whole playlist" "every item would overwrite the last"
else
    ok "one title is not applied to a whole playlist"
fi

run -- --music-audio --item-title "https://example.test/one"
expect_status 2 "--item-title without a value is rejected"

echo "Metadata (#86)"
run STUB_TITLE="Daft Punk - Get Lucky (Official Music Video)" -- --music-audio "https://example.test/one"
if find "$MUSIC_DIR" -maxdepth 1 -name "Daft Punk - Get Lucky.m4a" | grep -q .; then
    ok "the title is cleaned up for the filename"
else
    bad "the title is cleaned up for the filename" "found: $(ls "$MUSIC_DIR")"
fi

run STUB_TITLE="Daft Punk - Get Lucky (Official Music Video)" -- --music-audio --no-clean-metadata "https://example.test/one"
if find "$MUSIC_DIR" -maxdepth 1 -name "*Official Music Video*.m4a" | grep -q .; then
    ok "--no-clean-metadata keeps the raw name"
else
    bad "--no-clean-metadata keeps the raw name" "found: $(ls "$MUSIC_DIR")"
fi

echo "Failure paths"
run STUB_NO_MEDIA=1 -- --music-audio "https://example.test/dead"
expect_output "No media for" "a link that yields nothing is reported"
expect_status 1 "…and the run fails"
expect_count "$MUSIC_DIR" m4a 0 "…and nothing is imported"

run STUB_FFMPEG_FAIL=1 -- --music-audio "https://example.test/one"
expect_status 1 "a failing ffmpeg fails the run"
expect_count "$MUSIC_DIR" m4a 0 "…and imports nothing"

run -- "https://example.test/one"
expect_count "$MUSIC_DIR" m4a 1 "no destination flag defaults to Apple Music: song"
expect_count "$MUSIC_DIR" mp4 1 "no destination flag defaults to Apple Music: music video"

run -- --unknown-flag "https://example.test/one"
expect_status 2 "an unknown flag is rejected"

run -- --music-audio
expect_output "Usage:" "no input prints usage"

echo "Downloads (#111)"
run -- --downloads "https://example.test/one"
expect_count "$DOWNLOADS_DIR" mp4 1 "--downloads alone puts the video in Downloads"
expect_count "$DOWNLOADS_DIR" m4a 0 "…and no song, since none was asked for"
expect_count "$MUSIC_DIR"     mp4 0 "…and nothing in Apple Music"
expect_count "$TV_DIR"        mp4 0 "…and nothing in Apple TV"
expect_output "→ Downloads:" "the run says it went to Downloads"

run -- --music-audio --downloads "https://example.test/one"
expect_count "$DOWNLOADS_DIR" m4a 1 "with Song on, Downloads gets the song"
expect_count "$DOWNLOADS_DIR" mp4 0 "…and not the video"
expect_count "$MUSIC_DIR"     m4a 1 "…and Apple Music still gets its copy"

run -- --music --tv --downloads "https://example.test/one"
expect_count "$DOWNLOADS_DIR" m4a 1 "everything at once: Downloads gets the song"
expect_count "$DOWNLOADS_DIR" mp4 1 "everything at once: Downloads gets the video"
expect_count "$TV_DIR"        mp4 1 "everything at once: Apple TV still gets its copy"

run -- --music-video --downloads "https://example.test/one"
expect_count "$DOWNLOADS_DIR" mp4 1 "with Music Video on, Downloads gets the video"
expect_count "$DOWNLOADS_DIR" m4a 0 "…and no song"

# Explicit choices, independent of the libraries (#164).
run -- --downloads-audio "https://example.test/one"
expect_count "$DOWNLOADS_DIR" m4a 1 "--downloads-audio alone puts the song in Downloads"
expect_count "$DOWNLOADS_DIR" mp4 0 "…and no video"
expect_count "$MUSIC_DIR" m4a 0 "…and nothing in Music"

run -- --downloads-audio --downloads-video "https://example.test/one"
expect_count "$DOWNLOADS_DIR" m4a 1 "both Downloads flags: the song"
expect_count "$DOWNLOADS_DIR" mp4 1 "both Downloads flags: the video"

run -- --music --downloads-video "https://example.test/one"
expect_count "$DOWNLOADS_DIR" mp4 1 "--music with --downloads-video: only the video in Downloads"
expect_count "$DOWNLOADS_DIR" m4a 0 "…not the song, though Music got it"

# The file in Downloads is the processed one, not raw yt-dlp output: it carries
# the cleaned name, which is what the ffmpeg step produced.
run STUB_TITLE="Daft Punk - Get Lucky (Official Music Video)" -- --downloads "https://example.test/one"
if find "$DOWNLOADS_DIR" -maxdepth 1 -name "Daft Punk - Get Lucky.mp4" | grep -q .; then
    ok "the file in Downloads is the processed one, with the cleaned name"
else
    bad "the file in Downloads is the processed one, with the cleaned name" "found: $(ls "$DOWNLOADS_DIR")"
fi

# ~/Downloads is full of the user's own files; nothing there may be overwritten.
run -- --downloads "https://example.test/one"
printf 'not yours to clobber' > "$DOWNLOADS_DIR/Stub Artist - Stub Song.mp4"
LAST_OUTPUT=$(env CM_TOOL_PATH="$DIR/stubs" CM_MUSIC_IMPORT="$MUSIC_DIR" CM_TV_IMPORT="$TV_DIR" \
    CM_DOWNLOADS="$DOWNLOADS_DIR" /bin/bash "$SCRIPT" --downloads "https://example.test/one" 2>&1)
expect_count "$DOWNLOADS_DIR" mp4 2 "an existing file is kept and the new one numbered"
if [[ "$(cat "$DOWNLOADS_DIR/Stub Artist - Stub Song.mp4")" == "not yours to clobber" ]]; then
    ok "…the existing file is untouched"
else
    bad "…the existing file is untouched" "it was overwritten"
fi

# …and it keeps walking: an existing " (2)" doesn't get clobbered either.
run -- --downloads "https://example.test/one"
printf 'original' > "$DOWNLOADS_DIR/Stub Artist - Stub Song.mp4"
printf 'existing 2' > "$DOWNLOADS_DIR/Stub Artist - Stub Song (2).mp4"
printf 'existing 3' > "$DOWNLOADS_DIR/Stub Artist - Stub Song (3).mp4"
LAST_OUTPUT=$(env CM_TOOL_PATH="$DIR/stubs" CM_MUSIC_IMPORT="$MUSIC_DIR" CM_TV_IMPORT="$TV_DIR" \
    CM_DOWNLOADS="$DOWNLOADS_DIR" /bin/bash "$SCRIPT" --downloads "https://example.test/one" 2>&1)
expect_output "Stub Artist - Stub Song (4).mp4" "a taken (2) and (3) means the next one is (4)"
if [[ "$(cat "$DOWNLOADS_DIR/Stub Artist - Stub Song (2).mp4")" == "existing 2" \
   && "$(cat "$DOWNLOADS_DIR/Stub Artist - Stub Song (3).mp4")" == "existing 3" \
   && "$(cat "$DOWNLOADS_DIR/Stub Artist - Stub Song.mp4")" == "original" ]]; then
    ok "…and every file already there is untouched"
else
    bad "…and every file already there is untouched" "one of them was overwritten"
fi

# A film is a perfectly good download, it just isn't a song.
run STUB_DURATION=3600 -- --music --downloads "https://example.test/film"
expect_count "$MUSIC_DIR"     m4a 0 "a long item still stays out of Music"
expect_count "$DOWNLOADS_DIR" m4a 1 "…but still reaches Downloads"

# Someone with no Music library at all must still be able to use the app.
MUSIC_DIR=$(mktemp -d); TV_DIR=$(mktemp -d); DOWNLOADS_DIR=$(mktemp -d)
TEMP_DIRS+=("$MUSIC_DIR" "$TV_DIR" "$DOWNLOADS_DIR")
rmdir "$MUSIC_DIR" "$TV_DIR"
LAST_OUTPUT=$(env CM_TOOL_PATH="$DIR/stubs" CM_MUSIC_IMPORT="$MUSIC_DIR" CM_TV_IMPORT="$TV_DIR" \
    CM_DOWNLOADS="$DOWNLOADS_DIR" /bin/bash "$SCRIPT" --downloads "https://example.test/one" 2>&1)
LAST_STATUS=$?
expect_count "$DOWNLOADS_DIR" mp4 1 "a Downloads-only run works with no Music or TV folder"
expect_status 0 "…and reports success"

# A folder it cannot write to must fail loudly rather than claim success.
MUSIC_DIR=$(mktemp -d); TV_DIR=$(mktemp -d); DOWNLOADS_DIR=$(mktemp -d)
TEMP_DIRS+=("$MUSIC_DIR" "$TV_DIR" "$DOWNLOADS_DIR")
chmod 500 "$DOWNLOADS_DIR"
LAST_OUTPUT=$(env CM_TOOL_PATH="$DIR/stubs" CM_MUSIC_IMPORT="$MUSIC_DIR" CM_TV_IMPORT="$TV_DIR" \
    CM_DOWNLOADS="$DOWNLOADS_DIR" /bin/bash "$SCRIPT" --downloads "https://example.test/one" 2>&1)
LAST_STATUS=$?
expect_status 1 "an unwritable Downloads folder fails the run"
expect_output "Couldn't write to" "…and says so"
chmod 700 "$DOWNLOADS_DIR"
expect_count "$DOWNLOADS_DIR" mp4 0 "…and leaves no half-written file behind"

echo "A long conversion reports how far it has got (#133)"
run STUB_DURATION=600 STUB_FFMPEG_PROGRESS="0 60 150 300 450 600" -- --tv "https://example.test/one"
expect_output "converting: 2:30 of 10:00 (25%)" "progress is shown as time and percentage"
expect_output "converting: 10:00 of 10:00 (100%)" "…through to the end"
expect_count "$TV_DIR" mp4 1 "…and the import still lands"

# ffmpeg reports many times a second; the window gets a line every 5%.
run STUB_DURATION=600 STUB_FFMPEG_PROGRESS="$(seq 0 600 | tr '\n' ' ')" -- --tv "https://example.test/one"
LINES=$(printf '%s\n' "$LAST_OUTPUT" | grep -c "converting:")
# One line per 5% from 5% to 100%: exactly twenty. An upper bound alone would
# pass with no progress at all.
if (( LINES == 20 )); then ok "progress is throttled to one line per 5% (20 lines for 601 reports)"
else FAIL=$((FAIL+1)); printf '  ✗ progress is throttled to one line per 5%% — got %s lines for 601 reports\n' "$LINES"; fi
expect_output "converting: 5:00 of 10:00 (50%)" "…landing on each 5% boundary"
expect_output "converting: 10:00 of 10:00 (100%)" "…and reaching 100% even when updates are dense"

# The probed length can be shorter than what ffmpeg writes. Progress must keep
# coming after 100%, or the tail of the run looks hung again.
run STUB_DURATION=60 STUB_FFMPEG_PROGRESS="0 30 60 75 90 105 120" -- --tv "https://example.test/one"
expect_output "converting: 1:00 of 1:00 (100%)" "a run reaching its expected length says 100%"
expect_output "converting: 1:45" "…and keeps reporting when it runs past it"

run STUB_DURATION=N/A STUB_FFMPEG_PROGRESS="0 30 60 95" -- --tv "https://example.test/one"
expect_output "converting: 1:00" "an unknown length still shows elapsed media time"

# ffmpeg's exit status has to survive the progress pipe. A failing stub also
# writes no file, so "nothing landed" would hold either way — check that the
# run says it failed, which only happens if the status came through.
run STUB_FFMPEG_FAIL=1 -- --tv "https://example.test/one"
expect_output "ffmpeg failed on" "a failing conversion is still reported, progress or not"
expect_status 1 "…and fails the run"

echo "Formats are chosen so Apple's codecs stream-copy (#132)"
# Runs real yt-dlp's own format selection against made-up format lists, offline
# (--load-info-json), using the exact selector the shipped script uses. Checking
# the argument text alone can't tell a good selector from a bad one: a codec
# sort once passed that check while picking VP8 over HEVC.
VIDEO_FORMAT=$(sed -n "s/^VIDEO_FORMAT='\(.*\)'$/\1/p" "$SCRIPT")
REAL_YTDLP=$(command -v yt-dlp || true)
if [[ -z "$VIDEO_FORMAT" ]]; then
    FAIL=$((FAIL+1)); printf '  ✗ %s\n' "the script defines VIDEO_FORMAT"
elif [[ -z "$REAL_YTDLP" ]]; then
    printf '  – skipped: needs a real yt-dlp to run its format selection\n'
else
    FMT_DIR=$(mktemp -d); TEMP_DIRS+=("$FMT_DIR")
    video() { printf '{"format_id":"%s","url":"https://example.test/%s","ext":"mp4","protocol":"https","vcodec":"%s","acodec":"none","width":%s,"height":%s}' "$1" "$1" "$2" "$3" "$4"; }
    audio() { printf '{"format_id":"%s","url":"https://example.test/%s","ext":"%s","protocol":"https","vcodec":"none","acodec":"%s","abr":%s}' "$1" "$1" "$2" "$3" "$4"; }
    formats() { # formats <file> <entries...>
        local f="$FMT_DIR/$1"; shift
        printf '{"id":"x","title":"x","extractor":"generic","extractor_key":"Generic","webpage_url":"https://example.test/x","formats":[%s]}' \
            "$(IFS=,; echo "$*")" > "$f"
    }
    expect_pick() { # expect_pick <file> <format ids> <label>
        local got
        got=$("$REAL_YTDLP" --load-info-json "$FMT_DIR/$1" -f "$VIDEO_FORMAT" \
            --print '%(format_id)s' --simulate --no-warnings 2>&1 | tail -1)
        if [[ "$got" == "$2" ]]; then ok "$3"
        else FAIL=$((FAIL+1)); printf '  ✗ %s\n    wanted %s, got %s\n' "$3" "$2" "$got"; fi
    }
    AUDIO="$(audio aac m4a mp4a.40.2 128),$(audio opus webm opus 160)"

    formats youtube.json "$(video h264-1080 avc1.64002a 1920 1080)" "$(video av1-2160 av01.0.13M.08 3840 2160)" "$AUDIO"
    expect_pick youtube.json "h264-1080+aac" "YouTube: 1080p H.264 and AAC, not 4K AV1 and Opus"

    formats both.json "$(video h264-360 avc1.4d401e 640 360)" "$(video hevc-2160 hvc1.1.6.L150 3840 2160)" "$(video av1-2160 av01.0.13M.08 3840 2160)" "$AUDIO"
    expect_pick both.json "hevc-2160+aac" "a 4K HEVC beats a 360p H.264 — both copy, so resolution decides"

    formats noh264.json "$(video vp8-1080 vp8 1920 1080)" "$(video hevc-2160 hvc1.1.6.L150 3840 2160)" "$AUDIO"
    expect_pick noh264.json "hevc-2160+aac" "without H.264, HEVC is taken over VP8"

    # Extractors spell the same codec differently; each spelling must still
    # count as H.264 or HEVC. The native format is taller than 1080p and sits
    # beside a 1080p VP9: if the spelling were not recognised, the 1080p cap
    # would pick the VP9 instead — so this can't pass by accident.
    for spelling in avc3.640028 h264 AVC1.640028 hevc; do
        formats "spell-$spelling.json" "$(video native-1440 "$spelling" 2560 1440)" \
            "$(video vp9-1080 vp9 1920 1080)" "$(video av1-2160 av01.0.13M.08 3840 2160)" "$AUDIO"
        expect_pick "spell-$spelling.json" "native-1440+aac" "\"$spelling\" is recognised as a codec Apple plays"
    done

    formats foreign.json "$(video vp9-1080 vp9 1920 1080)" "$(video av1-2160 av01.0.13M.08 3840 2160)" "$AUDIO"
    expect_pick foreign.json "vp9-1080+aac" "nothing Apple plays: re-encoded, but capped at 1080p"
fi

echo "Re-encoding uses Apple's hardware encoder, not libx264 (#80)"
# What the packaging step asks ffmpeg for. libx264 is GPL, so it isn't in the
# LGPL ffmpeg the app downloads; a re-encode that asks for it simply fails.
FF_LOG=$(mktemp); TEMP_DIRS+=("$FF_LOG")
package_call() { grep -- "-movflags +faststart" "$FF_LOG" | head -1; }
expect_call() { # expect_call <needle> <label>
    if [[ "$(package_call)" == *"$1"* ]]; then ok "$2"
    else FAIL=$((FAIL+1)); printf '  ✗ %s\n    call: %s\n' "$2" "$(package_call)"; fi
}
reject_call() { # reject_call <needle> <label>
    if [[ "$(package_call)" != *"$1"* ]]; then ok "$2"
    else FAIL=$((FAIL+1)); printf '  ✗ %s\n    call: %s\n' "$2" "$(package_call)"; fi
}

: > "$FF_LOG"; run STUB_VCODEC=av1 STUB_FFMPEG_ARGS_LOG="$FF_LOG" -- --tv "https://example.test/one"
expect_call "-c:v h264_videotoolbox" "an AV1 source is re-encoded with VideoToolbox"
reject_call "libx264" "…never asking for libx264"
expect_call "-b:v 12M" "…at 12 Mbps for 1080p"
expect_call "-allow_sw 1" "…falling back to Apple's software encoder where there is no hardware one"
expect_call "-vf scale='trunc(min(1\\,3840/max(iw\\,ih))" "…scaling anything above 4K down, to even dimensions"
expect_count "$TV_DIR" mp4 1 "…and the import lands"

: > "$FF_LOG"; run STUB_VCODEC=av1 STUB_WIDTH=3840 STUB_HEIGHT=2160 STUB_FFMPEG_ARGS_LOG="$FF_LOG" -- --tv "https://example.test/one"
expect_call "-b:v 40M" "a 4K source gets 40 Mbps"

: > "$FF_LOG"; run STUB_VCODEC=av1 STUB_WIDTH=854 STUB_HEIGHT=480 STUB_FFMPEG_ARGS_LOG="$FF_LOG" -- --tv "https://example.test/one"
expect_call "-b:v 3M" "a 480p source gets 3 Mbps"

# The tier follows the longer side: a portrait 1080x1920 phone video is 1080p,
# not something smaller.
: > "$FF_LOG"; run STUB_VCODEC=av1 STUB_WIDTH=1080 STUB_HEIGHT=1920 STUB_FFMPEG_ARGS_LOG="$FF_LOG" -- --tv "https://example.test/one"
expect_call "-b:v 12M" "a portrait 1080x1920 source is treated as 1080p"

: > "$FF_LOG"; run STUB_VCODEC=av1 STUB_NO_VIDEOTOOLBOX=1 STUB_FFMPEG_ARGS_LOG="$FF_LOG" -- --tv "https://example.test/one"
expect_call "-c:v libx264" "an ffmpeg without VideoToolbox keeps the libx264 path"

: > "$FF_LOG"; run STUB_VCODEC=h264 STUB_FFMPEG_ARGS_LOG="$FF_LOG" -- --tv "https://example.test/one"
expect_call "-c:v copy" "an H.264 source is still copied, not re-encoded"

echo "Test seams are off in an installed app (#109)"
BUNDLE=$(mktemp -d)
TEMP_DIRS+=("$BUNDLE")
mkdir -p "$BUNDLE/CatchMatch.app/Contents/Resources"
cp "$SCRIPT" "$BUNDLE/CatchMatch.app/Contents/Resources/dlp2music.sh"
MUSIC_DIR=$(mktemp -d); TV_DIR=$(mktemp -d); TEMP_DIRS+=("$MUSIC_DIR" "$TV_DIR")
LAST_OUTPUT=$(CM_TOOL_PATH="$DIR/stubs" CM_MUSIC_IMPORT="$MUSIC_DIR" CM_TV_IMPORT="$TV_DIR" \
    /bin/bash "$BUNDLE/CatchMatch.app/Contents/Resources/dlp2music.sh" --music-audio "/nonexistent/file.mov" 2>&1)
expect_output "Ignoring CM_TOOL_PATH" "a copy inside an .app says it is ignoring the seams"
expect_count "$MUSIC_DIR" m4a 0 "…and copies nothing into the folder they named"

printf '\nResults: %d passed, %d failed (of %d)\n' "$PASS" "$FAIL" "$((PASS+FAIL))"
[[ $FAIL -eq 0 ]]

#!/bin/bash
#
# dlp2music.sh
# Usage: dlp2music.sh [--music|--music-audio|--music-video] [--tv]
#                     [--no-clean-metadata] <input> [<input> ...]
#   --music              import audio (.m4a) + video (.mp4) into Apple Music auto-add
#   --music-audio        import only the audio (.m4a) into Apple Music auto-add
#   --music-video        import only the video (.mp4) into Apple Music auto-add
#   --tv                 import video (.mp4) into Apple TV auto-add
#   --downloads          put the processed file in ~/Downloads, matching the libraries
#   --downloads-audio    put the song (.m4a) in ~/Downloads
#   --downloads-video    put the video (.mp4) in ~/Downloads
#   --no-clean-metadata  skip title/artist cleanup; keep raw yt-dlp output
#   --allow-long-music   don't hold long-form video out of the Music library
#   --item-title TITLE   use TITLE instead of the cleaned title (single-item runs)
#   --item-artist ARTIST use ARTIST instead of the cleaned artist (single-item runs)
# Defaults to --music if no destination flag given.
# Each <input> is either a web URL (downloaded via yt-dlp; may resolve to many
# items for playlists/channels/search pages) or a path to a local video file
# (fed straight into the ffmpeg/import steps, no download).

set -u

# ---------- helpers (sourceable) ----------

# clean_metadata RAW_TITLE UPLOADER
# Sets globals CLEAN_TITLE and CLEAN_ARTIST.
clean_metadata() {
    local raw_title="$1"
    local uploader="${2:-}"

    local cleaned
    cleaned=$(printf '%s' "$raw_title" | /usr/bin/perl -CSDA -pe '
        s/\s*[\(\[]\s*official[^)\]]{0,40}(music\s*)?video\s*[\)\]]//gi;
        s/\s*[\(\[]\s*official[^)\]]{0,40}audio\s*[\)\]]//gi;
        s/\s*[\(\[]\s*official\s*[\)\]]//gi;
        s/\s*[\(\[]\s*lyric\s*video\s*[\)\]]//gi;
        s/\s*[\(\[]\s*lyrics?\s*[\)\]]//gi;
        s/\s*[\(\[]\s*audio\s*[\)\]]//gi;
        s/\s*[\(\[]\s*visualizer\s*[\)\]]//gi;
        s/\s*[\(\[]\s*hd\s*[\)\]]//gi;
        s/\s*[\(\[]\s*4k\s*[\)\]]//gi;
        s/\s*[\(\[]\s*hq\s*[\)\]]//gi;
        s/\s*[\(\[]\s*full\s*version\s*[\)\]]//gi;
        s/\s*[\(\[]\s*full\s*hd\s*[\)\]]//gi;
        s/\s*[\(\[]\s*remastered?\s*[\)\]]//gi;
        s/\s+(hd|4k|hq|1080p|720p)\s*$//gi;
        s/\s*\|\s*[A-Za-z0-9]*VEVO\s*$//gi;
        s/\s*\|\s*Official(\s+Channel)?\s*$//gi;
        s/\s*-\s*Topic\s*$//gi;
        s/[\x{1F300}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{1F100}-\x{1F1FF}]//g;
        s/\bft\.?(?=\s|$)/feat./gi;
        s/\bfeaturing\b/feat./gi;
        s/\s+/ /g;
        s/^\s+|\s+$//g;
    ')

    local clean_uploader
    clean_uploader=$(printf '%s' "$uploader" | /usr/bin/perl -CSDA -pe '
        s/\s*-\s*Topic\s*$//gi;
        s/\s*-?\s*VEVO\s*$//gi;
        s/\s*-\s*Official(\s+Channel)?\s*$//gi;
        s/^\s+|\s+$//g;
    ')

    local artist=""
    local title="$cleaned"

    if printf '%s' "$cleaned" | /usr/bin/perl -CSDA -ne 'exit(/\s+[-\x{2013}\x{2014}]\s+/ ? 0 : 1)'; then
        local left right
        left=$(printf '%s' "$cleaned" | /usr/bin/perl -CSDA -pe 's/^(.*?)\s+[-\x{2013}\x{2014}]\s+.*$/$1/;')
        right=$(printf '%s' "$cleaned" | /usr/bin/perl -CSDA -pe 's/^.*?\s+[-\x{2013}\x{2014}]\s+(.*)$/$1/;')

        local right_lc left_lc up_lc
        right_lc=$(printf '%s' "$right" | /usr/bin/tr '[:upper:]' '[:lower:]')
        left_lc=$(printf '%s' "$left"  | /usr/bin/tr '[:upper:]' '[:lower:]')
        up_lc=$(printf '%s' "$clean_uploader" | /usr/bin/tr '[:upper:]' '[:lower:]')

        if [[ -n "$up_lc" && "$right_lc" == "$up_lc" ]]; then
            artist="$right"; title="$left"
        elif [[ -n "$up_lc" && "$left_lc" == "$up_lc" ]]; then
            artist="$left";  title="$right"
        else
            artist="$left";  title="$right"
        fi
    else
        if printf '%s' "$uploader" | /usr/bin/grep -qiE '[-–—][[:space:]]*Topic[[:space:]]*$'; then
            artist="$clean_uploader"
            title="$cleaned"
        fi
    fi

    CLEAN_TITLE="$title"
    CLEAN_ARTIST="$artist"
}

# read_json_fields FILE FIELD [FIELD ...]
# Echoes one line per FIELD, in order, empty when absent. One interpreter and
# one parse for the whole item: the old one-field-per-call version started a
# fresh python3 and re-read the file for every field, which on a playlist is
# hundreds of processes doing the same work.
read_json_fields() {
    local file="$1"; shift
    /usr/bin/python3 - "$file" "$@" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except Exception:
    d = {}
for key in sys.argv[2:]:
    v = d.get(key)
    if v is None:
        print("")
    elif isinstance(v, list):
        print(", ".join(str(x) for x in v))
    else:
        print(str(v).replace("\n", " "))
PY
}

# reserve_path DIR STEM EXT
# Echoes a path in DIR that nothing else holds: "stem.ext", then "stem (2).ext"
# and so on — and *creates* it, empty, before echoing. The auto-add folders are
# transient, but ~/Downloads is full of the user's own files and overwriting one
# would be unforgivable. Testing for the name and then copying leaves a window in
# which another run, or anything else on the Mac, can create that file and have
# it clobbered; `set -o noclobber` makes the claim atomic, so a loser of that
# race simply takes the next number.
reserve_path() {
    local dir="$1" stem="$2" ext="$3"
    # A folder we cannot write to is not a name clash: say so straight away
    # rather than trying a thousand names that will all fail the same way.
    if [[ ! -w "$dir" ]]; then
        printf '%s' ""
        return 1
    fi
    local candidate="$dir/$stem.$ext"
    local n=2
    while ! (set -o noclobber; : > "$candidate") 2>/dev/null; do
        candidate="$dir/$stem ($n).$ext"
        n=$((n + 1))
        if [[ $n -gt 1000 ]]; then
            printf '%s' ""
            return 1
        fi
    done
    printf '%s' "$candidate"
}

# sanitize_filename STRING
# Echoes STRING with filesystem-unfriendly chars stripped.
# h264_encoder_opts <source> — the options for re-encoding a source to H.264.
#
# Apple's VideoToolbox encoder, not libx264 (#80). libx264 is GPL, so it isn't
# in the LGPL ffmpeg the app downloads; and VideoToolbox runs on the Mac's
# media engine: on a 4K source it was 3.5x faster and wrote a seventh of the
# data at the same resolution. Quality is set by bitrate, scaled to the
# picture height: -q:v, VideoToolbox's constant-quality mode, exists only on
# Apple Silicon, and bitrate works the same on every Mac. -allow_sw lets it
# fall back to Apple's software encoder where there's no hardware one, as in a
# virtual machine. An ffmpeg without VideoToolbox keeps the old libx264 path.
h264_encoder_opts() {
    local src=$1 dims w h long rate
    if [[ "${HAS_VIDEOTOOLBOX:-0}" != "1" ]]; then
        printf '%s\n' -c:v libx264 -crf 18 -preset fast -pix_fmt yuv420p
        return
    fi
    # The bitrate tier follows the longer side, so a portrait video isn't
    # mistaken for a smaller one.
    dims=$("$FFPROBE" -v error -select_streams v:0 -show_entries stream=width,height \
        -of csv=p=0 "$src" 2>/dev/null)
    w=${dims%%,*}; h=${dims##*,}
    [[ "$w" =~ ^[0-9]+$ && "$h" =~ ^[0-9]+$ ]] || { w=1920; h=1080; }
    long=$(( w > h ? w : h ))
    if   (( long <= 854 ));  then rate=3
    elif (( long <= 1280 )); then rate=6
    elif (( long <= 1920 )); then rate=12
    elif (( long <= 2560 )); then rate=20
    else                          rate=40
    fi
    # Scale the longer side down to at most 3840 and round both sides to even
    # numbers — a no-op for ordinary sources. Apple's devices don't play H.264
    # above 4K (an Apple TV 4K or an iPhone can't play an 8K H.264 file), and
    # older and Intel encoders top out around there too; 4:2:0 H.264 needs
    # even sides, which this makes explicit rather than leaving to the encoder.
    # Written as an expression on iw/ih because ffmpeg rotates frames before
    # this filter: absolute sizes from the stored dimensions would squash a
    # portrait video.
    printf '%s\n' -vf \
        "scale='trunc(min(1\,3840/max(iw\,ih))*iw/2)*2':'trunc(min(1\,3840/max(iw\,ih))*ih/2)*2'" \
        -c:v h264_videotoolbox -allow_sw 1 -profile:v high \
        -b:v "${rate}M" -maxrate "$(( rate * 3 / 2 ))M" -bufsize "$(( rate * 2 ))M" \
        -pix_fmt yuv420p
}

# clock <seconds> — 2:47 or 1:02:47.
clock() {
    local s=$1
    if (( s >= 3600 )); then
        printf '%d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
    else
        printf '%d:%02d' $(( s / 60 )) $(( s % 60 ))
    fi
}

# ffmpeg_with_progress <source> <ffmpeg arguments…>
# Runs one packaging step and says how far it has got, so a long conversion
# visibly moves instead of looking hung. ffmpeg's stderr was sent to /dev/null,
# so a four-minute 4K re-encode printed nothing at all (#133). -progress writes
# machine-readable progress to stdout instead; it becomes a line every 5%, or
# every 30 seconds of media when the length is unknown. Returns ffmpeg's status.
ffmpeg_with_progress() {
    local src=$1; shift
    local total
    total=$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$src" 2>/dev/null)
    total=${total%%.*}
    [[ "$total" =~ ^[0-9]+$ ]] || total=0

    "$FFMPEG" -nostats -progress pipe:1 "$@" 2>/dev/null | {
        local shown_pct=0 shown_secs=-1 key value secs pct step
        while IFS='=' read -r key value; do
            [[ "$key" == "out_time_us" && "$value" =~ ^[0-9]+$ ]] || continue
            secs=$(( value / 1000000 ))
            # A percentage while the length is known and not yet reached. Past
            # it — the probed length can be shorter than what ffmpeg writes —
            # fall back to elapsed time, rather than stopping at 100% and
            # looking hung again for the rest of the run.
            if (( total > 0 && secs <= total )); then
                pct=$(( secs * 100 / total ))
                # Report on crossing each 5% boundary. "At least 5 more than
                # last time" drifted — 4%, 9%, 14% … 99% — and never said 100%.
                step=$(( pct / 5 * 5 ))
                if (( step <= shown_pct )); then continue; fi
                shown_pct=$step
                printf '   converting: %s of %s (%d%%)\n' "$(clock "$secs")" "$(clock "$total")" "$pct"
            else
                if (( secs < shown_secs + 30 )); then continue; fi
                shown_secs=$secs
                printf '   converting: %s\n' "$(clock "$secs")"
            fi
        done
    }
    return "${PIPESTATUS[0]}"
}

sanitize_filename() {
    printf '%s' "$1" | /usr/bin/perl -CSDA -pe '
        s{[/:\x00]}{ }g;
        s/\s+/ /g;
        s/^\s+|\s+$//g;
    '
}

# ---------- main (only runs when executed, not when sourced) ----------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then

# A copy the app downloaded wins over a Homebrew one: it is the copy the app can
# keep current. Homebrew stays behind it for anyone who already had the tools.
export PATH="$HOME/Library/Application Support/CatchMatch/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
# Test seams (CM_TOOL_PATH, CM_MUSIC_IMPORT, CM_TV_IMPORT): Tests/test_pipeline.sh
# points them at stub tools and temporary folders, so a test run never downloads
# anything or touches the real library.
#
# They are honoured only when this script runs from a checkout. The shipped copy
# lives inside CatchMatch.app/Contents/Resources, and there the environment is
# not ours to trust: the app inherits whatever launched it, so an inherited
# CM_TOOL_PATH would pick the tools to run and CM_MUSIC_IMPORT would pick where
# files are copied. The app scrubs these on its side too; this is the backstop.
CM_SEAMS=1
case "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" in
    */Contents/Resources|*/Contents/Resources/*) CM_SEAMS=0 ;;
esac
if [[ $CM_SEAMS -eq 0 && ( -n "${CM_TOOL_PATH:-}" || -n "${CM_MUSIC_IMPORT:-}" || -n "${CM_TV_IMPORT:-}" ) ]]; then
    echo "Ignoring CM_TOOL_PATH / CM_MUSIC_IMPORT / CM_TV_IMPORT: test seams are off in an installed app."
fi
if [[ $CM_SEAMS -eq 1 && -n "${CM_TOOL_PATH:-}" ]]; then
    export PATH="$CM_TOOL_PATH:$PATH"
fi

DEST_MUSIC_AUDIO=0
DEST_MUSIC_VIDEO=0
DEST_TV=0
DEST_DOWNLOADS=0
# Set by --downloads-audio / --downloads-video: an explicit choice of what goes
# to Downloads, independent of the libraries (#164).
WANT_DL_AUDIO=0
WANT_DL_VIDEO=0
CLEAN_META=1
# Minutes above which an item is treated as long-form and kept out of the Music
# library. A song or music video is minutes long; a film or an episode is not,
# and its audio track imported as a "song" is what iTunes Match then uploads.
LONG_FORM_MINUTES=20
# Set by the app when it has already worked out the metadata for a single item
# (see AITitleCleaner). Applies to the whole run, so the app only passes them
# when the run is that one item.
ITEM_TITLE=""
ITEM_ARTIST=""
URLS=()

# A while loop, not "for arg in $@": a flag that takes a value has to consume the
# next argument, and shift inside a for loop moves $1 while the loop keeps walking
# the original list — the value would be parsed again, as an input URL.
while (( $# )); do
    case "$1" in
        --music)              DEST_MUSIC_AUDIO=1; DEST_MUSIC_VIDEO=1 ;;
        --music-audio)        DEST_MUSIC_AUDIO=1 ;;
        --music-video)        DEST_MUSIC_VIDEO=1 ;;
        --tv)                 DEST_TV=1 ;;
        --downloads)          DEST_DOWNLOADS=1 ;;
        --downloads-audio)    DEST_DOWNLOADS=1; WANT_DL_AUDIO=1 ;;
        --downloads-video)    DEST_DOWNLOADS=1; WANT_DL_VIDEO=1 ;;
        --no-clean-metadata)  CLEAN_META=0 ;;
        --allow-long-music)   LONG_FORM_MINUTES=0 ;;
        --item-title)
            [[ $# -ge 2 ]] || { echo "--item-title needs a value"; exit 2; }
            ITEM_TITLE="$2"; shift ;;
        --item-artist)
            [[ $# -ge 2 ]] || { echo "--item-artist needs a value"; exit 2; }
            ITEM_ARTIST="$2"; shift ;;
        --*)                  echo "Unknown flag: $1"; exit 2 ;;
        *)                    URLS+=("$1") ;;
    esac
    shift
done

if [[ $DEST_MUSIC_AUDIO -eq 0 && $DEST_MUSIC_VIDEO -eq 0 && $DEST_TV -eq 0 && $DEST_DOWNLOADS -eq 0 ]]; then
    DEST_MUSIC_AUDIO=1
    DEST_MUSIC_VIDEO=1
fi

# True when anything is headed for the Music library at all.
DEST_MUSIC=0
if [[ $DEST_MUSIC_AUDIO -eq 1 || $DEST_MUSIC_VIDEO -eq 1 ]]; then DEST_MUSIC=1; fi

if [[ ${#URLS[@]} -eq 0 ]]; then
    echo "Usage: $0 [--music|--music-audio|--music-video] [--tv] [--downloads|--downloads-audio|--downloads-video]"
    echo "          [--no-clean-metadata]"
    echo "          [--allow-long-music] [--item-title TITLE] [--item-artist ARTIST] <url> [<url> ...]"
    exit 2
fi

# yt-dlp is only needed to download web URLs. A run of purely local files must
# not be blocked on it, so only require it when at least one input is not a
# local file.
NEED_YTDLP=0
for arg in "${URLS[@]}"; do
    [[ -f "$arg" ]] || { NEED_YTDLP=1; break; }
done

YTDLP=$(command -v yt-dlp || true)
if [[ -z "$YTDLP" ]]; then
    YTDLP=$(find /opt/homebrew/bin /usr/local/bin /usr/bin -name yt-dlp -type f 2>/dev/null | head -n 1)
fi
if [[ $NEED_YTDLP -eq 1 && -z "$YTDLP" ]]; then
    echo "Error: yt-dlp not found. Click Install in CatchMatch to fetch it."
    exit 1
fi

FFMPEG=$(command -v ffmpeg || true)
if [[ -z "$FFMPEG" ]]; then
    echo "Error: ffmpeg not found. Click Install in CatchMatch to fetch it."
    exit 1
fi

# ffprobe ships alongside ffmpeg; used to reject local files that have no video
# stream (this script imports video, so an audio-only file would otherwise be
# packaged into a bogus video .mp4 and reported as success).
FFPROBE=$(command -v ffprobe || true)
if [[ -z "$FFPROBE" ]]; then
    FFPROBE="$(dirname "$FFMPEG")/ffprobe"
fi

# Whether this ffmpeg has Apple's H.264 encoder. Asked once per run: the helper
# that uses it runs in a subshell, where a cached answer wouldn't survive.
HAS_VIDEOTOOLBOX=0
if [[ -n "${FFMPEG:-}" ]] && "$FFMPEG" -hide_banner -encoders 2>/dev/null | grep -qw h264_videotoolbox; then
    HAS_VIDEOTOOLBOX=1
fi

echo "Using yt-dlp: ${YTDLP:-<not needed: local files only>}"
echo "Using ffmpeg: $FFMPEG"
if [[ $CLEAN_META -eq 0 ]]; then
    echo "Metadata cleanup: OFF"
fi

MUSIC_IMPORT="$HOME/Music/Music/Media.localized/Automatically Add to Music.localized"
[[ $CM_SEAMS -eq 1 && -n "${CM_MUSIC_IMPORT:-}" ]] && MUSIC_IMPORT="$CM_MUSIC_IMPORT"
if [[ $CM_SEAMS -eq 1 && -n "${CM_TV_IMPORT:-}" ]]; then
    TV_IMPORT="$CM_TV_IMPORT"
else
    TV_IMPORT_CANDIDATES=(
        "$HOME/Movies/TV/Media.localized/Automatically Add to TV.localized"
        "$HOME/Movies/TV/TV Media.localized/Automatically Add to TV.localized"
    )
    TV_IMPORT=""
    for p in "${TV_IMPORT_CANDIDATES[@]}"; do
        if [[ -d "$p" ]]; then TV_IMPORT="$p"; break; fi
    done
fi

DOWNLOADS_DIR="$HOME/Downloads"
[[ $CM_SEAMS -eq 1 && -n "${CM_DOWNLOADS:-}" ]] && DOWNLOADS_DIR="$CM_DOWNLOADS"

# --downloads-audio / --downloads-video say exactly what goes to Downloads. Plain
# --downloads mirrors what the item already produced for the libraries: the song
# when that is all that was asked for, the video otherwise, both when both were.
# Same processed files — cleaned title and artist, artwork, subtitles — just
# copied somewhere the user can reach.
DL_AUDIO=0
DL_VIDEO=0
if [[ $WANT_DL_AUDIO -eq 1 || $WANT_DL_VIDEO -eq 1 ]]; then
    DL_AUDIO=$WANT_DL_AUDIO
    DL_VIDEO=$WANT_DL_VIDEO
elif [[ $DEST_DOWNLOADS -eq 1 ]]; then
    [[ $DEST_MUSIC_AUDIO -eq 1 ]] && DL_AUDIO=1
    [[ $DEST_MUSIC_VIDEO -eq 1 || $DEST_TV -eq 1 ]] && DL_VIDEO=1
    [[ $DL_AUDIO -eq 0 && $DL_VIDEO -eq 0 ]] && DL_VIDEO=1
fi

if [[ $DEST_DOWNLOADS -eq 1 && ! -d "$DOWNLOADS_DIR" ]]; then
    echo "Warning: Downloads folder not found at:"
    echo "  $DOWNLOADS_DIR"
    DEST_DOWNLOADS=0
    DL_AUDIO=0
    DL_VIDEO=0
fi

if [[ $DEST_MUSIC -eq 1 && ! -d "$MUSIC_IMPORT" ]]; then
    echo "Warning: Apple Music auto-add folder not found at:"
    echo "  $MUSIC_IMPORT"
    # Both halves have to go, not just the summary flag: the copy steps below
    # test the individual ones.
    DEST_MUSIC=0
    DEST_MUSIC_AUDIO=0
    DEST_MUSIC_VIDEO=0
fi
if [[ $DEST_TV -eq 1 && -z "$TV_IMPORT" ]]; then
    echo "Warning: Apple TV auto-add folder not found. Tried:"
    for p in "${TV_IMPORT_CANDIDATES[@]}"; do echo "  $p"; done
    DEST_TV=0
fi
if [[ $DEST_MUSIC -eq 0 && $DEST_TV -eq 0 && $DEST_DOWNLOADS -eq 0 ]]; then
    echo "Error: no valid destination available."
    exit 1
fi

TEMP_DIR=$(mktemp -d)
# Which formats to download (#132). The packaging step stream-copies H.264 and
# HEVC and re-encodes everything else, so ask for those first:
#   1. H.264 or HEVC at the highest resolution offered, with AAC audio if any —
#      matched case-insensitively, as avc1/avc3/h264 and hvc1/hev1/hevc/h265,
#      since extractors spell the same codec differently;
#   2. failing that — nothing Apple plays natively — something no taller than
#      1080p, since it will be re-encoded and a 4K re-encode is the slow part;
#   3. failing that, anything at all.
# Left to "best", yt-dlp took 4K AV1 and Opus from YouTube and both were
# re-encoded: a 430 MB download became a 1.29 GB file after ~90 CPU-minutes.
# A codec *sort* (-S vcodec:h264) is not a substitute: it ranks codec above
# resolution and puts VP8 ahead of HEVC, so it takes a 360p H.264 over a 4K HEVC
# and a VP8 over an HEVC that would have been copied untouched.
VIDEO_FORMAT='bv*[vcodec~="(?i)^(avc[13]|h26[45]|hvc1|hev1|hevc)"]+ba[acodec~="(?i)^(mp4a|aac)"]/bv*[vcodec~="(?i)^(avc[13]|h26[45]|hvc1|hev1|hevc)"]+ba/bv*[height<=1080]+ba[acodec~="(?i)^(mp4a|aac)"]/bv*[height<=1080]+ba/bv*+ba/b'

trap 'rm -rf "$TEMP_DIR"' EXIT

OVERALL_STATUS=0

for URL in "${URLS[@]}"; do
    echo
    echo "=== Processing: $URL ==="
    BATCH_DIR="$TEMP_DIR/$(uuidgen)"
    VIDEO_DIR="$BATCH_DIR/video"
    AUDIO_DIR="$BATCH_DIR/audio"
    OUT_DIR="$BATCH_DIR/out"
    mkdir -p "$VIDEO_DIR" "$AUDIO_DIR" "$OUT_DIR"

    if [[ -f "$URL" ]]; then
        # Local file — skip yt-dlp entirely and feed the file straight into the
        # same ffmpeg/import steps below. No download, no .info.json sidecar, no
        # separate audio pass (the per-file loop extracts audio from the video
        # when Music is a destination).
        echo "Local file detected; skipping download."
        # This script imports video; reject a file with no video stream rather
        # than package it into a bogus video-less .mp4 and report success. If
        # ffprobe isn't available, skip the preflight (don't block the import on
        # a misleading "no video stream") — ffmpeg below is what actually matters.
        if [[ -x "$FFPROBE" ]]; then
            if ! "$FFPROBE" -v error -select_streams v:0 -show_entries stream=codec_type \
                    -of csv=p=0 "$URL" 2>/dev/null | grep -q video; then
                echo "No video stream in: $URL (local audio-only files aren't supported; skipping)."
                OVERALL_STATUS=1
                continue
            fi
        else
            echo "ffprobe not found; skipping video-stream preflight for $URL."
        fi
        cp -f "$URL" "$VIDEO_DIR/"
    else
        # YouTube Mix/Radio playlists (list=RD...) are auto-generated and effectively
        # infinite — never expand them. Same for system "Liked" / "My Mix" lists.
        PLAYLIST_FLAG="--yes-playlist"
        if [[ "$URL" =~ [?\&]list=(RD|UL|LM|LL|OL) ]]; then
            PLAYLIST_FLAG="--no-playlist"
            echo "Detected auto-generated Mix/Radio playlist; downloading single video only."
        fi

        # Video pass — merged mp4 + .info.json sidecar. Runs whenever either destination
        # is enabled (Music wants the music-video.mp4, TV wants the .mp4).
        if ! "$YTDLP" -f "$VIDEO_FORMAT" --merge-output-format mp4 \
            --no-playlist-reverse "$PLAYLIST_FLAG" --write-info-json \
            --write-thumbnail --convert-thumbnails jpg \
            -o "$VIDEO_DIR/%(playlist_index|0)s-%(title).200B [%(id)s].%(ext)s" "$URL"; then
            echo "yt-dlp video pass reported errors for $URL (continuing with any files that did download)."
            OVERALL_STATUS=1
        fi

        # Audio pass — separate yt-dlp invocation with --extract-audio so it picks the
        # highest-quality audio format directly, independent of mp4 container constraints.
        # Produces .m4a directly (stream copy when source is AAC, single Opus→AAC encode otherwise).
        if [[ $DEST_MUSIC_AUDIO -eq 1 || $DL_AUDIO -eq 1 ]]; then
            if ! "$YTDLP" --extract-audio --audio-format m4a --audio-quality 0 \
                --no-playlist-reverse "$PLAYLIST_FLAG" \
                -o "$AUDIO_DIR/%(playlist_index|0)s-%(title).200B [%(id)s].%(ext)s" "$URL"; then
                echo "yt-dlp audio pass reported errors for $URL (will fall back to extracting from video)."
                OVERALL_STATUS=1
            fi
        fi
    fi

    # nocaseglob so camera filenames (IMG_1234.MOV, clip.MP4) are matched too —
    # Swift accepted them by existence, so the glob must not drop them by case.
    shopt -s nullglob nocaseglob
    # .webm is a video container here, but --convert-thumbnail can leave a
    # .webp; the glob below is extension-exact so artwork can't be picked up as
    # an item.
    VIDEO_FILES=("$VIDEO_DIR"/*.mp4 "$VIDEO_DIR"/*.mkv "$VIDEO_DIR"/*.webm \
                 "$VIDEO_DIR"/*.mov "$VIDEO_DIR"/*.m4v "$VIDEO_DIR"/*.avi)
    shopt -u nullglob nocaseglob

    if [[ ${#VIDEO_FILES[@]} -eq 0 ]]; then
        echo "No media for: $URL"
        OVERALL_STATUS=1
        continue
    fi

    for SRC in "${VIDEO_FILES[@]}"; do
        BASE="${SRC##*/}"
        STEM="${BASE%.*}"
        INFO_JSON="$VIDEO_DIR/$STEM.info.json"
        AUDIO_SRC="$AUDIO_DIR/$STEM.m4a"

        RAW_TITLE=""
        UPLOADER=""
        CLEAN_TITLE=""
        CLEAN_ARTIST=""
        OUT_STEM="$STEM"

        META_ALBUM=""; META_YEAR=""; META_GENRE=""; META_URL=""
        JSON_ARTIST=""; JSON_TRACK=""
        if [[ $CLEAN_META -eq 1 && -f "$INFO_JSON" ]]; then
            # One parse for every field this item needs.
            {
                read -r RAW_TITLE
                read -r UPLOADER
                read -r JSON_CHANNEL
                read -r JSON_ARTIST
                read -r JSON_TRACK
                read -r JSON_ALBUM
                read -r JSON_YEAR
                read -r JSON_UPLOAD_DATE
                read -r JSON_GENRE
                read -r JSON_URL
            } < <(read_json_fields "$INFO_JSON" title uploader channel artist track album release_year upload_date categories webpage_url)

            [[ -z "$UPLOADER" ]] && UPLOADER="$JSON_CHANNEL"

            META_ALBUM="$JSON_ALBUM"
            META_GENRE="$JSON_GENRE"
            META_URL="$JSON_URL"
            META_YEAR="$JSON_YEAR"
            if [[ -z "$META_YEAR" && ${#JSON_UPLOAD_DATE} -ge 4 ]]; then
                META_YEAR="${JSON_UPLOAD_DATE:0:4}"
            fi

            # Prefer what the extractor states outright. YouTube Music and other
            # music-aware extractors fill artist/track in properly, and no amount
            # of title-scraping beats being told.
            if [[ -n "$JSON_ARTIST" && -n "$JSON_TRACK" ]]; then
                CLEAN_ARTIST="$JSON_ARTIST"
                CLEAN_TITLE="$JSON_TRACK"
            else
                clean_metadata "$RAW_TITLE" "$UPLOADER"
            fi
            if [[ -n "$CLEAN_ARTIST" && -n "$CLEAN_TITLE" ]]; then
                OUT_STEM=$(sanitize_filename "$CLEAN_ARTIST - $CLEAN_TITLE")
            elif [[ -n "$CLEAN_TITLE" ]]; then
                OUT_STEM=$(sanitize_filename "$CLEAN_TITLE")
            fi
            [[ -z "$OUT_STEM" ]] && OUT_STEM="$STEM"
            echo "-- Title: ${RAW_TITLE:-<unknown>}"
            if [[ -n "$JSON_ARTIST" && -n "$JSON_TRACK" ]]; then
                echo "   Tagged: $CLEAN_ARTIST — $CLEAN_TITLE (stated by the extractor)"
            elif [[ -n "$CLEAN_ARTIST" ]]; then
                echo "   Clean: $CLEAN_ARTIST — $CLEAN_TITLE"
            else
                echo "   Clean: $CLEAN_TITLE"
            fi
        fi

        # An override the app supplies beats both the extractor's fields and the
        # regex pass: it is the answer a person accepted.
        # Only when this input produced exactly one file. A single URL can be a
        # playlist, and one accepted name applied to all of it would give every
        # item the same OUT_STEM - each copy overwriting the last in the
        # auto-add folder.
        if [[ -n "$ITEM_TITLE" && ${#VIDEO_FILES[@]} -eq 1 ]]; then
            CLEAN_TITLE="$ITEM_TITLE"
            [[ -n "$ITEM_ARTIST" ]] && CLEAN_ARTIST="$ITEM_ARTIST"
            if [[ -n "$CLEAN_ARTIST" ]]; then
                OUT_STEM=$(sanitize_filename "$CLEAN_ARTIST - $CLEAN_TITLE")
            else
                OUT_STEM=$(sanitize_filename "$CLEAN_TITLE")
            fi
            [[ -z "$OUT_STEM" ]] && OUT_STEM="$STEM"
            echo "   Using the title you accepted: ${CLEAN_ARTIST:+$CLEAN_ARTIST — }$CLEAN_TITLE"
        fi

        MP4="$OUT_DIR/$STEM.mp4"
        M4A="$OUT_DIR/$STEM.m4a"

        META_ARGS=()
        if [[ $CLEAN_META -eq 1 || -n "$ITEM_TITLE" ]]; then
            if [[ -n "$CLEAN_TITLE" ]]; then
                META_ARGS+=(-metadata "title=$CLEAN_TITLE")
            fi
            if [[ -n "$CLEAN_ARTIST" ]]; then
                META_ARGS+=(-metadata "artist=$CLEAN_ARTIST" -metadata "album_artist=$CLEAN_ARTIST")
            fi
            # Only set album when there is a real one. It used to be filled with
            # the artist's name, which collapses everything by one artist into a
            # single album that isn't an album.
            [[ -n "$META_ALBUM" ]] && META_ARGS+=(-metadata "album=$META_ALBUM")
            [[ -n "$META_YEAR" ]] && META_ARGS+=(-metadata "date=$META_YEAR")
            [[ -n "$META_GENRE" ]] && META_ARGS+=(-metadata "genre=$META_GENRE")
            # Where it came from, so an import can be traced back later.
            [[ -n "$META_URL" ]] && META_ARGS+=(-metadata "comment=$META_URL")
        fi

        # Video output: stream-copy the video when it's already a codec Apple
        # Music/TV plays natively — a fast, lossless remux instead of a slow,
        # lossy re-encode (a feature-length HEVC file would otherwise take many
        # minutes). Only genuinely incompatible codecs (VP9/AV1/…) are transcoded
        # to H.264. HEVC needs the hvc1 tag or Apple players reject the mp4.
        # Audio is stream-copied to preserve fidelity; we only re-encode audio if
        # the source codec can't live in mp4 (e.g. Opus/FLAC).
        SRC_VCODEC=""; SRC_VPIXFMT=""
        if [[ -x "$FFPROBE" ]]; then
            SRC_VCODEC=$("$FFPROBE" -v error -select_streams v:0 \
                -show_entries stream=codec_name -of csv=p=0 "$SRC" 2>/dev/null)
            SRC_VPIXFMT=$("$FFPROBE" -v error -select_streams v:0 \
                -show_entries stream=pix_fmt -of csv=p=0 "$SRC" 2>/dev/null)
        fi
        # Apple plays H.264/HEVC only in 4:2:0 — 8-bit for H.264, 8- or 10-bit for
        # HEVC. codec_name alone isn't enough (10-bit/4:2:2/4:4:4 H.264 still reports
        # "h264"), so gate the stream-copy on pix_fmt too; anything else transcodes
        # to 8-bit 4:2:0 H.264 for guaranteed compatibility.
        case "$SRC_VCODEC:$SRC_VPIXFMT" in
            h264:yuv420p)                    VIDEO_OPTS=(-c:v copy) ;;
            hevc:yuv420p|hevc:yuv420p10le)   VIDEO_OPTS=(-c:v copy -tag:v hvc1) ;;
            # A read loop, not mapfile: the app runs this with /bin/bash, which
            # on macOS is bash 3.2, and mapfile only arrived in bash 4.
            *)  VIDEO_OPTS=()
                while IFS= read -r opt; do VIDEO_OPTS+=("$opt"); done < <(h264_encoder_opts "$SRC") ;;
        esac

        # Audio: decide by codec, not by hoping a stream-copy fails. ffmpeg will
        # happily mux FLAC/AC3/etc. into mp4, but Apple Music/TV won't play them,
        # so only copy audio that's already Apple-compatible (AAC/ALAC); otherwise
        # transcode to AAC.
        SRC_ACODEC=""
        if [[ -x "$FFPROBE" ]]; then
            SRC_ACODEC=$("$FFPROBE" -v error -select_streams a:0 \
                -show_entries stream=codec_name -of csv=p=0 "$SRC" 2>/dev/null)
        fi
        case "$SRC_ACODEC" in
            aac|alac) AUDIO_OPTS=(-c:a copy) ;;
            *)        AUDIO_OPTS=(-c:a aac -q:a 1) ;;
        esac

        # Subtitles: carry text-based subtitle tracks into the mp4 as mov_text so
        # Apple TV can display them. Image-based subs (PGS/VobSub/DVB) can't be
        # represented as mov_text, so map only text subtitle streams by index and
        # skip image ones (which would otherwise make the whole mux fail).
        SUB_MAP=(); SUB_OPTS=()
        if [[ -x "$FFPROBE" ]]; then
            while IFS=, read -r S_IDX S_CODEC; do
                [[ -z "$S_IDX" ]] && continue
                case "$S_CODEC" in
                    subrip|srt|ass|ssa|mov_text|webvtt|text) SUB_MAP+=(-map "0:$S_IDX") ;;
                esac
            done < <("$FFPROBE" -v error -select_streams s \
                -show_entries stream=index,codec_name -of csv=p=0 "$SRC" 2>/dev/null)
            if [[ ${#SUB_MAP[@]} -gt 0 ]]; then SUB_OPTS=(-c:s mov_text); fi
        fi

        if [[ "${VIDEO_OPTS[1]:-}" == "copy" ]]; then VMODE="stream copy"; else VMODE="→ H.264 transcode"; fi
        SUB_COUNT=$(( ${#SUB_MAP[@]} / 2 ))
        echo "-- Packaging video (video: ${SRC_VCODEC:-unknown} $VMODE; audio: ${SRC_ACODEC:-none} → ${AUDIO_OPTS[*]}; subtitles: $SUB_COUNT): $BASE"
        # Map the first video and first audio track explicitly so the muxed track
        # is the same a:0 we probed for AUDIO_OPTS — ffmpeg's default selection
        # otherwise picks the most-channels track, which on a dual-audio source can
        # be a different codec than the one we decided to copy/transcode.
        PKG_OK=1
        if ! ffmpeg_with_progress "$SRC" -y -i "$SRC" -map 0:v:0 -map '0:a:0?' ${SUB_MAP[@]+"${SUB_MAP[@]}"} \
                "${VIDEO_OPTS[@]}" "${AUDIO_OPTS[@]}" ${SUB_OPTS[@]+"${SUB_OPTS[@]}"} \
                -movflags +faststart \
                ${META_ARGS[@]+"${META_ARGS[@]}"} "$MP4.tmp.mp4"; then
            PKG_OK=0
            # Only worth a second attempt if the first one carried subtitles: a
            # text-sub conversion may have failed, and importing subtitle-free
            # beats failing the item. With no subtitles the retry would just
            # repeat the identical (possibly expensive) command, so skip it.
            if [[ ${#SUB_MAP[@]} -gt 0 ]]; then
                echo "   subtitle mux failed; packaging without subtitles"
                if ffmpeg_with_progress "$SRC" -y -i "$SRC" -map 0:v:0 -map '0:a:0?' \
                        "${VIDEO_OPTS[@]}" "${AUDIO_OPTS[@]}" \
                        -movflags +faststart \
                        ${META_ARGS[@]+"${META_ARGS[@]}"} "$MP4.tmp.mp4"; then
                    PKG_OK=1
                fi
            fi
        fi
        if [[ $PKG_OK -eq 0 ]]; then
            echo "ffmpeg failed on $SRC"
            OVERALL_STATUS=1
            continue
        fi
        mv -f "$MP4.tmp.mp4" "$MP4"

        # Audio output: prefer the dedicated audio-pass file (stream copy of yt-dlp's
        # best-audio extraction, zero re-encode in our pipeline). Fall back to extracting
        # from the video file if the audio pass produced nothing for this item.
        # Artwork: yt-dlp writes the thumbnail next to the video with the same
        # stem. Without this every import shows up in Music as a grey square,
        # which reads as broken even when every other tag is right.
        ART=""
        for ext in jpg jpeg png webp; do
            if [[ -f "$VIDEO_DIR/$STEM.$ext" ]]; then ART="$VIDEO_DIR/$STEM.$ext"; break; fi
        done
        ART_ARGS=()
        if [[ -n "$ART" ]]; then
            # A second video stream tagged as attached_pic is how mp4/m4a carry a
            # cover; without the disposition players treat it as a video track.
            # The cover is the only video stream in the .m4a, so it is output
            # stream v:0 — indexing it as v:1 silently missed, leaving the art
            # re-encoded as a normal video track instead of a cover.
            ART_ARGS=(-i "$ART" -map 1:v -c:v mjpeg -disposition:v:0 attached_pic)
        fi

        if [[ $DEST_MUSIC_AUDIO -eq 1 || $DL_AUDIO -eq 1 ]]; then
            if [[ -f "$AUDIO_SRC" ]]; then
                # Build to a temp path and only move it into place on success, so
                # a failed mux can't leave a partial file that the copy step —
                # which only tests -f — would then import.
                if "$FFMPEG" -y -i "$AUDIO_SRC" ${ART_ARGS[@]+"${ART_ARGS[@]}"} \
                        -map 0:a -c:a copy \
                        ${META_ARGS[@]+"${META_ARGS[@]}"} "$M4A.tmp.m4a" 2>/dev/null; then
                    mv -f "$M4A.tmp.m4a" "$M4A"
                else
                    rm -f "$M4A.tmp.m4a"
                    echo "   artwork mux failed; tagging without a cover"
                    if "$FFMPEG" -y -i "$AUDIO_SRC" -c copy \
                            ${META_ARGS[@]+"${META_ARGS[@]}"} "$M4A.tmp.m4a" 2>/dev/null; then
                        mv -f "$M4A.tmp.m4a" "$M4A"
                    else
                        rm -f "$M4A.tmp.m4a"
                        echo "ffmpeg audio tagging failed on $AUDIO_SRC"
                        OVERALL_STATUS=1
                    fi
                fi
            else
                echo "   audio-pass file missing; extracting from video"
                # Same codec-aware choice as the video pass (AUDIO_OPTS was set
                # from $SRC's a:0 codec above), and map that same a:0 explicitly.
                if "$FFMPEG" -y -i "$SRC" ${ART_ARGS[@]+"${ART_ARGS[@]}"} \
                        -map 0:a:0 "${AUDIO_OPTS[@]}" \
                        ${META_ARGS[@]+"${META_ARGS[@]}"} "$M4A.tmp.m4a" 2>/dev/null; then
                    mv -f "$M4A.tmp.m4a" "$M4A"
                else
                    rm -f "$M4A.tmp.m4a"
                    if "$FFMPEG" -y -i "$SRC" -map 0:a:0 "${AUDIO_OPTS[@]}" \
                            ${META_ARGS[@]+"${META_ARGS[@]}"} "$M4A.tmp.m4a" 2>/dev/null; then
                        mv -f "$M4A.tmp.m4a" "$M4A"
                    else
                        rm -f "$M4A.tmp.m4a"
                        echo "ffmpeg audio extraction failed on $SRC"
                        OVERALL_STATUS=1
                    fi
                fi
            fi
        fi

        # A film's audio track is not a song. Imported into Music it becomes a
        # ~50-minute "track" that iTunes Match can't match and therefore uploads,
        # against the 100,000-song limit, syncing a torrent-shaped filename to
        # every device. Length is the one signal available before the fact, so
        # anything long-form is kept out of Music unless asked for explicitly.
        ITEM_MUSIC_AUDIO=$DEST_MUSIC_AUDIO
        ITEM_MUSIC_VIDEO=$DEST_MUSIC_VIDEO
        if [[ $DEST_MUSIC -eq 1 && $LONG_FORM_MINUTES -gt 0 && -x "$FFPROBE" ]]; then
            DURATION=$("$FFPROBE" -v error -show_entries format=duration \
                -of default=noprint_wrappers=1:nokey=1 "$SRC" 2>/dev/null)
            # ffprobe reports fractional seconds. Compare them as such: truncating
            # first puts 1200.1s — which is over twenty minutes — at exactly the
            # threshold, on the wrong side of it.
            if [[ "$DURATION" =~ ^[0-9]+(\.[0-9]+)?$ ]] \
               && awk -v d="$DURATION" -v m="$LONG_FORM_MINUTES" 'BEGIN { exit !(d > m * 60) }'; then
                ITEM_MUSIC_AUDIO=0
                ITEM_MUSIC_VIDEO=0
                echo "   $(awk -v d="$DURATION" 'BEGIN { printf "%d", d / 60 }') min — too long for the Music library; skipping Music for this item."
                if [[ $DEST_TV -eq 0 ]]; then
                    echo "   (turn on Apple TV to import it there, or pass --allow-long-music)"
                fi
            fi
        fi

        if [[ $ITEM_MUSIC_AUDIO -eq 1 && -f "$M4A" ]]; then
            if cp -f "$M4A" "$MUSIC_IMPORT/$OUT_STEM.m4a"; then
                echo "→ Music (audio): $OUT_STEM.m4a"
            else
                echo "Couldn't write to the Apple Music auto-add folder"
                OVERALL_STATUS=1
            fi
        fi
        if [[ $ITEM_MUSIC_VIDEO -eq 1 && -f "$MP4" ]]; then
            if cp -f "$MP4" "$MUSIC_IMPORT/$OUT_STEM.mp4"; then
                echo "→ Music (video): $OUT_STEM.mp4"
            else
                echo "Couldn't write to the Apple Music auto-add folder"
                OVERALL_STATUS=1
            fi
        fi
        if [[ $DEST_TV -eq 1 ]]; then
            if cp -f "$MP4" "$TV_IMPORT/$OUT_STEM.mp4"; then
                echo "→ TV: $OUT_STEM.mp4"
            else
                echo "Couldn't write to the Apple TV auto-add folder"
                OVERALL_STATUS=1
            fi
        fi

        # Downloads takes the same processed files as the libraries do, and the
        # long-form guard does not apply: a two-hour film is a perfectly good
        # download, it just isn't a song.
        copy_to_downloads() { # copy_to_downloads SOURCE EXT
            local source="$1" ext="$2" target
            target=$(reserve_path "$DOWNLOADS_DIR" "$OUT_STEM" "$ext")
            if [[ -z "$target" ]]; then
                if [[ ! -w "$DOWNLOADS_DIR" ]]; then
                    echo "Couldn't write to $DOWNLOADS_DIR (permissions?)"
                else
                    echo "Couldn't find a free name in $DOWNLOADS_DIR for $OUT_STEM.$ext"
                fi
                OVERALL_STATUS=1
                return 1
            fi
            if cp -f "$source" "$target"; then
                echo "→ Downloads: $(basename "$target")"
            else
                # The reservation is an empty file; don't leave it behind.
                rm -f "$target"
                echo "Couldn't write to $DOWNLOADS_DIR (permissions? disk full?)"
                OVERALL_STATUS=1
                return 1
            fi
        }

        if [[ $DL_AUDIO -eq 1 && -f "$M4A" ]]; then
            copy_to_downloads "$M4A" m4a
        fi
        if [[ $DL_VIDEO -eq 1 && -f "$MP4" ]]; then
            copy_to_downloads "$MP4" mp4
        fi
    done
done

if [[ $OVERALL_STATUS -eq 0 ]]; then
    echo
    echo "All done."
else
    echo
    echo "Done with some errors."
fi
exit $OVERALL_STATUS

fi

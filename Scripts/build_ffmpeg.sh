#!/bin/bash
#
#  build_ffmpeg.sh
#  CatchMatch
#
#  Created by Michel Storms on 22/09/2026.
#
# Builds the ffmpeg and ffprobe the app downloads on first run, so a customer
# never needs Homebrew or Terminal to use it (#80).
#
# LGPL only. Homebrew's ffmpeg is built with --enable-gpl and libx264, which a
# paid app can't hand out on the same terms; this build has neither. It adds
# dav1d (BSD) so AV1 sources can still be decoded, and relies on Apple's own
# VideoToolbox and AudioToolbox encoders instead of libx264.
#
# ffmpeg's configure auto-detects every library it can find — Homebrew's
# included — which would quietly link GPL code or make the binary depend on
# /opt/homebrew/lib, which doesn't exist on a customer's Mac. Auto-detection is
# off; everything used is enabled by name, and the result is checked to link
# nothing outside macOS itself.
#
# Output (in build/ffmpeg/out):
#   catchmatch-ffmpeg-<version>-macos-universal.zip   ffmpeg, ffprobe, NOTICE.txt
#   …zip.sha256                                       for the app to pin
#
# Usage:
#   Scripts/build_ffmpeg.sh              # build, verify, package
#   Scripts/build_ffmpeg.sh --sign       # also sign with Developer ID and notarize
#   CM_SKIP_COMPILE=1 Scripts/build_ffmpeg.sh   # re-verify and repackage the last build
#
# Needs: Xcode command line tools, meson, ninja, nasm (brew install meson ninja nasm).

set -euo pipefail

FFMPEG_VERSION=9.0.2
DAV1D_VERSION=1.5.4
MIN_MACOS=14.0
ARCHS=(arm64 x86_64)
SIGN_IDENTITY="Developer ID Application: MICHEL STORMS (4VYV5C3L3Y)"
# Where the binary zip is published, and its source beside it. LGPL 2.1 §4 lets
# the source be offered "from the same place" as the binary, which is the plan.
PUBLISH_BASE="https://michelstorms.com/catchmatch/tools"
NOTARY_PROFILE="${CM_NOTARY_PROFILE:-notary-profile}"

SIGN=0
[[ "${1:-}" == "--sign" ]] && SIGN=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/ffmpeg"
SRC="$WORK/src"
OUT="$WORK/out"
JOBS=$(sysctl -n hw.ncpu)
mkdir -p "$SRC" "$OUT"

COMPILE=1
[[ "${CM_SKIP_COMPILE:-0}" == "1" ]] && COMPILE=0

REQUIRED_TOOLS=(lipo otool)
[[ $COMPILE -eq 1 ]] && REQUIRED_TOOLS+=(clang meson ninja nasm)
for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null || { echo "❌ $tool is missing (brew install meson ninja nasm)" >&2; exit 1; }
done

# P2 (#143 review): nothing from the caller's environment may steer the build
# towards Homebrew. PKG_CONFIG_LIBDIR alone doesn't suppress PKG_CONFIG_PATH,
# and CPATH, LIBRARY_PATH and friends reach the compiler and linker directly —
# where a static Homebrew library would never show up in otool -L.
unset PKG_CONFIG_PATH CPATH C_INCLUDE_PATH LIBRARY_PATH CFLAGS CPPFLAGS LDFLAGS \
      OBJCFLAGS CXXFLAGS DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH
SDK=$(xcrun --sdk macosx --show-sdk-path)

# step <label> <log> <command…> — runs a build step with its output in a log,
# and shows the end of that log if it fails, rather than a bare exit code.
step() {
    local label=$1 log=$2; shift 2
    if ! "$@" >>"$log" 2>&1; then
        echo "❌ $label failed — last lines of $log:" >&2
        tail -30 "$log" >&2
        exit 1
    fi
}

fetch() { # fetch <url> <file>
    [[ -f "$SRC/$2" ]] || curl -fL --retry 3 -o "$SRC/$2" "$1"
}

if [[ $COMPILE -eq 1 ]]; then
    echo "⬇️  Sources"
    fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz"
    fetch "https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz" "dav1d-$DAV1D_VERSION.tar.xz"
    ARCHS_TO_BUILD=("${ARCHS[@]}")
else
    ARCHS_TO_BUILD=()
fi
for arch in ${ARCHS_TO_BUILD[@]+"${ARCHS_TO_BUILD[@]}"}; do
    PREFIX="$WORK/prefix-$arch"
    rm -rf "$PREFIX" "$WORK/dav1d-$arch" "$WORK/ffmpeg-$arch" "$WORK/dav1d-$arch.log" "$WORK/ffmpeg-$arch.log"
    mkdir -p "$PREFIX" "$WORK/dav1d-$arch" "$WORK/ffmpeg-$arch"

    echo ""
    echo "🔨 dav1d $DAV1D_VERSION ($arch)"
    tar -xf "$SRC/dav1d-$DAV1D_VERSION.tar.xz" -C "$WORK/dav1d-$arch" --strip-components=1
    CROSS="$WORK/cross-$arch.txt"
    cat > "$CROSS" <<EOF
[binaries]
c = ['clang', '-arch', '$arch']
ar = 'ar'
strip = 'strip'
nasm = 'nasm'
[host_machine]
system = 'darwin'
cpu_family = '$([[ $arch == arm64 ]] && echo aarch64 || echo x86_64)'
cpu = '$arch'
endian = 'little'
[built-in options]
c_args = ['-mmacosx-version-min=$MIN_MACOS', '-isysroot', '$SDK']
c_link_args = ['-mmacosx-version-min=$MIN_MACOS', '-isysroot', '$SDK']
EOF
    step "dav1d configure ($arch)" "$WORK/dav1d-$arch.log" \
        meson setup "$WORK/dav1d-$arch/build" "$WORK/dav1d-$arch" --cross-file "$CROSS" \
            --prefix "$PREFIX" --libdir lib --buildtype release --default-library static \
            -Denable_tools=false -Denable_tests=false -Denable_examples=false
    step "dav1d build ($arch)" "$WORK/dav1d-$arch.log" ninja -C "$WORK/dav1d-$arch/build" install

    echo "🔨 ffmpeg $FFMPEG_VERSION ($arch)"
    tar -xf "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" -C "$WORK/ffmpeg-$arch" --strip-components=1
    CROSS_FLAGS=()
    [[ "$arch" != "$(uname -m)" ]] && CROSS_FLAGS=(--enable-cross-compile)
    cd "$WORK/ffmpeg-$arch"
    # With auto-detection off, enabling iconv doesn't add it to the link, so
    # -liconv is named explicitly. It is macOS's own /usr/lib/libiconv.
    step "ffmpeg configure ($arch)" "$WORK/ffmpeg-$arch.log" \
        env PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig" ./configure \
            --prefix="$PREFIX" --arch="$arch" --target-os=darwin \
            --cc="clang -arch $arch" ${CROSS_FLAGS[@]+"${CROSS_FLAGS[@]}"} \
            --extra-cflags="-mmacosx-version-min=$MIN_MACOS -isysroot $SDK -I$PREFIX/include" \
            --extra-ldflags="-mmacosx-version-min=$MIN_MACOS -isysroot $SDK -L$PREFIX/lib" \
            --extra-libs="-liconv" \
            --pkg-config-flags=--static \
            --enable-static --disable-shared \
            --disable-autodetect \
            --enable-videotoolbox --enable-audiotoolbox \
            --enable-zlib --enable-iconv \
            --enable-libdav1d \
            --disable-doc --disable-ffplay --disable-debug
    step "ffmpeg build ($arch)" "$WORK/ffmpeg-$arch.log" make -j"$JOBS"
    step "ffmpeg install ($arch)" "$WORK/ffmpeg-$arch.log" make install
    cd "$ROOT"
done

echo ""
echo "🧬 Universal binaries"
STAGE="$WORK/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
for bin in ffmpeg ffprobe; do
    lipo -create "$WORK/prefix-arm64/bin/$bin" "$WORK/prefix-x86_64/bin/$bin" -output "$STAGE/$bin"
done

echo "🔎 Verifying"
fail() { echo "❌ $1" >&2; exit 1; }

# Every check runs per architecture. lipo -verify_arch only proves a slice
# exists, and running the binary exercises just the host's slice (#143 review).
ROSETTA=0
arch -x86_64 /usr/bin/true 2>/dev/null && ROSETTA=1
run_slice() { # run_slice <arch> <command…> — the Intel slice runs under Rosetta
    local a=$1; shift
    if [[ "$a" == "$(uname -m)" ]]; then "$@"; else arch "-$a" "$@"; fi
}
# The name column of -encoders / -decoders, so a match can't come from a description.
codec_names() { awk '$1 ~ /^[VASDFXB.]{6}$/ { print $2 }'; }

for bin in ffmpeg ffprobe; do
    for a in "${ARCHS[@]}"; do
        lipo "$STAGE/$bin" -verify_arch "$a" || fail "$bin is missing $a"
        # Only macOS itself may be linked: anything else is absent on a customer's
        # Mac. Library entries are indented; the other lines are headers.
        foreign=$(otool -arch "$a" -L "$STAGE/$bin" | grep -E '^[[:space:]]' | awk '{print $1}' \
            | grep -vE '^(/usr/lib/|/System/Library/)' || true)
        [[ -z "$foreign" ]] || fail "$bin ($a) links outside macOS: $foreign"
        minos=$(otool -arch "$a" -l "$STAGE/$bin" | awk '/LC_BUILD_VERSION/ {f=1} f && /minos/ {print $2; exit}')
        [[ "$minos" == "$MIN_MACOS" ]] || fail "$bin ($a) targets macOS $minos, not $MIN_MACOS"
    done
done

for a in "${ARCHS[@]}"; do
    if [[ "$a" != "$(uname -m)" && $ROSETTA -eq 0 ]]; then
        echo "   ⚠ $a slice: linkage and target checked, but it can't be run here (no Rosetta)"
        continue
    fi
    CONF=$(run_slice "$a" "$STAGE/ffmpeg" -hide_banner -buildconf)
    grep -q -- "--enable-gpl" <<<"$CONF" && fail "the $a build is GPL"
    grep -q -- "--enable-nonfree" <<<"$CONF" && fail "the $a build is non-free"
    # ffmpeg wraps its licence text, so match within a line. A GPL build says
    # "terms of the GNU General Public License"; this one must say "Lesser".
    LICENSE_TEXT=$(run_slice "$a" "$STAGE/ffmpeg" -hide_banner -L)
    grep -q "GNU Lesser General Public" <<<"$LICENSE_TEXT" || fail "the $a build doesn't report LGPL"
    grep -q "terms of the GNU General Public" <<<"$LICENSE_TEXT" && fail "the $a build reports GPL"
    ENCODERS=$(run_slice "$a" "$STAGE/ffmpeg" -hide_banner -encoders | codec_names)
    DECODERS=$(run_slice "$a" "$STAGE/ffmpeg" -hide_banner -decoders | codec_names)
    for want in h264_videotoolbox aac_at aac; do grep -qx "$want" <<<"$ENCODERS" || fail "$a: encoder $want is missing"; done
    for want in libdav1d h264 hevc vp9 opus; do grep -qx "$want" <<<"$DECODERS" || fail "$a: decoder $want is missing"; done
    grep -qx libx264 <<<"$ENCODERS" && fail "$a: libx264 is present — that is GPL"
    echo "   $a: links only macOS, targets $MIN_MACOS, LGPL, has VideoToolbox, AudioToolbox and dav1d"
done
CONF=$("$STAGE/ffmpeg" -hide_banner -buildconf)

if [[ $SIGN -eq 1 ]]; then
    echo "🔏 Signing"
    for bin in ffmpeg ffprobe; do
        codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$STAGE/$bin"
        codesign --verify --strict "$STAGE/$bin"
    done
fi

NAME="catchmatch-ffmpeg-$FFMPEG_VERSION-macos-universal"

# The licences themselves travel with the binaries, not just links to them.
cp "$WORK/ffmpeg-arm64/COPYING.LGPLv2.1" "$STAGE/LICENSE-ffmpeg-LGPL-2.1.txt"
cp "$WORK/dav1d-arm64/COPYING" "$STAGE/LICENSE-dav1d-BSD-2-Clause.txt"

cat > "$STAGE/NOTICE.txt" <<EOF
This folder contains ffmpeg and ffprobe $FFMPEG_VERSION, built for CatchMatch.

FFmpeg is licensed under the GNU Lesser General Public License, version 2.1 or
later — see LICENSE-ffmpeg-LGPL-2.1.txt. This build enables no GPL or non-free
component.

It includes dav1d $DAV1D_VERSION, (c) VideoLAN and dav1d authors, under the
BSD 2-Clause licence — see LICENSE-dav1d-BSD-2-Clause.txt.

The complete corresponding source is published beside this download:
  $PUBLISH_BASE/$NAME-source.zip
It contains the unmodified ffmpeg and dav1d releases and the script that built
these binaries, which records every configure option. The same releases are
also available from their authors:
  https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz
  https://downloads.videolan.org/pub/videolan/dav1d/$DAV1D_VERSION/dav1d-$DAV1D_VERSION.tar.xz

ffmpeg was configured with:
$(sed "s|$WORK|<build>|g; s|$SDK|<sdk>|g" <<<"$CONF")
EOF

rm -f "$OUT/$NAME.zip"
(cd "$STAGE" && ditto -c -k --norsrc . "$OUT/$NAME.zip")

# Bare executables can't carry a stapled ticket, so Gatekeeper would have to
# look the notarization up online — but it never assesses these at all:
# ToolManager downloads through URLSession, which doesn't quarantine the file,
# and it removes the quarantine attribute regardless. Notarizing is still done
# so the binaries are vouched for if they ever reach a Mac another way.
if [[ $SIGN -eq 1 ]]; then
    echo "🔏 Notarizing"
    xcrun notarytool submit "$OUT/$NAME.zip" --keychain-profile "$NOTARY_PROFILE" --wait
fi

# The corresponding source, to publish at the same place as the binary.
SRC_STAGE="$WORK/source-stage"
rm -rf "$SRC_STAGE"; mkdir -p "$SRC_STAGE"
cp "$SRC/ffmpeg-$FFMPEG_VERSION.tar.xz" "$SRC/dav1d-$DAV1D_VERSION.tar.xz" "$SRC_STAGE/"
cp "$ROOT/Scripts/build_ffmpeg.sh" "$SRC_STAGE/"
cp "$STAGE/NOTICE.txt" "$STAGE"/LICENSE-*.txt "$SRC_STAGE/"
rm -f "$OUT/$NAME-source.zip"
(cd "$SRC_STAGE" && ditto -c -k --norsrc . "$OUT/$NAME-source.zip")

shasum -a 256 "$OUT/$NAME.zip" | awk '{print $1}' > "$OUT/$NAME.zip.sha256"
echo ""
echo "✔ $OUT/$NAME.zip ($(du -h "$OUT/$NAME.zip" | cut -f1))"
echo "✔ $OUT/$NAME-source.zip ($(du -h "$OUT/$NAME-source.zip" | cut -f1)) — publish at $PUBLISH_BASE/"
echo "  sha256 $(cat "$OUT/$NAME.zip.sha256")"

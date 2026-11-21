#!/bin/bash
#
#  run_all.sh
#  CatchMatch
#
#  Created by Michel Storms on 21/09/2026.
#
# Runs every test: the shell suites against stub tools, then the Swift unit
# tests. Nothing here downloads anything or touches the real Music and TV
# libraries — see Tests/README.md. #109
#
# Usage: bash Tests/run_all.sh [--shell-only | --no-ui]
#   CM_DERIVED_DATA=<dir>   build somewhere other than the shared DerivedData

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUS=0

section() { printf '\n=== %s\n' "$1"; }

section "clean_metadata()"
bash "$DIR/test_clean_metadata.sh" || STATUS=1

section "Pipeline (dlp2music.sh)"
bash "$DIR/test_pipeline.sh" || STATUS=1

# In a C locale bash swallows the first byte of a following multi-byte character
# into the variable name, so a variable written straight against an ellipsis
# expands to nothing plus mojibake. That has now shipped twice in
# release_to_cdn.sh messages; brace it as a dollar-brace expansion (#124).
# The test is deliberately narrow: the offending byte must come *directly*
# after the name, or every emoji-prefixed echo with "$VAR!" in it would fail.
section "Shell hygiene"
UNBRACED=$(perl -ne 'print "$ARGV:$.: $_" if /\$[A-Za-z_]\w*[^\x00-\x7f]/' \
           "$DIR/../Scripts/"*.sh "$DIR"/*.sh \
           "$DIR/../dlp2music/dlp2music/Resources/dlp2music.sh" 2>/dev/null || true)
if [ -n "$UNBRACED" ]; then
    echo "✗ a variable is followed directly by a multi-byte character; brace it:"
    echo "$UNBRACED"
    STATUS=1
else
    echo "  ✓ no unbraced variable sits against a multi-byte character"
fi

# Everything the window's log shows must also reach the log file, written where
# it happens. Only these appends may bypass appendLog(), each because the line
# was already written to the file just before it (#134).
LOG_BYPASSES=(
    'logEntries.append(contentsOf: lines)'
    'logEntries.append(contentsOf: shown)'
    'logEntries.append(contentsOf: entries)'
    'logEntries.wrappedValue.append("[iMessage] reply sent")'
    'logEntries.wrappedValue.append("[iMessage] reply failed: \(err)")'
)
UNLOGGED=""
while IFS= read -r hit; do
    line="${hit#*:}"; line="${line#*:}"
    for ok in "${LOG_BYPASSES[@]}"; do line="${line//"$ok"/}"; done
    if printf '%s\n' "$line" | grep -qE 'logEntries(\.wrappedValue)?\.append\('; then UNLOGGED+="$hit"$'\n'; fi
done < <(grep -rnE 'logEntries(\.wrappedValue)?\.append\(' "$DIR/../dlp2music/dlp2music" --include='*.swift' 2>/dev/null)
if [ -n "$UNLOGGED" ]; then
    echo "✗ a line reaches the window's log without being written to the log file — use appendLog():"
    printf '%s' "$UNLOGGED"
    STATUS=1
else
    echo "  ✓ every line shown in the window's log is also written to the log file"
fi

# The module is dlp2music; the product is CatchMatch. A string literal naming
# dlp2music fails the suite unless it is one of these internal uses, matched *in
# its context* — a bare "dlp2music" is allowed only as the bundled script's
# resource name, so Text("dlp2music") is still caught (#135). Each is removed
# from the line before looking for a leftover; a new internal use has to be
# added here on purpose. Known limits of a grep guard: multi-line string
# literals and escaped quotes inside a literal are not parsed.
INTERNAL_USES=(
    'subsystem: "com.dlp2music.app"'
    'label: "dlp2music.applog"'
    'label: "dlp2music.imessage.poll"'
    'label: "dlp2music.line-collector"'
    'forResource: "dlp2music"'
    '"/dlp2music.sh"'
    '"/usr/local/bin/dlp2music.sh"'
    'appendingPathComponent("Logs/dlp2music"'
    'appendingPathComponent("dlp2music.log"'
    'appendingPathComponent("dlp2music.log.1"'
)
LEAKED=""
while IFS= read -r hit; do
    line="${hit#*:}"; line="${line#*:}"          # drop "file:" then "line:"
    for use in "${INTERNAL_USES[@]}"; do line="${line//"$use"/}"; done
    if printf '%s\n' "$line" | grep -qE '"[^"]*dlp2music'; then LEAKED+="$hit"$'\n'; fi
done < <(grep -rnE '"[^"]*dlp2music' "$DIR/../dlp2music/dlp2music" --include='*.swift' 2>/dev/null)
if [ -n "$LEAKED" ]; then
    echo "✗ the internal name dlp2music appears in a string that is not a known internal use:"
    printf '%s' "$LEAKED"
    STATUS=1
else
    echo "  ✓ every string naming dlp2music is a known internal use"
fi

if [[ "${1:-}" == "--shell-only" ]]; then
    printf '\nSkipping the Swift tests (--shell-only).\n'
    exit $STATUS
fi

DD_ARGS=()
[[ -n "${CM_DERIVED_DATA:-}" ]] && DD_ARGS=(-derivedDataPath "$CM_DERIVED_DATA")
LOG_DIR=$(mktemp -d)

# Keep the whole log and print what failed. Piping xcodebuild through `tail`
# threw the reason away, which left a failing run undiagnosable.
run_xcodebuild() { # run_xcodebuild <label> <-only-testing target>
    local label="$1" target="$2" log="$LOG_DIR/${2//\//_}.log"
    if xcodebuild test \
            -project "$DIR/../dlp2music/CatchMatch.xcodeproj" \
            -scheme CatchMatch \
            -destination 'platform=macOS' \
            -only-testing "$target" \
            ${DD_ARGS[@]+"${DD_ARGS[@]}"} > "$log" 2>&1; then
        echo "$label passed ($(grep -c "' passed" "$log") tests)"
    else
        echo "$label FAILED"
        grep -E "Test case '.*' failed|error: -\[|XCTAssert.*failed|Expectation failed" "$log" | head -10
        echo "  full log: $log"
        STATUS=1
    fi
}

section "Swift unit tests"
run_xcodebuild "Swift unit tests" CatchMatchTests

if [[ "${1:-}" == "--no-ui" ]]; then
    printf '\nSkipping the UI tests (--no-ui).\n'
    exit $STATUS
fi

section "UI tests"
run_xcodebuild "UI tests" CatchMatchUITests/QueueUITests

printf '\n'
[[ $STATUS -eq 0 ]] && echo "All suites passed." || echo "Some suites failed."
exit $STATUS

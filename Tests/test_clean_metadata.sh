#!/bin/bash
# Test fixture for clean_metadata() in dlp2music.sh.
# Usage: bash test_clean_metadata.sh
# Each case is: raw_title|uploader|expected_artist|expected_title

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../dlp2music/dlp2music/Resources/dlp2music.sh
source "$SCRIPT_DIR/../dlp2music/dlp2music/Resources/dlp2music.sh"

CASES=(
    'Daft Punk - Get Lucky (Official Music Video) ft. Pharrell Williams|Daft Punk|Daft Punk|Get Lucky feat. Pharrell Williams'
    'Adele - Hello (Official Video)|AdeleVEVO|Adele|Hello'
    'Queen – Bohemian Rhapsody (Official Video)|Queen Official|Queen|Bohemian Rhapsody'
    'Radiohead - Creep [Official Video] (HD)|Radiohead|Radiohead|Creep'
    'The Weeknd - Blinding Lights (Lyric Video)|The Weeknd|The Weeknd|Blinding Lights'
    'Billie Eilish - bad guy (Audio)|BillieEilishVEVO|Billie Eilish|bad guy'
    'Coldplay - Yellow [Lyrics]|Coldplay|Coldplay|Yellow'
    'Taylor Swift - Anti-Hero (Official Music Video) 4K|TaylorSwiftVEVO|Taylor Swift|Anti-Hero'
    'Imagine Dragons - Believer (Visualizer)|ImagineDragonsVEVO|Imagine Dragons|Believer'
    'Drake - One Dance ft. Wizkid & Kyla (HD)|Drake|Drake|One Dance feat. Wizkid & Kyla'
    'Eminem — Lose Yourself (Official Audio)|EminemMusic|Eminem|Lose Yourself'
    'Ariana Grande - thank u, next (Official Video) 🔥|ArianaGrandeVEVO|Ariana Grande|thank u, next'
    'Bruno Mars - Uptown Funk (featuring Mark Ronson) (HD)|BrunoMars|Bruno Mars|Uptown Funk (feat. Mark Ronson)'
    'Hotel California - Eagles|EaglesVEVO|Eagles|Hotel California'
    'Beethoven Symphony No. 9|||Beethoven Symphony No. 9'
    'Some Song Title|Some Artist - Topic|Some Artist|Some Song Title'
    'Just A Title (Official Video)|Random Channel||Just A Title'
    'A - B - C (Official Video)|Channel|A|B - C'
    'Linkin Park - In The End (Official HD Music Video)|LinkinParkVEVO|Linkin Park|In The End'
    'Kendrick Lamar - HUMBLE. (HD) (4K) (Remastered)|KendrickLamarVEVO|Kendrick Lamar|HUMBLE.'
)

FAIL=0
PASS=0
i=0
for c in "${CASES[@]}"; do
    i=$((i+1))
    IFS='|' read -r raw uploader exp_artist exp_title <<<"$c"

    CLEAN_TITLE=""
    CLEAN_ARTIST=""
    clean_metadata "$raw" "$uploader"

    # Trim expected fields (handles trailing spaces from |  | in fixtures)
    exp_artist="$(printf '%s' "$exp_artist" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    exp_title="$(printf '%s' "$exp_title" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

    if [[ "$CLEAN_ARTIST" == "$exp_artist" && "$CLEAN_TITLE" == "$exp_title" ]]; then
        PASS=$((PASS+1))
        # printf 'PASS %2d: %s\n' "$i" "$raw"
    else
        FAIL=$((FAIL+1))
        printf 'FAIL %2d: %s\n' "$i" "$raw"
        printf '         uploader: %s\n' "$uploader"
        printf '         expected: artist=[%s] title=[%s]\n' "$exp_artist" "$exp_title"
        printf '         got:      artist=[%s] title=[%s]\n' "$CLEAN_ARTIST" "$CLEAN_TITLE"
    fi
done

echo
echo "Results: $PASS passed, $FAIL failed (of $i)"
[[ $FAIL -eq 0 ]]

# Tests

`bash Tests/run_all.sh` runs everything. `--shell-only` skips the Xcode build;
`--no-ui` stops after the unit tests (the UI tests take about a minute).

| Suite | What it covers |
|---|---|
| `test_clean_metadata.sh` | `clean_metadata()` in `dlp2music.sh`: artist/title from messy video names (20 cases). Sources the script; it guards against running when sourced. |
| `test_pipeline.sh` | `dlp2music.sh` end to end: every destination combination, the long-form guard and `--allow-long-music`, accepted-name overrides, metadata cleaning on and off, and the failure paths. |
| `CatchMatchTests` (Swift) | `URLExtractor`; the `catchmatch://` entry point (what it refuses as much as what it accepts); the queue's destination flags and long-form threshold; `LineCollector` under concurrent appends. |
| `QueueUITests` (UI) | Drives the window: adding a link, the button's count, refusing a duplicate and refusing nonsense, choosing destinations, and Clear. Nothing presses Convert & Import, so no import runs. |

## How the pipeline tests stay safe

`dlp2music.sh` reads three variables that are unset in normal use:

- `CM_TOOL_PATH` — prepended to `PATH`, so `Tests/stubs/{yt-dlp,ffmpeg,ffprobe}` are found first
- `CM_MUSIC_IMPORT`, `CM_TV_IMPORT` — the import folders

The stubs write the files a real run would leave behind and take env knobs
(`STUB_DURATION`, `STUB_ITEMS`, `STUB_TITLE`, `STUB_NO_MEDIA`, `STUB_FAIL`,
`STUB_FFMPEG_FAIL`). So a test run **never downloads anything** and never writes
near the real Music or TV libraries.

## Not covered yet

Tracked in #109: `ToolManager`'s checksum verification (the download path needs
a seam of its own), the iMessage watcher end to end, and Sparkle's update check.

# Privacy policy

_Last updated: 2026-11-21. Applies to the CatchMatch macOS application._

## Short version

- **No tracking, and nothing about what you import.** The app sends anonymous usage counts to Google Analytics (launches, imports finished or failed) so we can see where people get stuck. You can turn this off in Settings → General → Privacy.
- The only outbound network calls the app makes are: (1) a one-shot reachability check (HEAD request to a public Apple URL) when the onboarding/setup sheet runs, used solely to tell you whether you're online; (2) checking for app updates; (3) downloading yt-dlp from its GitHub releases when you choose Download yt-dlp; (4) using yt-dlp / ffmpeg, which contact the source URL you ask the app to process; (5) the usage counts above, unless you turn them off.
- Logs stay on your Mac unless you choose to copy them via Help → Copy Diagnostics.
- Nothing is sold. Apart from the usage counts above, nothing is shared with third parties beyond what you explicitly trigger.

## Data we send

| What | Where | When | Why |
|---|---|---|---|
| Reachability HEAD | `apple.com` | When you open the onboarding/setup sheet | Confirms the Mac is online so the setup checklist can show ✓/✗ for "Network reachable." No data is sent beyond the bare HTTP request. |
| Update check | `michelstorms.com` | About once a day, and when you choose CatchMatch → Check for Updates… | Fetches the list of available versions (Sparkle). The request identifies only the app and its version (in the User-Agent); no system profile is sent. |
| yt-dlp download | GitHub (`api.github.com`, `github.com`) | Only when you choose Download yt-dlp | Looks up the latest yt-dlp release and downloads its macOS build and checksum file. GitHub sees an ordinary download request; nothing about you or your library is sent. |
| Usage counts | Google Analytics (`www.google-analytics.com`) | At launch and when an import finishes or fails — unless you turn it off in Settings → General → Privacy | Shows where people get stuck. Each count carries the event's name, where the import came from (queue or iMessage), the app version, and a random identifier made for this install (not derived from your Mac or your account). Turning the setting off deletes that identifier. Google processes this as our processor, under its [Data Processing Terms](https://business.safety.google/adsprocessorterms/); ad personalization is off. |
| URLs you submit | The site at the URL itself, via yt-dlp | When you press Convert & Import | This is the actual feature you asked for. We do not relay your URLs to any service we control. (URLs appear locally in the app's log — see the next section.) |

The app does **not** send: your name, email, IP address (beyond the unavoidable network-layer information), import history, links, titles, file names, or anything related to the content you process — to Google or anyone else.

## Data we store on your Mac

- A persistent log file at `~/Library/Logs/dlp2music/dlp2music.log`, capped at 5 MB with one rotated copy. It records what each import did, so a failure can be diagnosed. That means it contains:
  - **the links you submit**, and the local paths of files you drop in;
  - **the titles, artists and file names** of what you import;
  - **where each file was saved** — the Apple Music, Apple TV or Downloads folder path, which includes your macOS user name;
  - the locations and versions of the media components the app uses, and any errors they report;
  - iMessage watcher activity, if you use it — how many links arrived, whether they were imported or why not, and whether a reply was sent. The links themselves appear only for the ones it went on to process.

  You can reveal it via Help → Reveal Log in Finder, copy a 200-line tail via Help → Copy Diagnostics, or delete it at any time.
- Your settings (defaults and the usage-count identifier) in macOS UserDefaults.

None of this is uploaded, apart from the usage-count identifier, which goes with each count as described above. If you copy diagnostics via Help → Copy Diagnostics, recent log lines end up on your clipboard — including links, titles, file names and folder paths as described above. Read it before you send it to anyone, and remove anything you'd rather not share.

## Crash reports

The app does not include automatic crash reporting. If we ever add it, it will be **opt-in** and clearly disclosed in this document and in-app.

## Your rights

You can:
- Delete the app and any of the local files listed above at any time.
- Turn off usage counts from Settings → General → Privacy, which also deletes the install's identifier.
- Request information about data we hold by emailing catchmatchapp@michelstorms.dev — though we don't hold any account data on you to begin with.

## Children

The app is not directed at children under 13.

## Changes

If this policy changes in a meaningful way, we'll publish the new version on the landing page and bump the date at the top.

## Contact

catchmatchapp@michelstorms.dev

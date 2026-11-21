# CatchMatch

<a href="https://buymeacoffee.com/stormychel"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-support-FFDD00?logo=buymeacoffee&logoColor=black" alt="Buy me a coffee" /></a>

**A macOS app that adds your recordings, purchases and openly licensed video to your Apple Music and Apple TV libraries — or just to your Downloads folder.**

> *Repo / dev name: `dlp2music` — the public product name is **CatchMatch**.*

## Download

Get the signed, notarized DMG from the [latest release](https://github.com/stormychel/CatchMatch/releases/latest). Installed copies update themselves.

## Overview

`CatchMatch` started as a simple shell script (`dlp2music.sh`, still bundled inside the app), but it's now a full macOS app with a graphical interface. Paste one or more URLs and the app downloads, converts, and imports both audio and video into Apple Music and (optionally) Apple TV.

It's for material you have the right to use: your own recordings, music you bought on **Bandcamp**, and public-domain or Creative Commons sources such as **Archive.org**.

You can also assign one iMessage chat as a "drop zone": text a URL from your iPhone (e.g. via iOS 17+ Send-to-Self) and CatchMatch picks it up on the Mac, imports it, and sends back a `[CatchMatch] - ✅ Imported: <title>` reply.

## Prerequisites

### 1. Media tools

CatchMatch needs yt-dlp and ffmpeg/ffprobe. On first launch, click **Install**: the app downloads them into `~/Library/Application Support/CatchMatch/bin` and verifies them. No Homebrew, no Terminal, no admin password.

- **yt-dlp** comes from its official GitHub releases, checked against the checksum published with each release.
- **ffmpeg/ffprobe** is our own LGPL build (`Scripts/build_ffmpeg.sh`), published at `https://michelstorms.com/catchmatch/tools/` with its source bundle and checked against a SHA-256 compiled into the app. A new build means a new app release: rebuild with `Scripts/build_ffmpeg.sh --sign`, publish the zips, and update `ffmpegArchiveURL`/`ffmpegArchiveSHA256` in `ToolManager.swift`.

Copies already installed with Homebrew still work; the app's own copies come first on the pipeline's PATH.

### 2. Music Import Folder

Apple Music auto-imports audio files placed in:

```sh
~/Music/Music/Media.localized/Automatically\ Add\ to\ Music.localized/
```

Make sure this folder exists. The app will use it to move downloaded audio automatically.

## Usage

Launch the app, paste a video URL, and press the button. That's it.

Typical use cases include:

- Grabbing a live performance from Archive.org
- Extracting audio from freely available concert footage
- Adding Creative Commons music videos to your Apple Music library

Behind the scenes, the app:

- Downloads the best quality audio and video
- Extracts the audio as an AAC file
- Moves both video and audio files into Apple Music's auto-import folder

## Just the file

Turn on **⬇ Video** or **⬇ Audio** (or both) and the processed video or song lands
in `~/Downloads` instead of a library: same cleaned title and artist, same artwork. No Apple
Music subscription, no iTunes Match, no auto-add folders. It works on its own or
alongside the other destinations, and an existing file of the same name is never
overwritten.

## Getting tracks onto your other devices

CatchMatch only adds files to the Music library on your Mac. To have them on your iPhone, iPad or HomePod as well, turn on **Sync Library** in Music settings (it needs an Apple Music or iTunes Match subscription); Music then uploads the imported files to your iCloud Music Library.

## Legal Disclaimer

This app is for **personal use only**. Downloading copyrighted material without permission may violate terms of service and local laws. Use responsibly. The developer assumes no liability.

## License

CatchMatch is free and open source under the [MIT License](LICENSE). yt-dlp and FFmpeg, which the app downloads on first launch, come under their own licenses.

If it saves you time, you can [buy me a coffee](https://buymeacoffee.com/stormychel).

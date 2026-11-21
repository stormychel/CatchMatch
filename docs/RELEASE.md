# Release pipeline

Resolves issue #23. This is the operator's guide for cutting a signed, notarized, Sparkle-equipped DMG.

The release flow is **local-only** (no GitHub Actions), modelled on the BlueSender-FE pipeline at `Scripts/release_to_cdn.sh`. It differs at the last step: BlueSender-FE uploads to an S3 bucket that belongs to that client, not to us. CatchMatch publishes to **GitHub Pages** instead, by committing the artifacts into the `stormychel.github.io` repo that serves michelstorms.com (#121). No bucket, no CDN account, no second domain.

## Sparkle in the app (done in #100)

- Sparkle 2 is an SPM dependency of the `CatchMatch` target.
- `dlp2music/CatchMatch-Info.plist` is merged into the generated Info.plist and carries `SUFeedURL` (`https://michelstorms.com/catchmatch/sparkle/appcast-v2.xml`), `SUPublicEDKey` and `SUEnableAutomaticChecks`. If the CDN host changes, update `SUFeedURL` there **and** in any build already shipped — an installed app only ever checks the URL it was built with.
- `dlp2musicApp.swift` owns an `SPUStandardUpdaterController`; **CatchMatch → Check for Updates…** lives in `Updates/CheckForUpdatesView.swift`.
- The app isn't sandboxed, so no network entitlement is needed.

### Signing key

CatchMatch has its own EdDSA key, stored in the login Keychain under the account `catchmatch` (not the BlueSender key). `release_to_cdn.sh` signs with `sign_update --account catchmatch` (override with `CM_SPARKLE_ACCOUNT`).

**Back up the private key.** Losing it means shipped copies can never accept another update:

```
~/Library/Developer/Xcode/DerivedData/CatchMatch-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account catchmatch -x catchmatch-sparkle-private-key.txt
```

Store that file somewhere safe (password manager), then delete it. To print the public key: `generate_keys --account catchmatch -p`.

## One-time local setup

```sh
# Store notarytool creds in your login keychain. The script defaults to the
# profile name "notary-profile" — override with the CM_NOTARY_PROFILE env var.
xcrun notarytool store-credentials notary-profile \
    --apple-id YOUR@EMAIL \
    --team-id  4VYV5C3L3Y \
    --password APP-SPECIFIC-PASSWORD
```

Publishing needs no setup and no environment variables — just a checkout of the site repo at `~/Source/stormychel.github.io`, sitting on `main` with push rights. See [Where it publishes](#where-it-publishes) to override any of that.

## Cutting a release

The release script has two modes:

| Mode | What it does | When to use |
|---|---|---|
| `--version` | Builds, notarizes, packages a DMG + ZIP, EdDSA-signs the ZIP, updates the appcast, uploads everything | User-facing changes that should auto-update existing installs |
| `--build` | Builds, notarizes, packages a DMG (no Sparkle artifacts) | Internal changes you don't want to push as an auto-update |

```sh
# Bump CFBundleShortVersionString / CFBundleVersion in Xcode first, then:

# Dry run — produces local DMG/ZIP/appcast but skips notarize + upload
Scripts/release_to_cdn.sh --test --version

# Full release — fresh build, notarize, package, publish
Scripts/release_to_cdn.sh --version

# DMG-only build, no Sparkle update
Scripts/release_to_cdn.sh --build

# AI-generated release notes (uses claude CLI against commits since last appcast)
Scripts/release_to_cdn.sh --version --ai-notes

# Custom release notes
Scripts/release_to_cdn.sh --version -m "Faster downloads, fewer surprises"

# Generic message
Scripts/release_to_cdn.sh --version -m ""

# Skip the build, package an existing prebuilt .app
Scripts/release_to_cdn.sh --version /path/to/CatchMatch.app
```

The script previews the release notes and prints a `Proceed with publish? [y/N]` gate before anything is committed, so you can sanity-check the title/body before it goes live.

## Where it publishes

Into the site repo, which GitHub Pages serves as michelstorms.com:

```
~/Source/stormychel.github.io/
  catchmatch/sparkle/
    appcast-v2.xml                                     # the live feed (SUFeedURL points here)
    releases/
      CatchMatch_v{version}_{build}.zip                # Sparkle update payload (EdDSA-signed)
      CatchMatch_latest.dmg                            # human-download DMG
    notes/
      catchmatch-{version}.html                        # release notes (linked from appcast)
```

Overridable, though the defaults are the real ones:

| Variable | Default | Notes |
|---|---|---|
| `CM_CDN_BASE` | `https://michelstorms.com/catchmatch/sparkle` | Must match `SUFeedURL` in `CatchMatch-Info.plist`. **This URL can never move** — it's compiled into every copy sold. |
| `CM_SITE_REPO` | `~/Source/stormychel.github.io` | The Pages checkout to commit into. |
| `CM_SITE_BRANCH` | `main` | The publishing branch. |

The publish step stages **only** `catchmatch/sparkle/`, so unrelated work in that checkout is never swept into the release commit. It refuses to run at all if the site repo is on another branch, or if there are already uncommitted changes under that prefix — in both cases it stops before the confirmation prompt and leaves every local artifact in place, so nothing is lost and nothing half-lands.

### Things to know about Pages as a host

- **Deploy lag.** A push is usually live within a minute, but it isn't instant. The script prints the URLs to check.
- **Cache.** Pages sets its own cache headers (~10 minutes); the old `--cache-control max-age=300` on the appcast has no equivalent. An update can take that long to be seen. This is not worth engineering around.
- **Size.** GitHub's hard limit is 100 MB per file, soft 1 GB per repo, and every release adds a ZIP and a DMG to history permanently. Fine for years at an indie cadence — but if it ever becomes a problem, move to a real CDN and leave a redirect at this path. Sparkle follows redirects, so already-sold copies keep updating.
- **The push can be rejected** if the branch is behind. The release is then committed but not live; `git pull --rebase && git push` in the site repo finishes it. The script says so and exits non-zero.

## Files in this pipeline

- `Scripts/release_to_cdn.sh` — the local + Sparkle release pipeline
- `Scripts/ExportOptions.plist` — tells `xcodebuild -exportArchive` to use Developer ID + automatic signing
- `Scripts/generate_dmg_background.swift` — regenerates `dmg_assets/catchmatch-dmg-background.png` if you tweak the DMG branding
- `dmg_assets/catchmatch-dmg-background.png` — DMG window background
- `appcast.xml` — a seed appcast committed to this repo. **The script does not use it.** When the live feed 404s (first release), it generates a fresh appcast from an inline template instead: this committed copy is a bare `<channel>` with no `<item>`, so seeding from it would publish an empty feed. Kept only as a reference for the shape of the file.

## Failure modes

- **`exportArchive` fails with "no provisioning profile"** → make sure the Developer ID Application cert is in your login keychain and the Xcode project has automatic signing enabled.
- **Notarization rejected with "hardened runtime not enabled"** → Build Settings → Hardened Runtime → Yes for Release configuration.
- **Notarization rejected with "invalid signature"** → some helper binary (likely a Python or shell script in Resources) is unsigned. Re-sign it explicitly in a Run Script phase before archiving.
- **Sparkle update doesn't fire** → `SUPublicEDKey` in `Info.plist` doesn't match the private key used for `sign_update`.
- **`sign_update` not found** → the Sparkle SPM dependency hasn't been built yet. Build the app once in Xcode after adding the package and the binary will appear under DerivedData.
- **`hdiutil: create failed - Resource busy`** → Spotlight is still scanning the freshly notarized `.app`. The script already works around this by creating an empty volume and copying the payload in after attach.

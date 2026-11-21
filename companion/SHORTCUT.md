# iOS Shortcut spec

The Apple Shortcut that customers install on their iPhone/iPad to send URLs from the Share Sheet to their Mac.

## Steps (in order)

1. **Receive** — accept input from Share Sheet. Type: URLs.
2. **Get URLs from Input** — extract the actual URL.
3. **Get Contents of URL** — POST to `https://api.dlp2music.app/v1/jobs`:
   - Method: `POST`
   - Headers:
     - `Authorization: Bearer <COMPANION_TOKEN>` ← baked in at install time
     - `Content-Type: application/json`
   - Request body (JSON):
     ```json
     {
       "url": "<URL from step 2>",
       "destinations": ["music"],
       "client": "<Device Name>"
     }
     ```
4. **Get Dictionary Value** for key `id` from the response (sanity check that the request succeeded).
5. **Show Notification** — "Queued: <URL>". The Mac handles the rest; user gets a normal Music sync notification when it arrives.
6. **(Optional)** Version-check pre-step: GET `https://api.dlp2music.app/v1/version`. If the response's `minimumSupportedShortcutVersion` is greater than the bundled Shortcut version, show "Update available" instead of running.

## Distribution

The Mac app (Settings → Companion) generates an iCloud Shortcut deep link with the current `companionToken` baked into step 3's headers. Tapping the link on the phone opens the Shortcut in the iOS Shortcuts app, ready to add. Customers don't see or copy the token; it lives inside the Shortcut's "Get Contents of URL" action.

## Versioning

When the protocol changes incompatibly:
1. Bump `currentShortcutVersion` in the Mac app and in the Worker's `/v1/version` response
2. Customers' existing Shortcuts continue to work until the Worker's `minimumSupportedShortcutVersion` exceeds their bundled version
3. Re-install path: Settings → Companion → "Re-install Shortcut" generates a fresh deep link

# Companion-mode wire protocol

Resolves the design portion of #32. **Deferred to v1.1** — implementation lands after the Gumroad v1 launch.

## Overview

```
iPhone Share Sheet
   └─ Run Shortcut "Send to dlp2music"
        ├─ Get Selected URL
        ├─ POST to https://api.dlp2music.app/v1/jobs
        │     headers: Authorization: Bearer <companion-token>
        │     body:    { "url": "...", "destinations": ["music"], "client": "michel-iphone" }
        └─ Show banner "Queued"

Cloudflare Worker (free tier — wrangler.toml in /companion/worker)
   ├─ Validate companion-token against KV table tokens/<token-hash>
   ├─ Append job to KV list jobs/<token-hash> with TTL 24h
   └─ Long-poll endpoint /v1/jobs/poll for the Mac to consume

Mac (dlp2music in menu bar mode)
   ├─ Authenticated long-poll to /v1/jobs/poll (~25s timeout, reconnect)
   ├─ On job: run existing pipeline → mark done → POST /v1/jobs/<id>/status
   └─ (v1.2) APNs ping back to a future iOS app
```

## Endpoints

### `POST /v1/jobs`
Submit a new import job from any client device.

Request:
```json
{
  "url": "https://archive.org/details/...",
  "destinations": ["music", "tv"],
  "client": "michel-iphone-15",
  "requestId": "3f2a…"
}
```

`requestId` is optional (up to 64 characters). A retry with the same one returns the original job instead of queueing a second import. Limits: a 4 KB body, a 2,048-character http(s) URL with a host, a 64-character `client`, and 100 pending jobs per pairing (then `429`).

Response:
```json
{ "id": "01HFXY9G…", "queuedAt": "2026-…" }
```

Auth: `Authorization: Bearer <token>` (32–128 random URL-safe chars), producer or consumer.

### `GET /v1/jobs/poll`
Mac long-polls with its consumer token. It **leases** the oldest job that isn't leased, or whose lease expired, for 10 minutes, and returns it; otherwise `204` after the timeout. The job isn't deleted until the Mac reports its outcome, so a crash or a dropped response loses nothing: it is offered again when the lease runs out. Two overlapping polls can still lease the same job (see the known limitations below), so the Mac dedupes on `id`. Each lease carries a new `leaseId`, which the status call must echo.

Response (200):
```json
{
  "id": "01HFXY9G…",
  "url": "https://...",
  "destinations": ["music"],
  "client": "michel-iphone-15",
  "createdAt": "2026-…"
}
```

### `POST /v1/jobs/<id>/status`
Mac reports completion or failure with its consumer token. This is the acknowledgement: it stores the outcome and removes the job. `404` if the job is unknown or already acknowledged.

Request:
```json
{ "leaseId": "…", "status": "done", "files": ["song.m4a"], "error": null }
```

`leaseId` must match the job's current lease. A Mac whose lease expired and was handed to another poll gets `409 lease_superseded`, so its late acknowledgement can't remove the newer delivery. A job expires 24 hours after it was submitted, whether or not it has been leased.

`status` is `done` or `failed`. `files` holds at most 20 names of up to 256 characters, and `error` at most 500 characters.

### `GET /v1/version`
Shortcut's optional version-check step. Returns minimum supported Shortcut version.

```json
{ "currentShortcutVersion": "1.0.0", "minimumSupportedShortcutVersion": "1.0.0" }
```

## Token model

Each pairing is one **account** with two kinds of token, stored in KV as `tokens/<sha256(token)>` → `{ "account": "…", "role": "producer" | "consumer" }`:

- **producer**: baked into the Shortcut. It can only submit jobs.
- **consumer**: held by the Mac. It can submit, poll and report status.

Jobs are keyed by account, so a leaked phone token can queue links but can't read, lease or remove the Mac's jobs.

| Token type | Where it lives | Lifetime | Rotatable |
|---|---|---|---|
| `licenseKey` | Customer's Gumroad receipt | Forever (until refunded) | No (ties to purchase) |
| `companionToken` | Mac app Settings → Companion, paired to one license | Until customer rotates from the Mac | **Yes** |

The companion token is derived from the license key (e.g. HKDF) but stored independently in the Worker's KV. Rotation flow:
1. Customer clicks "Rotate companion token" on the Mac
2. Mac generates a new token, hashes it, writes to Worker's `tokens/<hash>` KV
3. Old token's KV row is removed
4. Customer reinstalls the Shortcut with the new token baked in (via the iCloud Shortcut link the Mac generates)

This means a leaked token can be revoked without invalidating the customer's Gumroad license.

## Pairing UX (Mac side)

Settings → Companion tab:
- Show Companion Token (with reveal/copy)
- "Install Shortcut on Phone" — opens the iCloud Shortcut link (the Shortcut bakes in the current token at install time)
- "Rotate Token"
- Recent Activity (last 10 jobs received from companion clients with their `client` label)

## iCloud Drive fallback toggle

When a customer can't or won't use the cloud Worker, they enable an iCloud Drive fallback in Settings. The Shortcut writes a file at `~/iCloud Drive/dlp2music/inbox/<uuid>.json` with the same job schema; the Mac watches that folder via `NSMetadataQuery`. Latency is 5–60s vs the Worker's <1s, but no Worker setup is needed.

The Mac handles whichever path is live — both can run in parallel.

## Privacy considerations

- The Worker stores only: token hash, queued URLs (TTL 24h), last-N status updates per token. Never the customer's Apple ID, email, or anything tying activity back to a person beyond the random token.
- All transport is HTTPS.
- The /v1/version endpoint is the only unauthenticated route.

## Implementation milestones (when this becomes active in v1.1)

1. **Worker MVP** — POST /v1/jobs, GET /v1/jobs/poll, POST /v1/jobs/<id>/status, KV-backed, ~150 lines TS
2. **Mac long-poll consumer** — async loop, reconnect with backoff, integrates with the existing `ImportJobQueue`
3. **Companion settings tab** — token reveal + rotate + recent activity
4. **Mac-side iCloud Shortcut export** — generates a Shortcut deeplink with the current token baked in
5. **iCloud Drive fallback** — `NSMetadataQuery` watcher reading the same JSON schema
6. **Move job claim from KV to Durable Objects / D1** — fixes two known limitations of the current KV scaffold: (a) leasing is get-then-put, not atomic, so concurrent polls can lease the same job (only the later lease can acknowledge it, bar a re-lease that lands mid-acknowledgement), and two simultaneous submits with the same `requestId` can both be queued; (b) KV is eventually consistent across regions so a submit and a poll at different PoPs can fail to see each other for tens of seconds. Practical short-term mitigation in v1.1: the Mac re-polls immediately after a 204; the eventually-consistent window typically resolves within a couple of polls.
7. **Future: APNs response path** — requires a native iOS app, postponed to v1.2

## What's intentionally out of scope for v1.1

- Native iOS app
- Web push to a PWA
- Per-device registration / enforcing a device cap
- Real-time progress relayed back to the phone (banner-on-done is enough for v1.1)
- Shared / multi-user companion folders

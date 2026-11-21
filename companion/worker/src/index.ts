// dlp2music companion-mode Worker — v1.1 scaffold (deferred per #32).
//
// Endpoints (see ../PROTOCOL.md):
//   POST /v1/jobs                  — submit a job              (producer or consumer token)
//   GET  /v1/jobs/poll             — Mac long-polls and leases (consumer token)
//   POST /v1/jobs/:id/status       — Mac reports the outcome   (consumer token)
//   GET  /v1/version               — current/minimum Shortcut version
//
// Run locally: `wrangler dev`
// Deploy:      `wrangler deploy`

interface Env {
    COMPANION_KV: KVNamespace;
}

const SHORTCUT_VERSION = "1.0.0";
const SHORTCUT_MIN_SUPPORTED = "1.0.0";
const POLL_TIMEOUT_MS = 25_000;
const JOB_TTL_SECONDS = 24 * 60 * 60;
// How long a polled job belongs to the Mac that took it. Unacknowledged after
// this, it is offered again, so a crash or a dropped response loses nothing.
const LEASE_MS = 10 * 60 * 1000;
const IDEMPOTENCY_TTL_SECONDS = 24 * 60 * 60;

// Limits, so one token can't fill KV or run up usage.
const MAX_BODY_BYTES = 4 * 1024;
const MAX_URL_LENGTH = 2048;
const MAX_CLIENT_LENGTH = 64;
const MAX_REQUEST_ID_LENGTH = 64;
const MAX_FILES = 20;
const MAX_FILE_NAME_LENGTH = 256;
const MAX_ERROR_LENGTH = 500;
const MAX_PENDING_JOBS = 100;

type Destination = "music" | "tv";
type Role = "producer" | "consumer";

/// What `tokens/<sha256(token)>` holds. A pairing has one account and two kinds
/// of token: the Shortcut's can only submit, the Mac's can also poll and report.
/// A leaked phone token therefore can't read or delete the Mac's jobs.
interface TokenRecord {
    account: string;
    role: Role;
}

interface Job {
    id: string;
    url: string;
    destinations: Destination[];
    client?: string;
    createdAt: string;
    /// Seconds since the epoch at which KV drops the job: 24 hours after it
    /// was submitted, however often it is re-leased.
    expiresAt: number;
    leasedUntil?: number;
    /// Changes with every lease, so only the Mac holding the current lease can
    /// acknowledge the job.
    leaseId?: string;
}

class BadRequest extends Error {}

export default {
    async fetch(request: Request, env: Env): Promise<Response> {
        const url = new URL(request.url);
        try {
            switch (`${request.method} ${url.pathname}`) {
                case "POST /v1/jobs":
                    return await handleSubmit(request, env);
                case "GET /v1/jobs/poll":
                    return await handlePoll(request, env);
                case "GET /v1/version":
                    return json({
                        currentShortcutVersion: SHORTCUT_VERSION,
                        minimumSupportedShortcutVersion: SHORTCUT_MIN_SUPPORTED,
                    });
                default: {
                    const m = request.method === "POST" && url.pathname.match(/^\/v1\/jobs\/([0-9]{15}-[0-9a-f]{8})\/status$/);
                    if (m) return await handleStatus(request, env, m[1]);
                    return json({ error: "not_found" }, 404);
                }
            }
        } catch (err) {
            if (err instanceof BadRequest) return json({ error: "bad_request", detail: err.message }, 400);
            // Details stay in the Worker's logs, not in the response.
            console.error(err);
            return json({ error: "server_error" }, 500);
        }
    },
};

async function handleSubmit(request: Request, env: Env): Promise<Response> {
    const token = await authenticate(request, env);
    if (!token) return json({ error: "unauthorized" }, 401);

    const body = await readJSON<{ url?: unknown; destinations?: unknown; client?: unknown; requestId?: unknown }>(request);
    const url = validURL(body.url);

    const requested = Array.isArray(body.destinations) ? body.destinations : [];
    const destinations = requested.length > 0
        ? [...new Set(requested.filter((d): d is Destination => d === "music" || d === "tv"))]
        : (["music"] as Destination[]);
    if (destinations.length === 0) throw new BadRequest("destinations must contain at least one of music, tv");

    const client = optionalString(body.client, MAX_CLIENT_LENGTH, "client");
    const requestId = optionalString(body.requestId, MAX_REQUEST_ID_LENGTH, "requestId");

    // A retried submit (the Shortcut re-running, a flaky network) carries the
    // same requestId and gets the original job back instead of a second import.
    // Best effort: two retries at the same instant can both miss the receipt,
    // since KV has no atomic check-and-set (see the known limitations below).
    if (requestId) {
        const existing = await env.COMPANION_KV.get(`idem/${token.account}/${requestId}`);
        if (existing) return json(JSON.parse(existing));
    }

    // A soft cap: two submits racing at the limit can both get in, which is
    // fine for its purpose of stopping one token filling KV.
    if ((await jobKeys(env, token.account, MAX_PENDING_JOBS)).length >= MAX_PENDING_JOBS) {
        return json({ error: "too_many_pending_jobs" }, 429);
    }

    // Sortable key: zero-padded millis + random suffix. KV.list returns keys in
    // lexicographic order, so a millis-prefixed key gives FIFO delivery.
    const millis = Date.now().toString().padStart(15, "0");
    const random = crypto.randomUUID().replace(/-/g, "").slice(0, 8);
    const id = `${millis}-${random}`;
    const now = new Date();
    const job: Job = {
        id, url, destinations, client,
        createdAt: now.toISOString(),
        expiresAt: Math.floor(now.getTime() / 1000) + JOB_TTL_SECONDS,
    };
    await env.COMPANION_KV.put(`job/${token.account}/${id}`, JSON.stringify(job), { expiration: job.expiresAt });

    const receipt = { id, queuedAt: job.createdAt };
    if (requestId) {
        await env.COMPANION_KV.put(`idem/${token.account}/${requestId}`, JSON.stringify(receipt), {
            expirationTtl: IDEMPOTENCY_TTL_SECONDS,
        });
    }
    return json(receipt);
}

/// Leases the oldest job that isn't already leased, or whose lease ran out.
/// Nothing is deleted here: a job goes only when the Mac reports it, so one
/// lost between here and the Mac is offered again once its lease expires.
///
/// KNOWN LIMITATIONS of this KV-backed scaffold, fixed by the Durable Objects /
/// D1 migration in ../PROTOCOL.md:
///   1. Leasing is get-then-put, not atomic: two overlapping polls can take the
///      same job. Only the later lease can acknowledge it; the Mac also dedupes
///      on the job id — though a re-lease landing between an acknowledgement's
///      lease check and its delete can still lose to that acknowledgement.
///      Simultaneous submits with one requestId can likewise both be queued.
///   2. KV is eventually consistent across PoPs, so a poll can miss a job that
///      was just queued. The Mac re-polls straight after a 204.
async function handlePoll(request: Request, env: Env): Promise<Response> {
    const token = await authenticate(request, env);
    if (!token) return json({ error: "unauthorized" }, 401);
    if (token.role !== "consumer") return json({ error: "forbidden" }, 403);

    const deadline = Date.now() + POLL_TIMEOUT_MS;
    while (Date.now() < deadline) {
        for (const name of await jobKeys(env, token.account)) {
            const raw = await env.COMPANION_KV.get(name);
            if (!raw) continue;
            const job = JSON.parse(raw) as Job;
            if (job.leasedUntil && job.leasedUntil > Date.now()) continue;
            // A job stored before expiresAt existed keeps the 24 hours it was given.
            job.expiresAt ??= Math.floor(Date.parse(job.createdAt) / 1000) + JOB_TTL_SECONDS;
            // KV refuses an expiration less than 60 s away; a job this close to
            // its end isn't worth handing out, and the margin covers rounding.
            if (job.expiresAt - Date.now() / 1000 < 120) continue;
            job.leasedUntil = Date.now() + LEASE_MS;
            job.leaseId = crypto.randomUUID();
            // The original expiry, not a fresh 24 h: re-leasing mustn't keep an
            // unacknowledged job alive for ever.
            await env.COMPANION_KV.put(name, JSON.stringify(job), { expiration: job.expiresAt });
            return json(job);
        }
        await new Promise((r) => setTimeout(r, 1500));
    }
    return new Response(null, { status: 204 });
}

/// The Mac's acknowledgement: records the outcome and removes the job.
async function handleStatus(request: Request, env: Env, id: string): Promise<Response> {
    const token = await authenticate(request, env);
    if (!token) return json({ error: "unauthorized" }, 401);
    if (token.role !== "consumer") return json({ error: "forbidden" }, 403);

    const body = await readJSON<{ leaseId?: unknown; status?: unknown; files?: unknown; error?: unknown }>(request);
    if (typeof body.leaseId !== "string") throw new BadRequest("leaseId from the poll is required");
    if (body.status !== "done" && body.status !== "failed") throw new BadRequest("status must be done or failed");
    let files: string[] = [];
    if (body.files !== undefined && body.files !== null) {
        if (!Array.isArray(body.files) || body.files.length > MAX_FILES
            || !body.files.every((f) => typeof f === "string" && f.length <= MAX_FILE_NAME_LENGTH)) {
            throw new BadRequest(`files must be at most ${MAX_FILES} names of up to ${MAX_FILE_NAME_LENGTH} characters`);
        }
        files = body.files as string[];
    }
    const error = optionalString(body.error, MAX_ERROR_LENGTH, "error");

    const jobKey = `job/${token.account}/${id}`;
    const raw = await env.COMPANION_KV.get(jobKey);
    if (!raw) return json({ error: "not_found" }, 404);
    // A Mac whose lease ran out and was handed to another poll no longer owns
    // the job; its late acknowledgement mustn't delete the newer delivery.
    if ((JSON.parse(raw) as Job).leaseId !== body.leaseId) return json({ error: "lease_superseded" }, 409);
    // KV can't check-and-delete atomically, so a re-lease can still slip in
    // between the check above and the delete below; the check is repeated here
    // to keep that window as short as it can be. See the known limitations.
    const current = await env.COMPANION_KV.get(jobKey);
    if (!current || (JSON.parse(current) as Job).leaseId !== body.leaseId) return json({ error: "lease_superseded" }, 409);
    await env.COMPANION_KV.delete(jobKey);
    await env.COMPANION_KV.put(
        `status/${token.account}/${id}`,
        JSON.stringify({ status: body.status, files, error, finishedAt: new Date().toISOString() }),
        { expirationTtl: JOB_TTL_SECONDS },
    );
    return json({ ok: true });
}

/// The account's job keys in FIFO order, across every page KV.list returns.
async function jobKeys(env: Env, account: string, max = Infinity): Promise<string[]> {
    const names: string[] = [];
    let cursor: string | undefined;
    do {
        const page = await env.COMPANION_KV.list({ prefix: `job/${account}/`, cursor });
        names.push(...page.keys.map((k) => k.name));
        cursor = page.list_complete ? undefined : page.cursor;
    } while (cursor && names.length < max);
    return names;
}

async function authenticate(request: Request, env: Env): Promise<TokenRecord | null> {
    const auth = request.headers.get("Authorization") ?? "";
    const m = auth.match(/^Bearer\s+([A-Za-z0-9_\-=]{32,128})$/);
    if (!m) return null;
    const record = await env.COMPANION_KV.get(`tokens/${await sha256(m[1])}`);
    if (!record) return null;
    const parsed = JSON.parse(record) as Partial<TokenRecord>;
    if (typeof parsed.account !== "string" || (parsed.role !== "producer" && parsed.role !== "consumer")) return null;
    return { account: parsed.account, role: parsed.role };
}

async function readJSON<T>(request: Request): Promise<T> {
    const declared = Number(request.headers.get("content-length") ?? "0");
    if (declared > MAX_BODY_BYTES) throw new BadRequest("request body too large");
    const text = await request.text();
    if (new TextEncoder().encode(text).length > MAX_BODY_BYTES) throw new BadRequest("request body too large");
    try {
        const value = JSON.parse(text);
        if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error();
        return value as T;
    } catch {
        throw new BadRequest("body must be a JSON object");
    }
}

function validURL(value: unknown): string {
    if (typeof value !== "string" || value.length > MAX_URL_LENGTH) throw new BadRequest("url must be an http(s) URL");
    let parsed: URL;
    try {
        parsed = new URL(value);
    } catch {
        throw new BadRequest("url must be an http(s) URL");
    }
    if ((parsed.protocol !== "http:" && parsed.protocol !== "https:") || !parsed.hostname) {
        throw new BadRequest("url must be an http(s) URL");
    }
    return parsed.toString();
}

function optionalString(value: unknown, max: number, name: string): string | undefined {
    if (value === undefined || value === null) return undefined;
    if (typeof value !== "string" || value.length > max) throw new BadRequest(`${name} must be a string of up to ${max} characters`);
    return value;
}

async function sha256(s: string): Promise<string> {
    const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
    return Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
        status,
        headers: { "content-type": "application/json" },
    });
}

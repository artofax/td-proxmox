# Troubleshooting Log

Running log of issues encountered building / running the TD-Proxmox stack and
the solutions that fixed them. **Reverse chronological** — newest entries at
the top. Each entry is self-contained so you can copy/paste it into a customer
SOW, a Slack channel, or an MR description without context.

## How to add an entry

Use this skeleton. Stamp with `YYYY-MM-DD HH:MM CT` (the local timezone matters
— overnight failures look different from mid-debug ones).

```markdown
## YYYY-MM-DD HH:MM CT — Short title

**Symptom:** what the user saw  
**Root cause:** technical explanation  
**Fix:** what we changed  
**Files / Commit:** where the fix lives in this repo  
**Related:** other entries this pattern matches (optional)
```

If multiple entries share an architectural pattern (e.g., "SSRF gate") cross-link
them via `**Related:**` so a reader skimming for one issue stumbles into the
sibling issues.

---

## Architectural patterns to recognize fast

These show up repeatedly across services. When debugging anything new, check
these first:

### SSRF / outgoing-webhook gates
Many self-hosted services ship anti-SSRF protection that blocks outgoing
connections to RFC1918 / private addresses by default. Symptom: webhook
configured in the UI, delivery log shows success or a benign error, but the
target service never receives the call. Known instances:

- **Mattermost** — `ServiceSettings.AllowedUntrustedInternalConnections`
- **Gitea** — `[webhook] ALLOWED_HOST_LIST` in `app.ini`
- (Likely others — watch for it on any new service.)

Fix pattern: open the allowlist to cover `private,loopback,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10` (named groups + explicit CIDRs + Tailscale CGNAT).

### Channel UUIDs vs slugs
Mattermost's REST API expects 26-char channel IDs, not slugs like `town-square`.
n8n's Mattermost node won't auto-resolve slugs; pasting the UUID directly works
only in **Expression mode** (`={{...}}`) — Fixed mode validation rejects
26-char strings as malformed. Live town-square UUID for THIS install:
`te9ckat1p3b3ukshup6z5jaesr`.

### Shell quoting through `pct exec`
`pct exec <CTID> -- bash -lc "..."` with double-quoted heredoc and embedded
`curl -d '...'` containing JSON `"` characters is a quoting trap. Three rules:
1. Write JSON payloads to a file inside the CT and `curl -d @file`.
2. Pass values via env vars **prefixed** before `python3 -c` (not appended).
3. For nested Python `"..."` inside single-quoted bash, single-quote the dict
   keys: `r['name']` not `r[\"name\"]`.

### Two-PVE / two-CT name collisions
When you have parallel installs on multiple PVE hosts, Tailscale MagicDNS
arbitrates which `n8n` / `gitea` / etc. wins. The "wrong" one being served can
look like every other category of bug. Always verify: `nslookup n8n` from the
client, `getent hosts n8n` from inside relevant CTs.

### Test URL vs Production URL (n8n webhooks)
n8n's Webhook node exposes both:
- `/webhook-test/<path>` — registered only after clicking "Execute workflow",
  unregisters after one event
- `/webhook/<path>` — registered when the workflow is **Active**

Easy to copy the wrong one from the UI. Symptom: external system reports
"delivered" but no n8n execution exists.

---

## Entries

## 2026-06-28 12:15 CT — n8n died overnight (V8 heap OOM)

**Symptom:** Wake up to `n8n.service` in `failed (Result: signal)` state after
~3h uptime. Service was running fine, then died at 02:49:48 with:
```
FATAL ERROR: Ineffective mark-compacts near heap limit
Allocation failed - JavaScript heap out of memory
Main process exited, code=killed, status=6/ABRT
Mem peak: 1.3G
```

**Root cause:** Node.js's default V8 heap limit is ~1.4GB on 64-bit. Under
sustained load (Gitea retrying SSRF-blocked webhooks, Mattermost credential
403 retries, execution log accumulation in memory before flush) n8n hit the
ceiling. CT had 2GB RAM available but V8 never asked the OS for more than its
internal default. SIGABRT killed the process. systemd unit had no `Restart=`
directive so it stayed dead.

**Fix:** Edit the systemd unit at `/etc/systemd/system/n8n.service`:
- Add `Environment=NODE_OPTIONS=--max-old-space-size=2048` (gives V8 2GB heap)
- Add `Restart=on-failure` + `RestartSec=10` (auto-recover from future OOMs)

Then `systemctl daemon-reload && systemctl restart n8n`. For extra cushion, bump
CT RAM to 4GB: `pct set <CTID> -memory 4096`.

**Files / Commit:** `addons/setup-n8n.sh` (commit `055d83a`) — baked into fresh
installs; existing CTs get the patch on next `--credentials-only` run.

**Related:** Future overnight-failure entries should compare against this.

---

## 2026-06-28 02:15 CT — Gitea webhook to n8n silently blocked (SSRF gate)

**Symptom:** Gitea webhook configured with correct URL `http://10.27.0.218:5678/webhook/gitea-events`. Recent Deliveries shows attempts, but the response is:
```
Post "http://10.27.0.218:5678/webhook/gitea-events": dial tcp ...:
webhook can only call allowed HTTP servers (check your
webhook.ALLOWED_HOST_LIST setting), deny '10.27.0.218'
```
No execution appears in n8n.

**Root cause:** Gitea has its own anti-SSRF gate — `webhook.ALLOWED_HOST_LIST`
in `app.ini`. Default empty value blocks every RFC1918 destination. Same
architectural pattern as Mattermost's `AllowedUntrustedInternalConnections`.

**Fix:** Edit `app.ini`'s `[webhook]` section:
```ini
[webhook]
ALLOWED_HOST_LIST = private,loopback,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,100.64.0.0/10
```
Then `systemctl reload gitea` (or restart). Belt-and-suspenders: both Gitea's
named groups (`private`, `loopback`) and explicit CIDR fallbacks.

**Files / Commit:** `automation/configure-apps.sh` (commit `baa5f04`) — fresh
installs get this baked in from `configure_gitea`.

**Related:** Mattermost SSRF gate (2026-06-27 22:30 entry). Both follow the
same architectural pattern; always check this first when a service-to-service
webhook silently fails.

---

## 2026-06-28 01:30 CT — Gitea events workflow saved with wrong resource/operation

**Symptom:** Gitea webhook reaches n8n, workflow runs, `finished: True` with no
error, Post to Mattermost node output is `{}` — but no message appears in Town
Square.

**Root cause:** While poking the Mattermost node's Channel dropdown to test if
the credential could fetch the channel list, accidentally **saved the workflow**
with `resource: user, operation: getById` instead of `resource: message,
operation: post`. The node was fetching a user (with no ID) and returning empty
`{}`. n8n reported success because MM returned 200 OK to the user-fetch call.

**Fix:** Open the Post to Mattermost node in the n8n UI. Set:
- Resource: Message
- Operation: Post  
- Channel: Expression mode → paste `te9ckat1p3b3ukshup6z5jaesr`
- Message: `={{$json.text}}`
- Credential: Mattermost (pi-bot)

Save. Workflow now posts correctly.

**Files / Commit:** Live config only — no script change needed (this was a
user-side mistake, the JSON in the repo is correct).

**Related:** Channel UUIDs (Fixed vs Expression mode) — see architectural
patterns above.

---

## 2026-06-28 01:00 CT — Webhook Test URL vs Production URL confusion

**Symptom:** Gitea webhook configured with what looked like the right n8n URL,
delivery log shows success, but no execution in n8n.

**Root cause:** Copied `/webhook-test/gitea-events` (the test URL, only listens
for one event after clicking "Execute workflow" in the editor) instead of
`/webhook/gitea-events` (the production URL, registered when workflow is
Active). The test URL responds with a benign 200 even when not actively
listening, fooling Gitea's delivery log.

**Fix:** In Gitea webhook config, change target URL from `/webhook-test/...` to
`/webhook/...`. Re-trigger to verify.

**Files / Commit:** Live config only.

**Related:** Always copy the **Production URL** shown at the bottom of the
Webhook node's parameter panel — never the Test URL, even though n8n's UI
often displays the test URL more prominently.

---

## 2026-06-28 00:30 CT — Format digest reported "no activity" despite recent commits

**Symptom:** Workflow ran all green end-to-end, Mattermost post landed, but
text said `:sleeping: No Gitea activity in the last 24 hours.` even though
commits within 24h existed.

**Root cause:** n8n's HTTP Request node **auto-splits array responses** into
individual items. When `Fetch commits per repo` returned `[commit1, commit2,
...]`, n8n unpacked the array and each commit became a separate item.
My old Format digest code assumed `item.json` was an array of commits and
did `(item.json || []).filter(...)`. Since each `item.json` was actually a
single commit object (not an array), `.filter` is undefined on the wrong shape
and crashed; the `!Array.isArray(raw)` guard then skipped every commit.

**Fix:** Rewrite Format digest to iterate commit-by-commit via `$input.all()`
and group by `c.repository.full_name` (Gitea sometimes includes it) or a URL
parse of `c.url` (which is always present). Filter on `c.commit.author.date >=
cutoff`.

**Files / Commit:** `addons/n8n/workflows/gitea-daily-digest.json` (commit `480b6a5`).

**Related:** Any workflow with HTTP Request → Code: assume auto-array-split,
treat each item as a single record, not a collection. Set "Split Into Items"
off explicitly if you want the array as a single item.

---

## 2026-06-27 23:50 CT — Wrong n8n CT — two-PVE name collision

**Symptom:** Two browser tabs to "n8n" — one logs in fine (LAN IP
`http://10.27.0.218:5678`), the other rejects the password
(`http://n8n:5678`). The tab favicons are different colors.

**Root cause:** Tailscale's DNS server (`100.100.100.100`) resolves the
hostname `n8n` to `10.27.0.124` (the **other** PVE host's n8n CT, from an
earlier parallel test build), not `10.27.0.218` (THIS PVE's n8n CT, where the
password was set). They're separate installs with different credentials, hence
the login mismatch.

**Diagnosis from client:**
```bash
nslookup n8n          # returns 100.100.100.100 → 10.27.0.124 ≠ expected
tailscale status | grep n8n
```

**Fix options:**
- **Use the LAN IP directly** (simplest): bookmark `http://10.27.0.218:5678`.
- **Update Tailscale's static DNS record** in admin → DNS → Custom records to
  point `n8n.localdomain` at `10.27.0.218`.
- **Decommission the other n8n CT** on the other PVE host.
- **Rename this CT** in Tailscale (`tailscale up --hostname=td-n8n`) so the
  two coexist without colliding.

**Files / Commit:** Live config only — this is an infrastructure-level
collision, not a script issue.

**Related:** The same pattern bit us with `gitea.localdomain` resolving to
`10.27.0.239` (other PVE) on the n8n CT — fixed by `/etc/hosts` override.

---

## 2026-06-27 23:30 CT — n8n password DB direct-update needed (locked out)

**Symptom:** Could not log in to n8n UI with the password used at signup, even
after multiple attempts. API key still worked. Account exists in `user` table
with `role=global:owner, disabled=0`.

**Root cause:** Unknown — possibly mistyped at original signup, possibly a
script side-effect that hashed something wrong. Symptom matched a corrupt or
unknown password hash, not a disabled account.

**Fix:** Reset the bcrypt hash directly in `database.sqlite`:

```bash
N8N_CTID=$(pct list | awk '/n8n /{print $1}')
DB=/.n8n/database.sqlite

# Install bcrypt via apt (not pip — pip isn't installed in the community CT)
pct exec $N8N_CTID -- apt-get install -y python3-bcrypt

NEW_PASSWORD='TdHomelab1234!'
NEW_HASH=$(pct exec $N8N_CTID -- python3 -c "
import bcrypt
print(bcrypt.hashpw('$NEW_PASSWORD'.encode(), bcrypt.gensalt(10)).decode())
")

pct exec $N8N_CTID -- sqlite3 $DB "
  UPDATE \"user\" 
  SET password = '$NEW_HASH', mfaEnabled = 0, mfaSecret = NULL, mfaRecoveryCodes = NULL
  WHERE email = 'posaprivy@tutanota.com';
"
```

Browser-side: stale session cookie may persist; use an Incognito window OR
clear cookies + localStorage for the n8n origin to log in with the new password.

Verify the hash is exactly 60 chars and starts with `$2a$10$` or `$2b$10$`. If
shorter, the shell mangled it (use file-based update via heredoc instead).

**Files / Commit:** No script change — recovery is one-off. But this is the
escape hatch if it happens again.

**Related:** If everything else fails: `pct exec <ctid> -- n8n user-management:reset`
deletes the owner (workflows + credentials preserved) and re-renders the signup
form.

---

## 2026-06-27 23:00 CT — n8n CT had no Tailscale (silent install failure)

**Symptom:** `pct exec <n8n-ct> -- tailscale status` returns `bash: tailscale:
command not found`. Earlier setup-n8n.sh run had said "Joining Tailscale..."
but the binary isn't there.

**Root cause:** Earlier version of `setup-n8n.sh` ran the Tailscale install
inside `bash -lc "... >/dev/null 2>&1"`, masking any install failure. The
install actually failed (network blip, repo unreachable, etc.) but the script
reported success.

**Fix:** Make the Tailscale install step loud:
- Strip `>/dev/null 2>&1` from the install
- After install, verify `command -v tailscale` exists before attempting `up`
- If the binary is missing, surface a clear warning that the CT is LAN-only
  and the user needs `/etc/hosts` entries to resolve in-stack hostnames

**Files / Commit:** `addons/setup-n8n.sh` (commit `f8c85d8`).

**Related:** When LAN-only, the n8n CT also needs `/etc/hosts` entries for
`gitea`, `mattermost`, `ollama-pi-agent`, etc., to resolve correctly. The user
got bit because of a stale `10.27.0.239 gitea.localdomain` entry — see next.

---

## 2026-06-27 22:45 CT — Wrong Gitea reached due to stale /etc/hosts

**Symptom:** Gitea daily digest workflow runs but gets HTTP 401 on every API
call. The Gitea token works against `10.27.0.226` (the local CT) but not
against the URL n8n was resolving to.

**Root cause:** n8n CT's `/etc/hosts` had a stale entry from an earlier debug
session:
```
10.27.0.239     gitea.localdomain
```
`10.27.0.239` is the OTHER PVE host's Gitea CT — different install with a
different token. The Tailscale DNS search domain `localdomain` was auto-appended
to bare `gitea`, matching this entry, routing the request to the wrong server.

**Fix:** Strip the stale entry and add proper local mappings:
```bash
N8N_CTID=$(pct list | awk '/n8n /{print $1}')
pct exec $N8N_CTID -- sed -i '/gitea\.localdomain/d' /etc/hosts
pct exec $N8N_CTID -- bash -lc "cat >> /etc/hosts <<EOF
10.27.0.226 gitea
10.27.0.91 mattermost
10.27.0.116 ollama-pi-agent
10.27.0.157 openwebui
10.27.0.9 homepage
10.27.0.100 sandbox
EOF"
```

**Files / Commit:** Live fix only. Future work: bake an `/etc/hosts` writer
into every CT-creating addon so each new CT has a definitive local hostname →
local IP mapping for all in-stack services.

**Related:** Two-PVE name collision (above). Same root cause: parallel installs
on multiple machines using the same hostnames.

---

## 2026-06-27 22:15 CT — pi-bot 403 when posting to Mattermost channel

**Symptom:** Mattermost workflow run errors with:
```
"errorMessage": "Forbidden - perhaps check your credentials?",
"errorData": {"id": "api.context.permissions.app_error"}
```

**Root cause:** pi-bot is a valid Mattermost user with a valid token, but it
isn't a **member** of `#town-square` (or whatever channel the workflow targets).
Bots don't auto-join any channel at creation — including the default
town-square that every human user gets.

**Fix:** Add pi-bot to town-square via MM API (no admin required — bot can join
public channels itself):
```bash
MM_CTID=$(pct list | awk '/mattermost/{print $1}')
TOKEN=$(awk -F= '/^MATTERMOST_BOT_TOKEN=/ {sub(/^[^=]*=/,"",$0); val=$0} END {print val}' /root/td-tokens.txt)
TEAM_ID=$(awk -F= '/^MATTERMOST_TEAM_ID=/ {sub(/^[^=]*=/,"",$0); val=$0} END {print val}' /root/td-tokens.txt)
pct exec $MM_CTID -- bash -lc "
  BOT_USER=\$(curl -sS -H 'Authorization: Bearer $TOKEN' http://localhost:8065/api/v4/users/me | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"id\"])')
  CHAN_ID=\$(curl -sS -H 'Authorization: Bearer $TOKEN' http://localhost:8065/api/v4/teams/$TEAM_ID/channels/name/town-square | python3 -c 'import sys,json; print(json.load(sys.stdin)[\"id\"])')
  curl -sS -X POST -H 'Authorization: Bearer $TOKEN' -H 'Content-Type: application/json' -d \"{\\\"user_id\\\":\\\"\$BOT_USER\\\"}\" http://localhost:8065/api/v4/channels/\$CHAN_ID/members
"
```

**Files / Commit:** `addons/setup-mattermost.sh` (commit `017997e`) — fresh
installs auto-add pi-bot to town-square + #bot + #ai-chat.

**Related:** Mattermost SSRF gate (below) — different layer of "this should
just work" but doesn't out of the box.

---

## 2026-06-27 21:45 CT — Mattermost outgoing webhooks blocked by SSRF gate

**Symptom:** Outgoing webhook configured to point at `http://n8n:5678/webhook/mm-chat`. Trigger word fires. Nothing reaches n8n. Mattermost server log silent.

**Root cause:** Mattermost has anti-SSRF protection that blocks outgoing
webhook destinations resolving to RFC1918 / private IPs. The gate setting is
`ServiceSettings.AllowedUntrustedInternalConnections`, default empty (= block
all). Famously under-documented.

**Fix:** Set the allowlist via API config PUT (admin token required):
```bash
"ServiceSettings": {
  "AllowedUntrustedInternalConnections":
    "localhost 127.0.0.1 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 n8n ollama-pi-agent gitea openwebui homepage sandbox mattermost",
  "EnablePostUsernameOverride": true,
  "EnablePostIconOverride": true,
  "EnableDynamicClientRegistration": true
}
```

Restart Mattermost. (`EnableDynamicClientRegistration` was the user's recall
from a prior install — included as belt-and-suspenders, possibly fixes an
unrelated MM bug that interfered with webhooks.)

**Files / Commit:** `addons/setup-mattermost.sh` (commits `40c874e` + `f520111`)
— baked into `configure_mattermost`'s config PUT block.

**Related:** Gitea SSRF gate (2026-06-28 02:15 entry). Same architectural
pattern — check both first when service-to-service webhooks silently fail.

---

## 2026-06-27 21:30 CT — Owner password update via UI fails (browser cache)

**Symptom:** Updated password hash in n8n's `database.sqlite` directly. `curl`
against `/rest/login` returns HTTP 200 OK with valid session cookie. Browser
form keeps saying "Wrong username or password."

**Root cause:** Browser has stale `n8n-auth` session cookie from a previous
login attempt + cached frontend state. n8n's frontend uses the stale cookie
before falling back to fresh form auth, getting 401, and looping.

**Fix:** Open n8n in an **Incognito / Private** browser window. Or clear
cookies + localStorage for the n8n origin in DevTools → Application tab,
hard-refresh.

**Files / Commit:** No code change — pure browser-side state.

**Related:** Any auth flow where direct API works but UI doesn't — first
suspect is browser session state.

---

## 2026-06-27 21:00 CT — Mistakenly pasted placeholder text as a token

**Symptom:** `N8N_API_KEY=<paste the key here>` appears literally in
`/root/td-tokens.txt`. Script keeps using the 20-char placeholder string as
the API key and getting 401 from n8n.

**Root cause:** Followed copy-paste instructions including the literal
`<paste the key here>` placeholder. Appended the real key on a second line
later. `read_token` originally took the **first** match for a key, returning
the bogus placeholder.

**Fix:** Two changes to `read_token` in `setup-n8n.sh`:
- Return the **last** match (so later appends override earlier values)
- Reject obvious placeholder values: `<...>`, `REPLACE_ME`, `CHANGEME`,
  empty string

Also added a duplicate-line warning to `diagnose-n8n.sh` that fires loudly if
multiple `N8N_API_KEY=` lines exist.

**Files / Commit:** `addons/setup-n8n.sh` + `addons/n8n/diagnose-n8n.sh`
(commit `5c2710b`).

**Related:** Generic shell-instruction-following risk. If a copy-paste
snippet contains a `<placeholder>`, run-as-is is a possible failure mode.

---

## 2026-06-27 20:30 CT — n8n owner setup needed real email + numeric password

**Symptom:** First-run n8n owner setup via `/rest/owner/setup` fails. Manual
signup via UI works, but only with a real email and a password containing at
least one number.

**Root cause:** n8n 2.x's owner setup:
- Requires the email field to be a real reachable mailbox (sends activation
  code). `admin@homelab.local` doesn't work.
- Validates that the password contains at least one digit (in addition to the
  usual 8+ chars).

The stack-wide `ADMIN_PASSWORD` is letters-only by default and `ADMIN_EMAIL`
is synthetic, so neither field satisfies n8n.

**Fix:** Add per-app overrides in `/root/td-tokens.txt`:
```
N8N_OWNER_EMAIL=you@tutanota.com
N8N_OWNER_PASSWORD=Xnrs9gRWeHLGM7p
```
`setup-n8n.sh` prefers these when set, falls back to `ADMIN_*` otherwise. The
script's pre-flight prints a warning if the password it's about to use has no
digit, so the failure mode is explicit not silent.

**Files / Commit:** `addons/setup-n8n.sh` (commit `e2dd1da`). README-addons.md
documents the requirements.

**Related:** Service-specific account requirements that don't match
stack-wide defaults — pattern likely to repeat with other services. Each
addon's preflight should validate against the service's specific rules.

---

## 2026-06-27 20:00 CT — Shell quoting: env-vars must precede python3

**Symptom:** Python `KeyError: 'ADMIN_EMAIL'` when running:
```bash
OWNER_BODY="$(python3 -c '...' ADMIN_EMAIL="$ADMIN_EMAIL" ...)"
```

**Root cause:** Bash treats `KEY=VAL` at the **end** of a command line as
positional argv (which python ignores), not env vars. Only `KEY=VAL` at the
**start** of the command sets env.

**Fix:** Move env vars before the command:
```bash
OWNER_BODY="$(ADMIN_EMAIL="$ADMIN_EMAIL" python3 -c '...')"
```

**Files / Commit:** `addons/setup-n8n.sh` (commit `fcded8b`).

**Related:** General shell pattern — applies anywhere `VAR=val cmd` is used
to inject env. Always at the start.

---

## 2026-06-27 19:45 CT — JSON payload corrupted through pct exec quoting

**Symptom:** n8n credential creation via REST API returns 4xx errors with
mangled JSON in the request body. Direct curl from inside the CT works.

**Root cause:** `pct exec <ct> -- bash -lc "curl -d '$body'"` where `$body`
contains JSON with `"` characters: the `"` in JSON collides with the outer
`bash -lc "..."` double-quote delimiter, mangling curl's `-d` argument.

**Fix:** Write the payload to a temp file inside the CT and use `curl
--data-binary @file`:
```bash
printf '%s' "$body" > /tmp/payload.tmp
pct push "$CTID" /tmp/payload.tmp /tmp/n8n-body.json
pct exec "$CTID" -- bash -lc "curl ... --data-binary @/tmp/n8n-body.json"
```

**Files / Commit:** `addons/setup-n8n.sh` (commit `c3e3553`).

**Related:** Generic — any time a payload contains arbitrary characters and
needs to traverse multiple quoting layers, use file-based transport.

---

## 2026-06-27 19:30 CT — n8n public API rejects giteaApi / ollamaApi credentials

**Symptom:** Creating a credential of type `giteaApi` (or `ollamaApi`) via
`POST /api/v1/credentials` returns:
```json
{"message": "req.body.type is not a known type"}
```

**Root cause:** n8n 2.x's public REST API maintains a smaller whitelist of
credential types than the UI's full picker. Some types (including `giteaApi`
and `ollamaApi`) exist in the UI but are blocked from creation via REST for
security.

**Fix:** Use a generic credential that IS on the API whitelist and is
functionally equivalent. For Gitea: create `httpHeaderAuth` named
"Gitea (admin) — Bearer" with value `token <PAT>`. Any HTTP Request node can
use it against any Gitea endpoint. Same for Ollama: skip the credential
entirely; Ollama is unauthenticated on tailnet, use a plain HTTP Request node
to `http://ollama-pi-agent:11434/api/chat`.

**Files / Commit:** `addons/setup-n8n.sh` (commits `017997e` + `1bf2761`).

**Related:** When the n8n public API doesn't accept a credential type, fall
back to `httpHeaderAuth` or `httpBasicAuth` plus an HTTP Request node.

---

## 2026-06-27 19:00 CT — Fake n8n node type in workflow JSON

**Symptom:** Activating the `mm-ollama-chat` workflow fails with:
```
Unrecognized node type: n8n-nodes-base.ollama
```

**Root cause:** `n8n-nodes-base.ollama` doesn't exist as a node type. The real
Ollama node lives in the LangChain package at
`@n8n/n8n-nodes-langchain.lmChatOllama`, which may or may not be installed in
the community-scripts n8n image.

**Fix:** Replace the dedicated Ollama node with a generic HTTP Request node
posting to `http://ollama-pi-agent:11434/api/chat` with body:
```json
{
  "model": "gemma4:31b-cloud",
  "stream": false,
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "{{$json.body.text}}"}
  ]
}
```
Ollama is unauthenticated on tailnet so no credential needed. Works on any n8n
install regardless of LangChain package presence.

**Files / Commit:** `addons/n8n/workflows/mm-ollama-chat.json` + `addons/setup-n8n.sh` (commit `1bf2761`).

**Related:** Generic: when a node type doesn't exist or depends on an optional
package, fall back to HTTP Request + the service's REST API.

---

## 2026-06-27 18:30 CT — Gitea webhook payload structure surprise

**Symptom:** Gitea events fired, n8n received the webhook, but Format event
node returned `{skip: true}` for every push — never matched the push branch.

**Root cause:** My switch statement checked `headers['x-gitea-event']` but
wasn't seeing the value I expected. Turned out the actual issue was n8n's
header normalization: it lowercases everything, but my code was
case-sensitive on the **value** side (`'push'` vs `'Push'`). Gitea sends
lowercase event values so this happened to work, but other services with
mixed-case values would fail.

**Fix:** Lowercase the event value defensively:
```javascript
const eventType = (headers['x-gitea-event'] || '').toLowerCase();
```

**Files / Commit:** `addons/n8n/workflows/gitea-events-to-mattermost.json` (initial commit `884c33e`).

**Related:** Anything reading HTTP headers from n8n: keys are lowercased,
but values are passed through as-is. Always normalize the value side too.

---

## 2026-06-27 18:00 CT — n8n owner-setup REST endpoint returns conflicting codes

**Symptom:** `POST /rest/owner/setup` returns HTTP 400 even though the owner
doesn't exist yet. Or returns 400 the second time when the owner is set up.

**Root cause:** n8n 2.x returns:
- HTTP 200/201 on first successful setup
- HTTP 400 if owner already exists (response body says "already")
- HTTP 400 if the request body fails validation (e.g., password rules)
The same status code means two very different things; need to check the body.

**Fix:** Case on the HTTP code, but distinguish:
- 200/201 → success
- 400 + body mentions "already" → owner exists, log in instead
- 400 + body says validation → re-prompt with corrected fields

**Files / Commit:** `addons/setup-n8n.sh` (commit `fcded8b`).

**Related:** When a REST API uses overloaded status codes, always inspect the
response body before reacting.

---

## 2026-06-27 17:00 CT — Gitea CLI deprecated --username flag

**Symptom:** `gitea admin user delete-access-token --username admin --name pi-agent`
fails on Gitea 1.26: `unknown flag --username`.

**Root cause:** Gitea 1.26 removed `--username` from the token-management
CLI subcommands. The CLI's surface is unstable across versions.

**Fix:** Switch all token management to the REST API (stable since 1.18):
```bash
# Delete: DELETE /api/v1/users/{user}/tokens/{name}
# Mint:   POST /api/v1/users/{user}/tokens  → returns sha1
```
Both accept basic auth as the target user.

**Files / Commit:** `automation/configure-apps.sh` (commit history pre-dates
this log; check `configure_gitea` for the REST-based implementation).

**Related:** When a service's CLI is unstable but the REST API is documented
to be stable, prefer the API even from inside the CT.

---

## End-of-log housekeeping

When this file gets long, the oldest entries can be moved to
`TROUBLESHOOTING_LOG_<year>.md` archive files. Don't delete — they're the
record of what was tried.

If a new entry duplicates an existing one (same symptom, same fix), add a
cross-reference to `**Related:**` instead of writing a duplicate entry. If
the same architectural pattern shows up a third time, promote it to the
"Architectural patterns to recognize fast" section at the top.

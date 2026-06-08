# Addons

Optional scripts that layer on top of the core homelab built by [`automation/`](../automation/). Each addon is self-contained and assumes the base stack already exists — the CTs (`ollama-pi-agent`, `docker`, `gitea`, `openwebui`, `homepage`) are running and joined to Tailscale.

If you haven't run the automation scripts yet, start there: [automation/README-automation.md](../automation/README-automation.md).

---

## Available addons

| Script | What it does | Target CT | Time |
|---|---|---|---|
| [`setup-filebrowser.sh`](setup-filebrowser.sh) | Drag-and-drop web UI for getting files into `ollama-pi-agent` where pi can read them | `ollama-pi-agent` | ~3 min |
| [`setup-pi-web-uis.sh`](setup-pi-web-uis.sh) | Three browser UIs on `ollama-pi-agent`: cards (9090), pi terminal (9091), plain bash shell (9092) | `ollama-pi-agent` | ~5 min |
| [`setup-port80-redirect.sh`](setup-port80-redirect.sh) | Kernel-level NAT redirect so `http://gitea`, `http://openwebui`, `http://homepage` work without typing `:3000` / `:8080` | `gitea`, `openwebui`, `homepage` | ~1 min |

---

## `setup-filebrowser.sh`

Installs [filebrowser](https://github.com/filebrowser/filebrowser) on `ollama-pi-agent` and exposes `/root/uploads/` as a drag-and-drop web UI at `http://ollama-pi-agent:8080`. Drop a PDF or markdown file in the browser tab, immediately reference it in a pi prompt like `"summarize the PDF in /root/uploads/"` — no scp, no rsync, no sftp client.

**What you get:**

- Single 20 MB Go binary running as a systemd service inside CT 200
- Web UI: drag-drop upload, folder navigation, in-browser text edit, file preview
- JSON-file auth with one admin user, JWT sessions
- Files land at `/root/uploads/` on `ollama-pi-agent` — already visible to pi without any additional setup
- Optional Homepage tile (script prints the YAML snippet to paste)

**Prereqs:**

- `ollama-pi-agent` CT exists and is running (from `bootstrap-pve.sh`)
- Tailscale is up on the CT (so `http://ollama-pi-agent:8080` resolves via MagicDNS)
- You have admin creds you want to use for the filebrowser login

**Install:**

```bash
# On the PVE host
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-filebrowser.sh \
  -o /root/setup-filebrowser.sh
chmod +x /root/setup-filebrowser.sh
/root/setup-filebrowser.sh
```

The script prompts for:
1. Admin username (e.g. `td`)
2. Admin password (hidden, confirmed twice, min 8 chars)

…then installs the binary, initializes `/etc/filebrowser/filebrowser.db`, creates the admin user, drops a systemd unit, and starts the service. End state: `http://ollama-pi-agent:8080` is live.

**Or from your own Gitea (after first push):**

```bash
curl -fsSL http://gitea:3000/<your-gitea-user>/td-proxmox/raw/branch/main/addons/setup-filebrowser.sh \
  -o /root/setup-filebrowser.sh
```

**Flags for unusual cases:**

| Flag | Default | What it does |
|---|---|---|
| `--ct-id N` | (hostname lookup) | Target a CT by ID instead of looking up `ollama-pi-agent` |
| `--hostname X` | `ollama-pi-agent` | Look up a CT by a different hostname |
| `--root <path>` | `/root/uploads` | Filesystem path the UI exposes |
| `--port <n>` | `8080` | Port filebrowser listens on inside the CT |
| `--admin-user <name>` | (prompt) | Skip the prompt |
| `--admin-password <pw>` | (prompt) | Skip the prompt |
| `--dry-run` | — | Preview commands without running them |

**After install:**

Open `http://ollama-pi-agent:8080` from any device on your tailnet, log in, drag files into the browser. They appear at `/root/uploads/` inside CT 200.

To wire it into Homepage's dashboard, the script's final log lines print a YAML snippet — paste it into your Homepage `services.yaml` under whatever group makes sense:

```yaml
- Files:
    href: http://ollama-pi-agent:8080
    description: Drop files for pi to use
    icon: filebrowser.png
```

Restart Homepage (or wait — its watcher picks up file changes), and the tile shows up on the dashboard.

**Idempotent.** Re-running detects the existing install and updates the admin user's password rather than failing. Safe to invoke again whenever you want to rotate credentials.

---

---

## `setup-pi-web-uis.sh`

Installs **three** browser UIs side-by-side on `ollama-pi-agent`:

- **Port 9090 — cards UI** ([VVander/pi-remote-web-ui](https://github.com/VVander/pi-remote-web-ui)). Purpose-built for pi: tool outputs render as expandable cards, thinking blocks are surfaced separately, multiple browser tabs share one session via WebSocket. Uses pi's `AgentSession` SDK in-process (the upstream-recommended pattern, no subprocess spawning).
- **Port 9091 — pi terminal** ([ttyd](https://github.com/tsl0922/ttyd) wrapping `ollama launch pi`). xterm.js in a browser tab. Same experience as `pct enter 200 && ollama launch pi`. HTTP basic auth.
- **Port 9092 — plain shell** (ttyd wrapping `bash` at `/root`). Same `pct enter 200` experience without auto-launching pi — useful for `git`/`curl`/file inspection/log tail-ing or just kicking the CT around. HTTP basic auth.

Why all three: the cards UI is nicer for day-to-day pi prompting (tool calls don't blow past your scrollback, thinking is collapsed), the pi terminal is a bulletproof fallback when the cards UI doesn't render some new feature, and the plain shell is for everything that isn't agent-driven (debugging, inspection, manual commands).

**Prereqs:**

- `ollama-pi-agent` CT exists, is running, and has pi installed (from `setup-ollama-pi.sh` — the cards UI reuses pi's bundled Node.js install)
- Tailscale is up on the CT (so `http://ollama-pi-agent:9090` and `:9091` resolve via MagicDNS)

**Install:**

```bash
# On the PVE host
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-pi-web-uis.sh \
  -o /root/setup-pi-web-uis.sh
chmod +x /root/setup-pi-web-uis.sh
/root/setup-pi-web-uis.sh
```

The script prompts for an admin username + password (used for the ttyd basic auth on the terminal UI; the cards UI has no built-in auth and relies on your tailnet boundary).

**What it does, step by step:**

1. `apt install` git, ttyd, build-essential inside the CT.
2. Clones `pi-remote-web-ui` to `/opt/pi-remote-web-ui`, runs `npm install && npm run build && npm run build:server` using pi's standalone Node (`/root/.local/share/pi-node/node-v*/bin/node` — no second Node install).
3. Patches the upstream's `127.0.0.1:8080` bind to `0.0.0.0:9090` so the cards UI is reachable across the tailnet. (VVander's default was designed for SSH-tunneled access on a VPS; tailnet is our security boundary instead.)
4. Drops `pi-cards.service` (cards UI) and `pi-term.service` (ttyd) as systemd units, enables both.
5. Verifies both services are running.
6. Prints Homepage tile YAML for both ports.

**Flags for unusual cases:**

| Flag | Default | What it does |
|---|---|---|
| `--ct-id N` | (hostname lookup) | Target a CT by ID instead of looking up `ollama-pi-agent` |
| `--hostname X` | `ollama-pi-agent` | Look up a CT by a different hostname |
| `--cards-port N` | `9090` | Port for the cards UI |
| `--term-port N` | `9091` | Port for the pi terminal UI |
| `--shell-port N` | `9092` | Port for the plain shell UI |
| `--admin-user <name>` | (prompt) | Skip the prompt |
| `--admin-password <pw>` | (prompt) | Skip the prompt |
| `--only cards` | — | Install only the cards UI |
| `--only terminal` | — | Install only the pi terminal UI |
| `--only shell` | — | Install only the plain shell UI |
| `--only cards,shell` | — | Combine subsets |
| `--dry-run` | — | Preview commands |

**Security note.** The cards UI has no built-in authentication — it inherits trust from whoever can reach port 9090 on the tailnet. For a personal homelab with a closed tailnet that's fine. If you have multiple tailnet users and want to restrict the cards UI further, the easiest fix is a Tailscale ACL rule limiting port 9090 to your own user. ttyd on 9091 has HTTP basic auth as a second layer.

**Idempotent.** Re-running detects an existing clone and `git pull`s the latest. Systemd units are recreated and restarted.

---

---

## `setup-port80-redirect.sh`

Lets you type `http://gitea` instead of `http://gitea:3000`. Same for `http://openwebui` and `http://homepage`. The apps stay on their high ports; the kernel quietly rewrites incoming `:80` traffic to the real port before it reaches the app.

**Why these defaults exist in the first place.** Ports below 1024 (the "privileged" range) require root or `CAP_NET_BIND_SERVICE` on Linux. Modern web apps run as a dedicated unprivileged user for security, so they default to higher ports (3000, 8080) that don't need elevated permissions. In a Docker / multi-tenant world this is normal — you put a reverse proxy on 80 and route to the apps' high ports. Our "one CT per app + Tailscale MagicDNS" homelab is the unusual case where typing the port is friction without payoff.

**How it works.** A single `iptables` NAT rule per CT:

```
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 3000
```

That tells the kernel: rewrite the destination port of any incoming TCP packet bound for :80 to :3000 before the app sees it. The app itself is unchanged — it keeps listening on 3000 and never knows. Both URLs work: `http://gitea` and `http://gitea:3000`. A small systemd oneshot re-applies the rule on every boot so it survives reboots without needing `iptables-persistent`.

**Targets:**

| Hostname | Redirect |
|---|---|
| `gitea` | 80 → 3000 |
| `openwebui` | 80 → 8080 |
| `homepage` | 80 → 3000 |

`docker` and `ollama-pi-agent` aren't included because they don't have a single obvious "primary" web service — `ollama-pi-agent` runs filebrowser on 8080, pi UIs on 9090–9092, and pinning one to port 80 would mask the others.

**Install:**

```bash
# On the PVE host
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/addons/setup-port80-redirect.sh \
  -o /root/setup-port80-redirect.sh
chmod +x /root/setup-port80-redirect.sh
/root/setup-port80-redirect.sh
```

No prompts. Loops over each `hostname:port` pair in the script's `REDIRECTS=(...)` array, finds the CT, applies the rule, drops a systemd unit. Idempotent — re-running checks for the rule with `iptables -C` before adding, so no duplicate rules pile up.

**Test from your workstation:**

```bash
curl -sI http://gitea  | head -1   # Should be 200 / 302 / 303 (Gitea login redirect)
curl -sI http://homepage | head -1
```

**Uninstall:**

```bash
/root/setup-port80-redirect.sh --uninstall
```

Removes the systemd unit and deletes the iptables rule from each CT. The apps continue to work on their original ports.

**Flags:**

| Flag | What it does |
|---|---|
| `--uninstall` | Reverse the changes (remove rules + units, leave apps untouched) |
| `--dry-run` | Print commands without executing |

**Extending.** To add another CT, edit the `REDIRECTS=(...)` array at the top of the script. Each entry is `hostname:port`. To add SSL termination later, the natural upgrade is to drop a small reverse proxy (Caddy is a one-binary fit) on each CT and let it handle 80 → 443 + auto-HTTPS via Tailscale's MagicDNS certificates.

---

## Adding your own addon

Drop a new `setup-<thing>.sh` into this folder. The patterns from `setup-filebrowser.sh` are worth borrowing:

- Auto-detect the target CT by hostname (`find_ct_by_hostname`) with a `--ct-id` override.
- Interactive prompts for required inputs, with `--flag value` overrides for automation.
- `--dry-run` that skips state-changing operations but still prints what would happen.
- Idempotent re-runs (check whether the work is already done before doing it).
- Final log lines that print the access URL and any next-step config.

Then add a row to the table at the top of this file describing it. If it's useful enough to surface, also link it from the top-level [`README.md`](../README.md).

# Addons

Optional scripts that layer on top of the core homelab built by [`automation/`](../automation/). Each addon is self-contained and assumes the base stack already exists — the CTs (`ollama-pi-agent`, `docker`, `gitea`, `openwebui`, `homepage`) are running and joined to Tailscale.

If you haven't run the automation scripts yet, start there: [automation/README-automation.md](../automation/README-automation.md).

---

## Available addons

| Script | What it does | Target CT | Time |
|---|---|---|---|
| [`setup-filebrowser.sh`](setup-filebrowser.sh) | Drag-and-drop web UI for getting files into `ollama-pi-agent` where pi can read them | `ollama-pi-agent` | ~3 min |

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

## Adding your own addon

Drop a new `setup-<thing>.sh` into this folder. The patterns from `setup-filebrowser.sh` are worth borrowing:

- Auto-detect the target CT by hostname (`find_ct_by_hostname`) with a `--ct-id` override.
- Interactive prompts for required inputs, with `--flag value` overrides for automation.
- `--dry-run` that skips state-changing operations but still prints what would happen.
- Idempotent re-runs (check whether the work is already done before doing it).
- Final log lines that print the access URL and any next-step config.

Then add a row to the table at the top of this file describing it. If it's useful enough to surface, also link it from the top-level [`README.md`](../README.md).

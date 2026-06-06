# TD-Proxmox — Automated Build Run Sheet

End state after a full run: a Proxmox VE 9.x host with five LXC containers (`ollama-pi-agent`, `docker`, `gitea`, `openwebui`, `homepage`), all joined to your Tailscale tailnet, Gitea + OpenWebUI configured with admin accounts and an OpenRouter connection, Homepage running with a default dashboard ready for pi to populate, and pi itself running on `ollama-pi-agent`.

Total time from "USB plugged in" to "Homepage dashboard up": ~45 minutes, of which roughly 10 minutes is your hands on the keyboard.

---

## Run order

| # | Phase | How | Roughly |
|---|---|---|---|
| 1 | Flash USB, boot, install Proxmox | Manual (Etcher + BIOS + graphical installer) | 15 min |
| 2 | First web UI login + grab the IP | Manual (browser) | 1 min |
| 3 | `bootstrap-pve.sh` | One script on the PVE host | 18 min |
| 4 | Pair Ollama device | Manual (one browser click) | 1 min |
| 5 | `configure-apps.sh` | One script on the PVE host | 3 min |
| 6 | pi prompts (the actual point) | Interactive in `ollama launch pi` | open-ended |

Phases 1, 2, and 4 are the only manual stops. Everything else is a single command.

---

## Before you start

Have ready:

- A USB drive (8 GB+) with the Proxmox VE 9.1 ISO flashed via Balena Etcher.
- An SSH keypair on your workstation. `ssh-keygen -t ed25519` if you don't have one.
- An account at **tailscale.com** with an auth key minted in advance: admin console → Settings → Keys → Generate auth key → reusable, no expiry needed for first run.
- An account at **openrouter.ai** with at least one API key (`sk-or-...`).
- An account at **ollama.com** (no token needed yet — pairing is done in-flow).

Everything else is bootstrapped by the scripts.

---

## Phase 1–2 — Install Proxmox + first login

This part stays manual until you want to invest in a custom unattended-install ISO. Follow the `Proxmox VE Installation.pptx` deck through the install screens (target disk, country/timezone, hostname, management IP, root password). After reboot, browse to `https://<pve-ip>:8006`, log in as `root`, and note the IP.

---

## Phase 3 — `bootstrap-pve.sh`

Open the PVE web UI's `>_ Shell` on the node. The fastest way to get the script onto a fresh host is to fetch it directly from GitHub:

```bash
# Fetch + run interactively (process substitution keeps stdin free for prompts)
bash <(curl -fsSL https://raw.githubusercontent.com/<your-github-user>/td-proxmox/main/automation/bootstrap-pve.sh) --dry-run
```

Or, equivalently, download then run — easier to debug, easier to re-run:

```bash
curl -fsSL https://raw.githubusercontent.com/<your-github-user>/td-proxmox/main/automation/bootstrap-pve.sh \
  -o /root/bootstrap-pve.sh
chmod +x /root/bootstrap-pve.sh
/root/bootstrap-pve.sh --dry-run
```

> **Don't use `curl … | bash`.** The script is interactive — `bash` would consume stdin from the pipe, leaving nothing for the SSH-key/Tailscale-key/password prompts to read. Use process substitution `bash <(curl …)` or download-then-run instead.

**Alternative paths** if you don't have GitHub access from the host (offline lab, restricted network, etc.):

- `scp ~/td-proxmox/automation/bootstrap-pve.sh root@<pve-ip>:/root/` from your workstation.
- Paste the script contents directly into `nano /root/bootstrap-pve.sh` in the web UI shell — it's ~6 KB, paste is instant.

The script doesn't need any flags up front. It will prompt you to paste, in order:

1. Your workstation's SSH **public** key (one line, starts with `ssh-...`).
2. A Tailscale auth key (`tskey-auth-...`) — input hidden.
3. A root password for the new CTs — input hidden, confirmed twice.

This solves the chicken-and-egg on a fresh install: you don't need to scp the public key over first or have anything else preloaded on the host. If you'd rather pass them non-interactively (e.g. from a CI driver or vault helper), the same values can come in as `--sshkey-file`, `--sshkey-text`, `--tsauthkey`, `--ct-password` flags.

Drop `--dry-run` once the printed command sequence looks right. The script:

1. Disables the enterprise repo, enables `pve-no-subscription`.
2. Runs `apt update && apt upgrade -y`.
3. Drops your workstation pubkey into `/root/.ssh/authorized_keys`.
4. Runs `pveam update` + `pveam download local debian-12-standard...`.
5. Creates `ollama-pi-agent` (CT 200) with `pct create`, plus the TUN passthrough config.
6. Runs the community helper scripts for `docker` (CT 215, with Docker preinstalled), `gitea` (CT 202), `openwebui` (CT 100), and `homepage` (CT 110).
7. Applies the Tailscale add-on to each CT and runs `tailscale up --authkey=...` non-interactively.

End state: five containers running, all reachable by MagicDNS name (`ollama-pi-agent`, `docker`, `gitea`, `openwebui`, `homepage`) from any device on your tailnet.

Idempotent. Safe to re-run — existing CTs are skipped.

---

## Phase 4 — Ollama device pairing

This is the only part that can't be eliminated without storing your Ollama session on disk. `pct enter 200` into ollama-pi-agent, then:

```bash
apt install -y curl zstd
curl -fsSL https://ollama.com/install.sh | sh
ollama signin
```

`ollama signin` prints a URL like `https://ollama.com/connect?name=ollama-pi&key=...`. Paste it into a browser where you're logged into ollama.com, click **Connect**. Done. Pull a model to confirm:

```bash
ollama pull gemma3:12b-cloud
```

(You can also install pi here with `curl -fsSL https://pi.dev/install.sh | sh` and the printed `export PATH=...` line, or leave it for later.)

---

## Phase 5 — `configure-apps.sh`

Back on the PVE host. By now Gitea is up, so you have two equally good sources for the script:

```bash
# From GitHub (canonical, always reachable)
curl -fsSL https://raw.githubusercontent.com/<your-github-user>/td-proxmox/main/automation/configure-apps.sh \
  -o /root/configure-apps.sh

# Or from your own Gitea (after you've pushed there too)
curl -fsSL http://gitea:3000/td/td-proxmox/raw/branch/main/automation/configure-apps.sh \
  -o /root/configure-apps.sh

chmod +x /root/configure-apps.sh
/root/configure-apps.sh \
  --admin-user      td \
  --admin-email     td@homelab.local \
  --admin-password  'something-strong' \
  --openrouter-key  'sk-or-...' \
  --dry-run
```

Drop `--dry-run` to commit. The script:

1. Creates the Gitea admin user via `gitea admin user create`, mints an access token named `pi-agent`.
2. Creates the OpenWebUI admin user via `/api/v1/auths/signup`, logs in, and adds an OpenRouter connection (`https://openrouter.ai/api/v1`) under OpenAI-compatible providers.
3. On ollama-pi-agent, writes `/root/.netrc` with the Gitea creds and persists `OPENROUTER_API_KEY` in `/root/.bashrc`.
4. On homepage, writes a starter `services.yaml` (Gitea + widget, OpenWebUI, ollama-pi-agent, docker), `settings.yaml` (theme, title, layout), `bookmarks.yaml` (Proxmox + Tailscale + OpenRouter + Ollama admin links), and `widgets.yaml` (resources + search bar), then restarts the service.

A credentials summary is written to `/root/td-tokens.txt` (chmod 600) and echoed to stdout. Open `http://homepage:3000` from any tailnet device — every tile already points at the right place.

---

## Phase 6 — pi prompts

`pct enter 200`, then `ollama launch pi`, pick a model, and start prompting. The earlier scripts have already given pi the credentials it needs:

- Gitea: `.netrc` already on disk, push/pull "just works" on `http://gitea:3000/td/<repo>.git`.
- OpenRouter: `OPENROUTER_API_KEY` already in environment — ask pi to add it as a model provider on first launch.

Sample prompts that mirror the deck demo (Docker is already installed on the `docker` CT, so pi can go straight to using it):

> "ssh into the docker container and run `docker run hello-world`. Show me the output."
>
> "ssh into the docker container and tell me what's listening on which port."
>
> "write a small Python CLI that prints a random programming joke. Init a git repo, push to Gitea as `td/joke-cli`."
>
> "ssh into the docker container, clone td/joke-cli, build it as a container image, and run it."
>
> "ssh into the homepage container, open services.yaml, and add a tile for the joke-cli repo under Development. Restart the service. The other tiles are already there from configure-apps.sh — just slot the new one in."

---

## What's left to automate

In rough order of effort vs payoff:

- **pi provider config** — the one gap in `configure-apps.sh`. Pi's CLI for adding model providers isn't stable, so the current script just sets `OPENROUTER_API_KEY` and leaves the wiring to a first-launch prompt. If pi.dev stabilizes a `pi providers add` command, this becomes a one-liner.
- **Homepage tile config** — `services.yaml` and `widgets.yaml` for Homepage have a clean schema. A `configure-homepage.sh` that takes the four tailnet hostnames + Gitea token and emits these files would replace prompt 6 entirely.
- **Ollama device pairing** — eliminable only if you're willing to scrape the connect URL out of `ollama signin` output and open it in a headless browser with stored creds. Honestly not worth it for a one-time setup.
- **Proxmox unattended install** — `proxmox-auto-install-assistant` + an answer file can produce a no-keyboard installer ISO. Replaces phases 1–2 entirely. ~2 hours to set up, pays off the third time you reinstall.

---

## File layout

```
TD-Proxmox/
├── automation/
│   ├── bootstrap-pve.sh        # Phase 3
│   ├── configure-apps.sh       # Phase 5
│   └── README-automation.md    # This file
├── follow-along-guide.md       # The manual walkthrough (source of truth for what each phase does)
├── concepts-deep-dive.md       # Background reading
└── Proxmox VE Installation.pptx   # Slide deck for live presentation
```

Both scripts support `--dry-run`, `--only <subset>`, and `--help`. Read the header comment at the top of each for the full flag list.

# TD-Proxmox

Bootstrap a Proxmox VE 9.x homelab — five LXC containers, Tailscale-joined, with Gitea + OpenWebUI + Homepage preconfigured and an Ollama-hosted `pi` coding agent ready to drive the rest.

Run sheet and core scripts live in **[`automation/`](automation/)**:

- **`bootstrap-pve.sh`** — fresh PVE host → five running CTs (`ollama-pi-agent`, `sandbox`, `gitea`, `openwebui`, `homepage`), all on your tailnet. `sandbox` is the Docker host (built via the community `docker.sh` helper); the rename keeps prompts like "run a docker image on sandbox" unambiguous.
- **`setup-ollama-pi.sh`** — installs Ollama on `ollama-pi-agent` and `openwebui`, walks you through device pairing (one browser click per CT), pulls a model, installs `pi` on `ollama-pi-agent`.
- **`configure-apps.sh`** — Gitea admin + access token, OpenWebUI admin + OpenRouter connection, pi credentials seeded on `ollama-pi-agent`, Homepage dashboard populated.
- **`README-automation.md`** — the operator run sheet that ties it all together.

Optional extras live in **[`addons/`](addons/)** — each script is self-contained and assumes a stack already built by the `automation/` scripts:

- **`setup-filebrowser.sh`** — installs filebrowser on both `ollama-pi-agent` and `sandbox` (configurable), exposing `/root/uploads/` as a drag-and-drop web UI on each (`http://ollama-pi-agent:8080`, `http://sandbox:8080`). Drop a PDF or markdown in the pi UI and reference it from a pi prompt; drop a Dockerfile or compose file in the sandbox UI and `ssh root@sandbox` to use it.
- **`setup-pi-web-uis.sh`** — installs three browser UIs on `ollama-pi-agent`: a cards UI (tool calls/thinking blocks, multi-tab session) on 9090, a `ttyd`-wrapped pi terminal on 9091, and a plain `bash` shell on 9092.
- **`setup-port80-redirect.sh`** — adds a kernel-level NAT redirect on `gitea`, `openwebui`, and `homepage` so you can type `http://gitea` instead of `http://gitea:3000`. Apps unchanged; both URLs work.
- **`setup-pve-etc-backup.sh`** — daily systemd timer on the PVE host that snapshots `/etc/pve` + host network/SSH/apt config to your backup drive as a compressed tarball. Closes the gap `vzdump` leaves (CT data but not PVE's own state). Mountpoint-checked so an unplugged backup drive becomes a clean skip, never a host-root pollution.
- **`setup-vzdump-schedule.sh`** — installs a nightly `vzdump` job in `/etc/pve/jobs.cfg` (02:00, snapshot mode, zstd, retention `keep-daily=7,keep-weekly=4,keep-monthly=2`). Pairs with `setup-pve-etc-backup.sh` for a complete backup picture: host identity at 01:30, CT data at 02:00.
- **`setup-new-pi-agent.sh`** — spin up an additional `ollama-pi-agent`-style CT later (research agent, sandbox agent, etc.). Auto-numbers `pi-agent-2`, `pi-agent-3`, ... and wires it into the existing tailnet + SSH trust mesh + Homepage dashboard + SMB share. Delegates Ollama + pi install to `setup-ollama-pi.sh`, web UIs to `setup-pi-web-uis.sh`, SMB to `setup-smb-share.sh`.
- **`setup-smb-share.sh`** — expose `/root` on a pi agent over SMB so you can mount the agent's home directory from macOS Finder / Windows Explorer / Linux directly. Auth: Samba `root` user with password (reuses CT root password by default when called from `setup-new-pi-agent.sh`). Auto-installed for new agents; run once manually against the original `ollama-pi-agent`.

## One-command install (recommended)

From `/root` on a fresh PVE 9.x host:

```bash
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/bootstrap-fresh-pve.sh | bash
```

That single command installs git (if missing), clones this repo to `/root/td-proxmox`, and runs all three phases in sequence: `bootstrap-pve.sh` → `setup-ollama-pi.sh` → `configure-apps.sh`. Each phase is the same prompts you'd see running them manually — just no copy-paste between them.

**Add the Founder AI OS layer** (Dan Martell's framework as ollama-pi-agents) by passing a repo URL:

```bash
curl -fsSL https://raw.githubusercontent.com/artofax/td-proxmox/main/bootstrap-fresh-pve.sh \
  | bash -s -- --with-founder-os <your-founder-os-repo-url>
```

This runs the same TD-Proxmox phases, then clones the Founder OS repo and runs its Phase 1 install (The Chief + The Auditor).

**Flags:**
- `--dry-run` — preview every step without executing
- `--skip-ollama` / `--skip-configure` — skip a specific phase if you've already run it
- `--repo-url URL` — alternate TD-Proxmox source (default: GitHub)

## Manual install (run the phases yourself)

```bash
git clone https://github.com/artofax/td-proxmox.git /root/td-proxmox
cd /root/td-proxmox

./automation/bootstrap-pve.sh     # ~18 min — prompts for SSH key, Tailscale auth key, CT password.
                                  #          Click "Default Install" in each helper-script's whiptail menu (4 clicks total).
./automation/setup-ollama-pi.sh   # ~5 min  — Ollama + pi install. Two browser clicks for ollama.com device pairing.
./automation/configure-apps.sh    # ~3 min  — prompts for admin user/email/password + OpenRouter key.
                                  #          Gitea + OpenWebUI + Homepage all configured automatically.
```

Hands-on time: roughly 10 minutes of the ~45-minute total — 4 menu clicks during bootstrap, 2 browser clicks during setup-ollama-pi, plus the prompts in each phase.

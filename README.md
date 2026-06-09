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

From `/root` on a fresh PVE install:

```bash
./bootstrap-pve.sh              # ~18 min — prompts for SSH key, Tailscale auth key, CT password.
                                #          Click "Default Install" in each helper-script's whiptail menu (4 clicks total).
./setup-ollama-pi.sh            # ~5 min  — Ollama + pi install. Two browser clicks for ollama.com device pairing.
./configure-apps.sh             # ~3 min  — prompts for admin user/email/password + OpenRouter key.
                                #          Gitea + OpenWebUI + Homepage all configured automatically.
```

Hands-on time: roughly 10 minutes of the ~45-minute total — 4 menu clicks during bootstrap, 2 browser clicks during setup-ollama-pi, plus the prompts in each phase.

# TD-Proxmox

Bootstrap a Proxmox VE 9.x homelab — five LXC containers, Tailscale-joined, with Gitea + OpenWebUI + Homepage preconfigured and an Ollama-hosted `pi` coding agent ready to drive the rest.

Run sheet and scripts live in **[`automation/`](automation/)**:

- **`bootstrap-pve.sh`** — fresh PVE host → five running CTs (`ollama-pi-agent`, `docker`, `gitea`, `openwebui`, `homepage`), all on your tailnet.
- **`setup-ollama-pi.sh`** — installs Ollama on `ollama-pi-agent` and `openwebui`, walks you through device pairing (one browser click per CT), pulls a model, installs `pi` on `ollama-pi-agent`.
- **`configure-apps.sh`** — Gitea admin + access token, OpenWebUI admin + OpenRouter connection, pi credentials seeded on `ollama-pi-agent`, Homepage dashboard populated.
- **`README-automation.md`** — the operator run sheet that ties it all together.

From `/root` on a fresh PVE install:

```bash
./bootstrap-pve.sh              # ~18 min — prompts for SSH key, Tailscale auth key, CT password
./setup-ollama-pi.sh            # ~5 min — Ollama + pi install, two browser clicks for device pairing
./configure-apps.sh \
  --admin-user td --admin-email td@homelab.local \
  --admin-password '<strong>' --openrouter-key '<sk-or-…>'
# (3 min — Gitea + OpenWebUI + Homepage all configured)
```

Hands-on time: roughly 10 minutes of the ~45-minute total.

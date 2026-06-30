# CLAUDE.md — `repo/` (TD-Proxmox framework + reference stack)

You're inside the TD-Proxmox framework repo — the foundation stack and
addon library that other Sobol Data stacks inherit from. Public on
GitHub (`github.com/artofax/td-proxmox`) + mirrored to Gitea.

For project-wide context, the parent `../CLAUDE.md` is loaded automatically.
This file adds tactical context specific to working in this repo.

## What lives here

```
repo/
├── automation/                  Two phase-1 + phase-2 scripts
│   ├── bootstrap-pve.sh         Creates CTs, joins to tailnet
│   └── configure-apps.sh        First-run-setup for installed apps
│
├── addons/                      Everything else (apps + workflows + connectors)
│   ├── setup-*.sh               One addon = one CT or one feature
│   ├── README-addons.md         Catalog
│   ├── n8n/workflows/           8 workflow JSONs + README catalog
│   ├── connectors/slack/        Sobol Mirror Slack connector
│   ├── setup-mattermost-helpers/  Shared MM helpers
│   └── pi-mattermost-bridge/    Local patches + service for pi-bot
│
├── manifest.yaml                The td-proxmox stack manifest (v1.0.0, tier: foundation)
├── TROUBLESHOOTING_LOG.md       READ THIS when something looks weird
├── README.md
└── bootstrap-fresh-pve.sh       The one-liner public entry point
```

## Most common operations

### Patching an existing addon

1. Edit the script
2. `bash -n addons/setup-<name>.sh` to check syntax
3. SSH to td and dry-run if possible: `ssh root@td "cd /root/td-proxmox && ./addons/setup-<name>.sh --dry-run"`
4. If it fixed a real-world bug, add an entry to `TROUBLESHOOTING_LOG.md`
5. Commit with verbose message (what + why + impact)

### Adding a new addon

Follow the §10 addon shape in `../proxmox-stack-foundations/foundations.md`:
`set -Eeuo pipefail`, `--dry-run`, `--uninstall`, `log()` helper, markered
config blocks. Then ship its workflow (the §10.1 contract — see
`../proxmox-stack-foundations/conventions.md` §7.1).

### Adding a new workflow

`addons/n8n/workflows/<name>.json` with `meta.description` + 
`meta.stack_dependencies` + `meta.addon_dependencies`. Channel slugs not
UUIDs (`setup-n8n.sh` patches at import time). Update
`addons/n8n/workflows/README.md` catalog.

## Token + credential conventions

This repo's addons read from `/root/td-tokens.txt` (or `--tokens` flag).
Never put secrets on CLI flags — `bootstrap-pve.sh` reads `TS_AUTHKEY` +
`CT_PASSWORD` from the tokens file by default. The token file template
lives at `automation/configure-apps.sh` write_summary().

## When something's weird

`TROUBLESHOOTING_LOG.md` documents almost everything we've hit:
- enterprise.proxmox.com 401s in fresh installs
- Gitea `must_change_password` trap
- SASL no-mechs in Postfix without `libsasl2-modules`
- community-scripts helpers failing without TTY
- ... and ~30 more entries

Skim the headings first — many issues have a documented fix.

## Anti-patterns specific to this repo

- **Hardcoded CTIDs** — use `find_ct_by_hostname` (community-scripts may
  assign different CTIDs on re-install)
- **Editing app configs without markered blocks** — re-runs duplicate
- **Skipping the workflow contract** — every addon ships ≥1 workflow,
  no exceptions
- **`pct exec` with shell-special chars in args** — they re-evaluate
  inside the CT shell; use `pct push` of a wrapper script instead

## Tests

There's no formal test suite. Verification path:

1. `bash -n addons/setup-<name>.sh` — syntax
2. SSH to td, `--dry-run`, eyeball the output
3. SSH to td, real run, watch for surprises
4. If the change is in a workflow JSON, validate via Python:
   `python3 -m json.tool addons/n8n/workflows/<name>.json > /dev/null`

# Tools

One-off utility scripts that use the running homelab stack to do work. Different from [`addons/`](../addons/) which install services — `tools/` scripts use the installed services to operate on data you point them at.

If you haven't built the stack yet, start with [`automation/`](../automation/).

---

## Available tools

| Script | What it does | Runs on | Time |
|---|---|---|---|
| [`push-to-gitea.sh`](push-to-gitea.sh) | Bulk-import every subfolder of a directory as its own Gitea repo (git init / commit / create / push) | `ollama-pi-agent` (any CT with `git`+`curl` and `/root/.netrc`) | ~3 sec per project |

---

## `push-to-gitea.sh`

Walks the subfolders of the current (or specified) directory and, for each one, creates a Gitea repo and pushes the folder's contents to it. Useful for getting a stack of community projects into your homelab Gitea in one shot.

**Typical flow:**

1. On your laptop, make a folder (e.g. `~/td-repos/`) and drop community projects into subfolders inside it — one project per subfolder. The folder structure looks like:

   ```
   td-repos/
   ├── push-to-gitea.sh
   ├── project-foo/
   │   ├── README.md
   │   └── src/...
   ├── project-bar/
   │   └── ...
   └── another-thing/
       └── ...
   ```

2. Drop the script (`push-to-gitea.sh`) into the same folder so it sits next to the projects.

3. Open `http://ollama-pi-agent:8080` (filebrowser), drag the entire `td-repos/` folder into the upload zone. It lands at `/root/uploads/td-repos/` on `ollama-pi-agent`.

4. Open `http://ollama-pi-agent:9092` (the plain shell UI from `setup-pi-web-uis.sh`) or `pct enter 200` from PVE. Then:

   ```bash
   cd /root/uploads/td-repos
   chmod +x push-to-gitea.sh
   ./push-to-gitea.sh
   ```

5. The script:
   - Reads `/root/.netrc` for the Gitea owner + access token (which `configure-apps.sh` already wrote during the base build)
   - Iterates over each subfolder, skipping common non-project names (`node_modules`, `venv`, `.git`, etc.)
   - For each subfolder: `git init -b main` if needed → `git add -A && git commit` → POST `/api/v1/user/repos` → `git remote add gitea …` → `git push -u gitea main`
   - Prints a summary at the end (processed / failed / skipped)

After it finishes, every project is browsable at `http://gitea/<owner>/<project-name>`.

**Flags for unusual cases:**

| Flag | Default | What it does |
|---|---|---|
| `--gitea-url URL` | `http://gitea:3000` | Override the Gitea base URL |
| `--owner NAME` | (`.netrc` lookup, then prompt) | Skip the lookup, pass the owner directly |
| `--token TOKEN` | (`.netrc` lookup, then prompt) | Skip the lookup, pass the token directly |
| `--visibility V` | `public` | `public` or `private` for newly-created repos |
| `--branch NAME` | `main` | Default branch when initializing a non-git folder |
| `--commit-msg MSG` | `Initial import` | Commit message for the initial commit |
| `--skip-existing` | — | Skip projects whose Gitea repo already exists, rather than pushing to them |
| `--dry-run` | — | Print every command without running it |

**Repo-name handling.** Folder names are normalized for Gitea: spaces become hyphens, characters outside `[A-Za-z0-9._-]` become hyphens, trailing hyphens trimmed. So `My Cool Project (v2)` becomes `My-Cool-Project-v2-`.

**Folders skipped by name** (treated as build artifacts / cruft):

`node_modules`, `venv`, `__pycache__`, `target`, `build`, `dist`, and anything starting with `.`.

**Idempotency.** Re-running is safe:

- If a folder is already a git repo, the script keeps the existing history.
- If a Gitea repo already exists at that name, the script logs "already exists — will push to it" and proceeds (push fails cleanly if the remote has commits you don't have locally — fix with `git pull --rebase gitea main` before re-running, or use `--skip-existing`).
- The `gitea` remote is set or overwritten each run, so the URL stays current.

**If something goes wrong.** The script tries to be loud about failures. Per-project failures don't abort the whole run; the summary at the end lists which projects succeeded, failed, or were skipped. To debug a single project, `cd` into its folder and re-run the script with just that path:

```bash
cd /root/uploads/td-repos/specific-project
git push -u gitea main   # the script's last step — usually where things go wrong
```

---

## Adding your own tool

If you want a one-shot homelab utility (rotate API tokens, archive old containers, refresh a model cache), drop a `do-thing.sh` here and add a row to the table at the top of this file. The patterns from `push-to-gitea.sh` are worth borrowing:

- Read credentials from `/root/.netrc` first, then env / flag / prompt
- Validate prereqs (`command -v git`, `command -v curl`) up front
- Iterate with a small per-item function, accumulate success/fail in arrays, print a summary at the end
- `--dry-run` that prints commands instead of running them
- Idempotent: detect prior runs and update rather than duplicate

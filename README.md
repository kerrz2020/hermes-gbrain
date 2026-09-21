# hermes-gbrain

Community (non-official) Hermes plugin that wires **GBrain** into Hermes as a memory
layer. It provides a unified package modeled on the pattern of one-link install,
per-profile setup, easy updates, and a small desktop starter UI.

**GBrain** itself is developed and maintained by [garrytan](https://github.com/garrytan)
(`garrytan/gbrain`, MIT). This plugin is an independent community add-on: it is **not**
affiliated with, endorsed by, or maintained by the upstream GBrain project.

> Upstream: `garrytan/gbrain` — see the [Credits](#credits) section below.

GBrain connects to Hermes over **MCP** (`gbrain serve`). This plugin adds:

- a `/gbrain` slash command (quick status) on the CLI and gateway
- a desktop UI starter (`desktop/plugin.js`)
- `scripts/setup.sh` (fresh default / migrate, per-profile, source options)
- `scripts/update.sh` (always pull the latest gbrain via `self-upgrade`)
- `docs/AGENT-GUIDE.md` — the agent-facing guide (primary source, cloned with the repo)

> **Important:** installing the plugin alone is not enough — the `mcp_servers.gbrain`
> entry in the profile config is also required. `setup.sh` handles both.

## Install (fresh VPS / migration)

For **agents**: follow `docs/AGENT-GUIDE.md` (read it once the plugin is cloned).
Manual (default profile, shared source):

```bash
# 1. install the plugin from git (--force: security scanner flags the bun-installer
#    subprocess scripts as trusted)
hermes plugins install kerrz2020/hermes-gbrain --enable --force
# 2. setup — runs the full path: bun → gbrain → Postgres+pgvector+grant → init keyless →
#    brain dir → source → writer claim → ACTIVATE → MCP wrapper → 3 crons → plugin → verify
bash ~/.hermes/plugins/gbrain-plugin/scripts/setup.sh --dry-run   # see the plan first
bash ~/.hermes/plugins/gbrain-plugin/scripts/setup.sh
# 3. restart the gateway from the user's shell
```

> **Default mode = KEYLESS on POSTGRES** (`gbrain init --url "postgresql://gbrain:***@127.0.0.1:5432/gbrain" --no-embedding --non-interactive`):
> no API key, no LLM, no local embeddings — just keyword FTS (tsvector) + memory.
> Suited to fully-offline use. `setup.sh` provisions Postgres itself
> (role/db/extension/grant/BYPASSRLS/v35 objects). Semantic upgrade later without
> rework: `gbrain init --force --embedding-model voyage:voyage-4`.

## Validation

`bash scripts/verify-install-fresh.sh` runs a drill in an isolated HOME sandbox with a
throwaway role/database: full provisioning path, 20 positive-state checks (including the
keyless posture and the keyless timeline path), then cleanup. Your real brain is never
touched. Expected values for every check are in `docs/VALIDATION.md`.

## Per-profile & source

```bash
bash scripts/setup.sh --profile myprofile                 # a specific profile
bash scripts/setup.sh --source dedicated:work --profile friday  # isolated source (work brain)
bash scripts/setup.sh --migrate ~/brain                   # OPTIONAL: reuse an existing brain repo
bash scripts/setup.sh --engine pglite --profile myprofile # single-writer option (default: postgres)
```

- **shared** (default): one federated source; writers split per `agents/<name>/`.
- **dedicated:<name>**: isolated source (`federated=false`), env `GBRAIN_SOURCE=<name>` on
  the MCP profile → reads/writes stay inside that source. Good for a separate domain brain.
- Default migration is fresh-empty; `--migrate <dir>` syncs an existing brain repo.

## Update (always latest)

```bash
bash scripts/update.sh    # gbrain self-upgrade + sync + hermes plugins update gbrain-plugin
```
Silent when already up to date → safe for unattended cron.

## Structure

```
hermes-gbrain/
├── plugin.yaml          # manifest (v1-compat) + /gbrain command
├── __init__.py          # /gbrain status (fail-open)
├── desktop/plugin.js    # desktop UI starter (pane + chip)
├── docs/AGENT-GUIDE.md  # agent guide (primary source)
├── docs/VALIDATION.md   # what the fresh-install drill checks
├── tools/fm-check.py    # brain-frontmatter validator
├── scripts/setup.sh     # fresh/migrate/per-profile/source + PG provision + claim/activate + crons
├── scripts/update.sh    # self-upgrade + sync (--no-pull) + plugin update
└── scripts/maintenance/ # brain-sync.sh · gbrain-maintain.sh · gbrain-weekly-backup.sh (cron set)
```

## Credits

- **GBrain** — developed and maintained by [garrytan](https://github.com/garrytan);
  `garrytan/gbrain`, MIT licensed. Install it from GitHub, **never from npm** (npm has an
  unrelated package that shadows it): `bun install -g github:garrytan/gbrain`.
- **This plugin** — a non-official community helper, MIT licensed.
# AGENT GUIDE — GBrain on Hermes (read by the agent)

> **Read this file AFTER the plugin/clone is in place** (`~/.hermes/plugins/gbrain-plugin/`
> or a repo clone). GBrain connects to Hermes via **MCP** (`gbrain serve`), **per-profile**
> (each profile has its own HERMES_HOME). Installing the plugin alone is not enough — the
> `mcp_servers.gbrain` entry in the profile config is also required. `scripts/setup.sh`
> handles both.
>
> **This guide was verified end-to-end on a fresh server (Ubuntu 26.04, Postgres 18 +
> pgvector, gbrain 0.51, keyless).** Every command below was actually run, not recalled.

Upstream: `garrytan/gbrain` (MIT). This wrapper: `kerrz2020/hermes-gbrain` (community,
non-official).

## Main rules

1. **NEVER install gbrain from npm** — `npm install -g gbrain` / `bun add -g gbrain` is a
   different, shadowing package. Use `bun install -g github:garrytan/gbrain` or (more
   deterministic, the fallback when the first fails) `git clone` + `bun install && bun link`.
2. **Installing the plugin alone is not enough** — the MCP entry must exist in the profile
   config.
3. **The gateway must not be restarted from inside the agent** (guard blocks it). Run all
   agent steps, then ask the user to restart from their shell, wait for confirmation, and
   verify. The plugin's scripts are guard-safe (no restart commands).
4. Per-profile: install the plugin and MCP per profile; one gbrain DB may be shared across
   sources (a separate `source` is not a separate brain) — unless the domain differs → use a
   `dedicated` source.
5. **A new botmaker-scaffolded Bot: the Bot Mode title MUST live in the bot's `profile.yaml`,
   not `config.yaml`.** The `message_agent` gate reads `ui_meta.hermes-bots` from
   `profile.yaml` only — `hermes -p NAME config set ui_meta.hermes-bots.title …` writes
   `config.yaml` and the gate stays false → the bot silently has no bot-to-bot DM.

## Default mode: KEYLESS on POSTGRES

Not PGLite (that is quickstart/dev only). Production fleet configuration:

```bash
gbrain init --url "postgresql://gbrain:***@127.0.0.1:5432/gbrain" --no-embedding --non-interactive
# → embedding_disabled: true, engine: postgres, schema up to current
```

Zero credentials (no API key, no LLM, no local embed). What **works**: `put_page`/`gbrain
put`, `capture`, `search` (keyword FTS tsvector), `remember`/`recall` (degraded dedup), tags,
wikilinks, timeline, multi-source, graph traversal, `sync --no-pull`. What **doesn't**:
semantic/cosine search, query expansion, automatic entity/fact extraction. Semantic upgrade
any time without rework — the live provider today is **Voyage** → `gbrain init --force
--embedding-model voyage:voyage-4`.

> **KEYED posture (semantic upgrade) — don't mistake it for FTS-only.** Once the machine is
> upgraded to an embedding model (a voyage key), everything "off" above turns ON: semantic
> search, query expansion, fact extraction. `embedding_state: queued` on a `put_page` result
> is a background embed job in the queue, NOT a disabled signal.
> **Never infer the posture from this document** — check live first:
> `gbrain status --json` (see `embedding_coverage_pct`, `chunks_unembedded`,
> `backfill_queued`) and `~/.gbrain/config.json` (`embedding_model`).

## Run setup.sh (fast path, guard-safe)

```bash
bash ~/.hermes/plugins/gbrain-plugin/scripts/setup.sh --dry-run   # read the plan first
bash ~/.hermes/plugins/gbrain-plugin/scripts/setup.sh             # execute
```

What it does (10 steps, idempotent — safe to re-run):

1. install bun if missing → 2. install gbrain (GitHub, not npm) → 3. **provision local
   Postgres**: apt `postgresql` + `postgresql-<major>-pgvector`, role/db, `CREATE EXTENSION
   vector`, 2 GRANTs, `ALTER ROLE … BYPASSRLS`, pre-create v35 objects + `ALTER FUNCTION
   OWNER` → 4. `gbrain init` keyless → 5. MECE brain dir + git → 6. `sources add default
   --federated` → 7. **writer claim + activate** → 8. `fm-check` + **MCP & CLI wrappers**
   (`~/.hermes/bin/gbrain-mcp`, `~/.local/bin/gbrain`) + `hermes mcp add gbrain` → 9. **3
   maintenance crons** (registered directly) → 10. install plugin + verify.

Key flags: `--dry-run`, `--profile <name>`, `--migrate <dir>`, `--source dedicated:<name>`,
`--no-pg-provision`, `--no-claim`, `--no-activate`, `--no-crons`, `--no-plugin`, `--engine
pglite`, `--db-url <DSN>`, `--pg-major <n>`, `--pg-password-file <path>`.

If `sudo` is unavailable, setup.sh stops and **prints the manual commands** the user must run
(the Postgres steps), then can be re-run with `--no-pg-provision`.

## Step-by-step manual (if the plugin fails / the agent wants full control)

```bash
# 1. Runtime + binary
curl -fsSL https://bun.sh/install | bash
git clone https://github.com/garrytan/gbrain.git ~/src/gbrain
( cd ~/src/gbrain && bun install && bun link )

# 2. Postgres 18 + pgvector + grant (EVERY line required)
sudo apt-get install -y postgresql postgresql-18-pgvector     # older releases: postgresql-16-pgvector
sudo -u postgres psql -c "CREATE USER gbrain WITH PASSWORD '<pw>';"
sudo -u postgres psql -c "CREATE DATABASE gbrain OWNER gbrain;"
sudo -u postgres psql -d gbrain -c "CREATE EXTENSION IF NOT EXISTS vector;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE gbrain TO gbrain;"
sudo -u postgres psql -d gbrain -c "GRANT ALL ON SCHEMA public TO gbrain;"
sudo -u postgres psql -c "ALTER ROLE gbrain BYPASSRLS;"      # v24 + v35 backfill
#   v35 needs superuser (CREATE EVENT TRIGGER). Pre-create function + trigger
#   (the migration is create-if-absent), then hand the function to role gbrain (v120):
sudo -u postgres psql -d gbrain -c "ALTER FUNCTION public.auto_enable_rls() OWNER TO gbrain;"

# 3. Init keyless
gbrain init --url "postgresql://gbrain:***@127.0.0.1:5432/gbrain" --no-embedding --non-interactive

# 4. MCP — MUST use the wrapper (the gbrain binary is a Bun script; the Hermes process PATH
#    usually lacks ~/.bun/bin → the MCP server dies without a clear message)
mkdir -p ~/.hermes/bin && cat > ~/.hermes/bin/gbrain-mcp <<'WRAP'
#!/bin/sh
export PATH="$HOME/.bun/bin:$PATH"
exec "$HOME/.bun/bin/gbrain" "$@"
WRAP
chmod +x ~/.hermes/bin/gbrain-mcp
printf 'Y\n' | hermes mcp add gbrain --env GBRAIN_HOME=$HOME --connect-timeout 60 \
  --command $HOME/.hermes/bin/gbrain-mcp --args serve
hermes mcp test gbrain        # add exit 0 does NOT mean it's OK

# 4b. CLI — ALSO required. Agent/cron/systemd shells don't have ~/.bun/bin on PATH
#     (~/.bashrc only exports it in interactive shells) → `gbrain search` =
#     "command not found" even with a healthy brain. Put a PATH-independent wrapper in
#     ~/.local/bin. Do NOT symlink cli.ts: its shebang is `#!/usr/bin/env bun` → "env:
#     'bun': No such file or directory".
mkdir -p ~/.local/bin && cat > ~/.local/bin/gbrain <<'WRAPCLI'
#!/bin/sh
export PATH="$HOME/.bun/bin:$PATH"
exec "$HOME/.bun/bin/gbrain" "$@"
WRAPCLI
chmod +x ~/.local/bin/gbrain
env -i HOME=$HOME PATH=$HOME/.local/bin:/usr/bin:/bin /bin/sh -c 'command -v gbrain && gbrain --version'

# 5. Brain + source + writer ownership
mkdir -p ~/brain/{people,companies,projects,systems,concepts,ideas,meetings,inbox,archive,agents,fleet/bots,tasks,handoffs}
cd ~/brain && git init && git add -A && git commit -m bootstrap
gbrain sources add default --path ~/brain --federated
gbrain sources writer claim default --path ~/brain     # the "BigInt" print bug is cosmetic — claim still works
gbrain sources writer activate --confirm-quiesced      # REQUIRED, this is the closer

# 6. Validator + crons
cp ~/.hermes/plugins/gbrain-plugin/tools/fm-check.py ~/.hermes/scripts/
cp ~/.hermes/plugins/gbrain-plugin/scripts/maintenance/*.sh ~/.hermes/scripts/ && chmod +x ~/.hermes/scripts/*.sh
hermes cron create --name brain-sync           --script brain-sync.sh           --no-agent "0 */3 * * *"
hermes cron create --name gbrain-maintain      --script gbrain-maintain.sh      --no-agent "every 2h"
hermes cron create --name gbrain-weekly-backup --script gbrain-weekly-backup.sh --no-agent "0 0 * * 0"
```
## Write protocol after writer claim + activate (do not violate)

| Action | How | Don't |
|---|---|---|
| Write/change a page | `put_page` (MCP) / `gbrain put <slug>` (CLI). Read first with `get_page`, pass `expected_revision` on replace (CAS) | `write_file` straight into `~/brain/` → `source_changed` on the next `put` |
| Sync git → DB | `gbrain sync --source <id> --no-pull`, or `gbrain-maintain.sh` | `gbrain import` (silent no-op, 0 pages in a claimed root), `sync` without `--no-pull` |
| Evict DB → disk | not needed — `put_page` is write-through | `gbrain export` + `cp` into the brain dir |
| Fix data directly | via `put`/MCP | direct SQL into `pages`/`facts`/`tags`/`timeline_entries`/`sources` → rejected by the `writer_coordinator_required` guard (that's the protection) |
| Slug | lowercase path (`readme`, `fleet/agent-registry`) | `README.md` (creates a duplicate page) |

Safe sequence when a handwritten file occupies the canonical path: **move the file out of
the brain → `gbrain put` → delete the handwritten copy**. If `put` says `source_changed`
("An unindexed file already occupies the canonical page path"), that's the cause.

### Required timeline block on every page (feeds the `timeline` brain-score component)

```markdown
<!-- timeline -->

## Timeline

- **2026-09-19** | a real event, one line
```

- **Only that exact form is read** by gbrain's extractor (regex, **no key/LLM**). `- 2026-09-19:
  text` without the bold + pipe **is not read** — a page can have a Timeline section while its
  timeline density stays at 0.
- Entries are written **inline at `put_page`** (coordinator path). No worker, no autopilot, no
  key needed.
- The `timeline:` frontmatter field is **not** parsed; `gbrain timeline-add` only writes the DB
  (lost on DB rebuild) → use body bullets so they ride along in git.

## Verify — acceptance criteria (ALL of these before reporting "done")

```bash
gbrain --version                                   # a version number
gbrain engine status --probe                       # Engine: postgres, Probe: ok
env -i HOME=$HOME PATH=$HOME/.local/bin:/usr/bin:/bin /bin/sh -c 'command -v gbrain'   # CLI wrapper must exist — PATH without ~/.bun/bin
grep -i embedding_disabled ~/.gbrain/config.json   # true
gbrain sources list                                # default federated + last sync
hermes mcp test gbrain                             # ✓ Connected + Tools discovered
python3 ~/.hermes/scripts/fm-check.py ~/brain      # 0 with issues
gbrain doctor                                      # status "warnings" — keyless ceiling
hermes cron list                                   # 3 jobs: brain-sync / gbrain-maintain / gbrain-weekly-backup
# write-proof round-trip:
gbrain put inbox/_smoke <<< $'---\ntype: note\ntitle: "smoke"\ndate: \'2026-01-01\'\ntags: [smoke]\nai-first: true\n---\n\nsmoke'
gbrain get inbox/_smoke && gbrain delete inbox/_smoke
```

On a keyless brain `doctor` stops at **`warnings`**, not `fail`: `embed 0/35` holds `brain_score`
at ~50, plus legacy `embedding_model` warnings. That is normal — don't chase it with commands
the guard will reject. The only `fail` that can appear is `Source '<id>' has never been synced`
**before** activate.

## Routine update

```bash
bash ~/.hermes/plugins/gbrain-plugin/scripts/update.sh   # self-upgrade + sync + plugin update
```
On a managed brain `update.sh` uses `sync --no-pull` (not bare `sync`). An agent asked to
"update gbrain": `gbrain self-upgrade`, `hermes plugins update gbrain-plugin`, then ask the
user to restart.

## Source: shared vs dedicated

- **shared** (default): one federated source; all agents read the same, writers split per
  prefix `agents/<name>/`. No extra env needed.
- **dedicated:<name>**: isolated source (`federated=false`) + env `GBRAIN_SOURCE=<name>` on
  the MCP profile → reads/writes stay inside that source. Good for a separate work/domain
  brain (`~/brain-<name>`).

## Cron maintenance (why this set)

| Job | Runs | Does | Why |
|---|---|---|---|
| `brain-sync` (3h) | commit + push the markdown `~/brain` | git = offsite copy |
| `gbrain-maintain` (2h) | **commit write-through first**, then `sync --source default --no-pull`, a read-only `extract --stale --dry-run --json` probe, then a keyless dream phase `lint + backlinks + orphans` | page freshness + graph observability; **no key**, no daemon |
| `gbrain-weekly-backup` (Sun) | `pg_dump -Fc` → `~/.gbrain/backups/` (rotate 8) + push markdown | `remember` facts live only in the DB — the dump is their recovery path |

Not used: **`gbrain autopilot`** (the `embed` phase fails every 10 min on a keyless brain) and
the PGLite-era `gbrain-export.sh` (DB → disk is already write-through). `hermes cron create`
schedules are **positional arguments** in this Hermes version.

**Why the WRITING `extract --stale` is not used on a managed brain:** the managed guard only
allows graph writes through the coordinator (`put_page`). Once there is a new edge to persist,
`gbrain extract --stale` and `gbrain sweep --once` both exit 1
(`writer_coordinator_required`) — whereas when there is no work they both pass (stamping only).
So that step (a) never does real work and (b) flips from green to false-red exactly when
`sync` suggests `run 'gbrain extract --stale'`. What's used instead: a `--dry-run` (read-only)
probe for the `stale_pages` count, and graph writes stay inline in `put_page`.

Stamp note: `updated_at > links_extracted_at` on **every** page is **normal** on a managed
brain (coordinator content writes happen after the extraction stamp). Measure graph completeness
by comparing `[[wikilink]]` with a living target vs the `links` rows in the DB — not from that
stamp.

## Human gate: what MUST be asked of the user

1. **Search mode** (the 9-cell matrix from `gbrain init`/post-upgrade) — relay as-is; the
   common fleet choice is **keyword-only** (`conservative`, no key).
2. **API key** — OPTIONAL; don't ask at bootstrap.
3. **Ambient memory writeback** — a no-op on Hermes, so *don't* offer it as a solution: it has
   no Hermes target (`no harness detected`), and Hermes only reads `initialize_result.capabilities`,
   not `instructions`. Instead: explicit rules in `~/.hermes/SOUL.md` so the agent calls
   `remember` for salient facts (one claim per call, `entity` when the subject is a
   person/company/project, provenance, `ttl` only for transient facts) + a skip-list (greeting,
   questions, tool output, third-party quotes, transcripts, secrets).

## Fresh install — what the agent MUST verify

`scripts/setup.sh` **fails hard** (`❌ SETUP FAILED` + `exit 1`) if any critical step fails.
Don't report "done" without these three positive checks:

1. `gbrain engine status --probe --json` → `effective_engine` = the requested engine (not `null`).
   **`gbrain doctor --fast` exits 0 even before a brain exists** (status `no_url`) — that proves
   nothing and used to cause `gbrain init` to be skipped on an empty box.
2. `psql <brain url> -tAc "select enabled from persistence_brain;"` → `t` (managed persistence on).
3. `psql <brain url> -tAc "select count(*) from persistence_source_bindings;"` → `1` (ownership
   claimed; if `0`, `put_page` will hit `owner_unavailable`).

`sql_brain` inside the script always reads the URL lazily (config.json exists only after `init`) —
if verifying manually in another script, don't read that URL once at the start.

On an empty box `fm-check` reports `CHECKED 0 files` — that is **normal**: the brain pages
(readme/resolver/registry) are filled by the botmaker bootstrap, not by this plugin.

**Expected validation results** (the check table + what each mismatch means): `docs/VALIDATION.md`.
**Prove the install with a drill:** `bash scripts/verify-install-fresh.sh` — makes a HOME sandbox
+ throwaway role/database, runs full `setup.sh` (full provisioning), checks 20 positive states
(engine, v35 objects, ownership, managed persistence, page write + write-through, **keyless
timeline from body bullets**, git bootstrap, **keyless posture** (embedding width = column width,
`facts.extraction_enabled=false`, queue not wedged), crons, and CLI `gbrain` resolution without
`~/.bun/bin` on PATH) and **deletes everything again**. Your real brain is untouched. If the drill
passes, the fresh install can be trusted.

## Pitfalls

- npm gbrain shadowing → always GitHub (`bun install -g github:...` / clone+link).
- `gbrain sync`/`import` at an already-claimed root: `import` **silently no-ops (0 pages, exit 0)**;
  `sync` needs `--no-pull`. Don't treat it as "synced".
- `gbrain sources writer status` may print `JSON.stringify cannot serialize BigInt` — cosmetic;
  prove it via the `persistence_local_writers` table (lanes `cli` + `stdio`).
- Migration stuck at schema 23/34 = Postgres grant incomplete (see the line count in §step-by-step;
  `BYPASSRLS` + v35 objects + function owner).
- In-agent restart → guard blocks it; must be a user-shell restart.
- `manifest_version: 2` is rejected by the installer on Hermes ≤0.21 — this repo doesn't have it.
- Renaming/re-owning the repo → update every reference (AGENT-GUIDE, README, setup.sh,
  update.sh, plugin.yaml).
- `gbrain self-upgrade` may pop a post-upgrade prompt — let the agent/operator answer it (the
  search-mode matrix is the human gate).
- **`gbrain doctor` is cwd-sensitive**: run from a folder that has a `skills/` dir (e.g. a cloned
  skill repo) and you'll see a `[fail] resolver_health` (`missing_file: RESOLVER.md or AGENTS.md`)
  that **isn't** a brain problem. Run doctor from `$HOME` or the brain dir.
- **Commit before sync** — `gbrain sync` walks git OBJECTS: a page whose `.md` is write-through
  to disk but not yet committed counts as missing from the source and is **soft-deleted**.
  `gbrain-maintain.sh` auto-commits as step 0; if syncing manually, commit first. If hit:
  `gbrain put <slug> --force < file`.
- **`Sync BLOCKED at <sha>: N file(s) failed`** after a history rewrite (`filter-branch`/`gc`):
  the source checkpoint points at pruned objects and `--skip-failed` is rejected in managed mode.
  Fix: `gbrain sync --source default --no-pull --retry-failed`.

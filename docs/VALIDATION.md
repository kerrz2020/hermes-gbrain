# Validation record — fresh install

Reference for what the fresh-install drill actually verifies (not assumptions). Agents on a
new server use it to compare their own install result: if a value differs from the table
below, don't report "done".

## How to reproduce

```bash
# on a freshly-installed server (needs non-interactive sudo -u postgres)
DRILL_LOG_OUT=/tmp/fresh.log bash scripts/verify-install-fresh.sh
# pass = exit 0 + "✅ DRILL PASSED";  fail = exit 1 + the list of mismatched checks
```

The drill makes a HOME sandbox + throwaway role/database, runs `setup.sh` on the **full
provisioning path** (apt → role/db → grant → v35 objects → init → source → claim → activate),
checks 20 positive states (including the keyless posture), then deletes everything. Your real
brain is untouched. Raw drill logs are kept out of this public repo (private operational data).

## Expected results — a fresh keyless install

Environment reference: Ubuntu, PostgreSQL 18 + pgvector, bun, gbrain 0.51.0.0, engine
`postgres`, mode keyless (`--no-embedding`).

| Check | Expected | 
|---|---|
| `gbrain list` (live brain) | rc 0 |
| `effective_engine` | `postgres` |
| `embedding_disabled` (keyless) | `True` |
| v35 objects created by the script | `1\|1` (`auto_enable_rls` function \| `auto_rls_on_create_table` trigger) |
| `sources.config->>'federated'` | `true` |
| `count(*) persistence_source_bindings` | `1` |
| `persistence_brain.enabled` | `t` |
| `gbrain put` (writer protocol) | `"state": "committed"` |
| write-through to disk | file exists |
| bootstrap git commit | present |
| `fleet/bots` | exists |
| crons registered | `3` (brain-sync, gbrain-maintain, gbrain-weekly-backup) |
| final script banner | no `SETUP FAILED` |

Supplementary from the drill output: `schema_version: 2`, MCP `✓ Connected` + tools
discovered, MECE scaffold, and `fm-check` reporting `CHECKED 0 files` (normal: brain pages are
filled by the botmaker bootstrap, not this plugin).

## Why the drill exists (and the bugs it found)

The drill was first run 2026-09-19 and **immediately found a fatal bug**: `setup.sh` used
`gbrain doctor --fast` as a "brain configured?" guard, but that command **exits 0 even when no
brain exists** — so on an empty box `gbrain init` was skipped and the install finished with a
"success" banner despite having no brain at all. Fix: use `engine status --probe --json`
(positive check), verify every critical step, and exit 1 on any failure.

Lesson for agents: **don't trust an installer's exit code; check the state.** Every critical
step (init, source, claim, activate) must be verified, and a failure must stop with a non-zero
status.

## Engineering notes worth keeping

### Keyless posture fixes two "false warnings" (verified)
A keyless install that "succeeds" can still light up false doctor warnings without these two config touches:
- `facts.extraction_enabled=false` — automatic fact extraction needs an LLM, and a keyless brain
  has no worker daemon, so leaving it `true` queues `facts-absorb` jobs forever → `WEDGED QUEUE
  'default'` in doctor.
- `embedding_dimensions` on the **file plane** `~/.gbrain/config.json` = the real width of
  `content_chunks.embedding`. `gbrain init --no-embedding` drops that field, so the gateway
  falls back to a stale default while the schema is sized for a new install → two
  `*_width_consistency` warnings on *every* keyless install. The width is read from the doctor
  message itself, never invented. `gbrain config set` can't do this (DB plane; the gateway only
  reads the file plane) — it's written via gbrain's own config API.

### CLI wrapper (verified)
`gbrain` was not resolvable in non-interactive shells (agent/cron/systemd): the binary lives in
`~/.bun/bin`, but that dir is only exported by an interactive `~/.bashrc`. A PATH-independent
wrapper at `~/.local/bin/gbrain` fixes it, verified with `env -i HOME=… PATH=…` (without
`~/.bun/bin`). A symlink to `cli.ts` does **not** work — its shebang is `#!/usr/bin/env bun`
and fails when `~/.bun/bin` is off PATH. Lesson: "binary exists" ≠ "binary callable"; test
resolution on a minimal non-interactive PATH.

### Write protocol on a claimed brain (enforced by gbrain)
After `writer claim` + `activate`, graph/content writes go **through the coordinator**
(`put_page` / `gbrain put`); the writing `gbrain extract --stale` and `gbrain sweep --once`
are rejected (`writer_coordinator_required`) and must not be used in cron. The read-only
`extract --stale --dry-run --json` probe is used for `stale_pages` observability instead.

### Keyless timeline path
Timeline entries need **no key and no worker** — they come from body bullets of the exact form
`- **YYYY-MM-DD** | event` (regex-extracted at `put_page`). Other forms (e.g. `- YYYY-MM-DD:
text` without bold+pipe) are not read. A fresh keyless install must produce timeline entries
from two dated bullets (drill check).

### "Install succeeded" ≠ "brain without false warnings"
Keyless brains have two structural bug seeds (a producer with no consumer, and a stale
embedding default) that must be closed in the *install path*, not left as noise that hides real
warnings. Warnings intentionally **not** silenced: `provider_sunset`/`ze_embedding_health`
suppression is non-conditional, so silencing them would also mute the honest warning on a keyed
brain. The stale `extract_health` rollup warning is a truthful 7-day ratio and clears on its
own — don't buy the score by deleting it.

## What a mismatch means

| Symptom | Meaning |
|---|---|
| `effective_engine` = `null` / `gbrain init` didn't run | brain never initialized; remember `gbrain doctor --fast` exits 0 even without a brain — don't use it as a guard |
| binding count `0` | ownership not claimed → all `put_page` hit `owner_unavailable` |
| `persistence_brain.enabled` = `f` | managed persistence not active → managed sync + DB guard won't run |
| v35 objects `0\|0` | v35 pre-create didn't run; migration will stall at schema 35 |
| `put` not `committed` | writer protocol not ready (see binding/enabled above) |
| write-through file missing | write path not managed (maybe writing files directly → later `source_changed`) |
| crons `0`/`1`/`2` | `hermes cron create` failed (schedule is a POSITIONAL arg) or maintenance scripts not copied to `~/.hermes/scripts/` |
| `fm-check` error `CHECKED 0 files` + a `.md` exists | `fm-check.py` not copied, not an empty brain |
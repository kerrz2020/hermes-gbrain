#!/usr/bin/env bash
# gbrain-plugin setup — fresh VPS / per-profile / source options.
#
# v1.1.0 (2026-09-19): rewritten from a real fresh-server install.
# Now handles local Postgres PROVISIONING + role grant, MCP wrapper (bun on PATH),
# MECE brain dir, writer claim + ACTIVATE, fm-check, and registration of 3 maintenance
# crons — not just "install gbrain then inject config".
#
# Usage:
#   bash setup.sh --dry-run                          # view the plan, change nothing
#   bash setup.sh                                    # default profile, shared source, postgres engine
#   bash setup.sh --profile myprofile                # another profile
#   bash setup.sh --migrate ~/brain                  # reuse an existing brain repo (not fresh)
#   bash setup.sh --source dedicated:work --profile friday   # isolated source (another brain domain)
#   bash setup.sh --pg-user myuser --pg-db mybrain   # differently-named role/database
#   (if --db-url is given, Postgres provisioning is skipped entirely)
#   bash setup.sh --no-pg-provision                  # Postgres already exists / handled manually
#   bash setup.sh --no-crons --no-plugin             # skip cron registration / plugin install
#   bash setup.sh --engine pglite                    # quickstart/dev (single-writer) — NOT fleet production
#
# GUARD-SAFE: no gateway-restart command here — restart is always done by the user
# from their shell (see docs/AGENT-GUIDE.md).
set -uo pipefail

FAILED=()   # critical steps that failed → exit 1 at the end (never a false-green)

PROFILE="default"
SOURCE_MODE="shared"
DEDICATED_NAME=""
MIGRATE_DIR=""
DO_PLUGIN=1
DO_CRONS=1
DO_PG_PROVISION=1
DO_CLAIM=1
DO_ACTIVATE=1
DRY_RUN=0
ENGINE="postgres"
DB_URL=""
BRAIN_DIR=""
PG_MAJOR="18"
PG_USER="gbrain"
PG_DB="gbrain"
PG_PW_FILE="$HOME/.gbrain/pgpass.secret"

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --source)
      if [[ "$2" == dedicated:* ]]; then SOURCE_MODE="dedicated"; DEDICATED_NAME="${2#dedicated:}"
      else SOURCE_MODE="$2"; fi
      shift 2 ;;
    --migrate) MIGRATE_DIR="$2"; shift 2 ;;
    --brain-dir) BRAIN_DIR="$2"; shift 2 ;;
    --engine) ENGINE="$2"; shift 2 ;;
    --db-url) DB_URL="$2"; shift 2 ;;
    --pg-major) PG_MAJOR="$2"; shift 2 ;;
    --pg-user) PG_USER="$2"; shift 2 ;;
    --pg-db) PG_DB="$2"; shift 2 ;;
    --pg-password-file) PG_PW_FILE="$2"; shift 2 ;;
    --no-pg-provision) DO_PG_PROVISION=0; shift ;;
    --no-claim) DO_CLAIM=0; shift ;;
    --no-activate) DO_ACTIVATE=0; shift ;;
    --no-crons) DO_CRONS=0; shift ;;
    --no-plugin) DO_PLUGIN=0; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '1,22p' "$0"; exit 0 ;;
    *) echo "❌ unknown argument: $1"; exit 1 ;;
  esac
done

BRAIN_DIR="${BRAIN_DIR:-${MIGRATE_DIR:-$HOME/brain}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT_SRC="$SCRIPT_DIR/maintenance"

echo "=========================================================="
echo " gbrain setup | profile=$PROFILE | engine=$ENGINE | source=$SOURCE_MODE${DEDICATED_NAME:+:$DEDICATED_NAME}"
echo " brain_dir=$BRAIN_DIR | migrate=${MIGRATE_DIR:-fresh} | pg_provision=$DO_PG_PROVISION"
echo " claim=$DO_CLAIM activate=$DO_ACTIVATE crons=$DO_CRONS plugin=$DO_PLUGIN dry_run=$DRY_RUN"
echo "=========================================================="

# ── 1. Bun ────────────────────────────────────────────────────────────────
if ! command -v bun >/dev/null 2>&1 && [ ! -x "$HOME/.bun/bin/bun" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] 1/10 install bun (official installer script)"
  else
    echo "==> 1/10 install bun"
    curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || true
  fi
else
  echo "==> 1/10 bun present — $(bun --version 2>/dev/null || echo '?')"
fi
export PATH="$HOME/.bun/bin:$PATH"

# ── 2. gbrain binary (NEVER npm; clone + bun link = deterministic path) ──
if ! command -v gbrain >/dev/null 2>&1 && [ ! -x "$HOME/.bun/bin/gbrain" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] install gbrain from garrytan/gbrain (fallback: clone ~/src/gbrain + bun install && bun link)"
  else
    echo "==> 2/10 install gbrain"
    bun install -g github:garrytan/gbrain >/dev/null 2>&1 || true
    if ! command -v gbrain >/dev/null 2>&1 && [ ! -x "$HOME/.bun/bin/gbrain" ]; then
      mkdir -p "$HOME/src" && cd "$HOME/src" || exit 1
      [ -d "$HOME/src/gbrain/.git" ] || git clone https://github.com/garrytan/gbrain.git "$HOME/src/gbrain"
      ( cd "$HOME/src/gbrain" && git pull --ff-only --quiet 2>/dev/null || true; \
        bun install >/dev/null 2>&1 && bun link >/dev/null 2>&1 )
      cd - >/dev/null || exit 1
    fi
  fi
else
  echo "==> 2/10 gbrain present — $(gbrain --version 2>/dev/null | tail -1)"
fi
if [ "$DRY_RUN" != "1" ] && ! command -v gbrain >/dev/null 2>&1; then
  echo "❌ gbrain not installed. Check the bun/git errors above, then re-run."; exit 1
fi

# ── 3. Local Postgres + role grant (engine=postgres) ──────────────────────
# IMPORTANT: `gbrain doctor --fast` exits 0 EXACTLY when the brain is NOT yet
# configured (status no_url) — so don't use it as a "brain exists" check. Positive check:
gbrain_configured() {
  local out
  out=$(gbrain engine status --probe --json 2>/dev/null) || return 1
  printf '%s' "$out" | grep -qE '"effective_engine":[[:space:]]*"[^"]+"'
}
gbrain_reachable() { gbrain_configured; }   # legacy alias
# Query the brain DB directly via the URL in ~/.gbrain/config.json (no password file needed).
# LAZY: config.json is only created at init (step 4), so don't read it once at the start —
# reading it early yields empty values and claim/activate verification would FALSE-FAIL.
sql_brain() {
  local url
  url="$(python3 -c "import json,os;p=os.path.expanduser('~/.gbrain/config.json');print(json.load(open(p)).get('database_url') or '')" 2>/dev/null)"
  [ -n "$url" ] || return 1
  psql "$url" -tAc "$1" 2>/dev/null | tr -d ' '
}

if [ "$ENGINE" = "postgres" ] && [ "$DRY_RUN" != "1" ] && gbrain_reachable; then
  # Brain already live (its URL comes from ~/.gbrain/config.json) — don't touch Postgres/password again.
  URL=""; REDACTED="(from ~/.gbrain/config.json — brain already configured)"
  echo "==> 3/10 brain already configured — Postgres provisioning skipped"
elif [ "$ENGINE" = "postgres" ]; then
  if [ -n "$DB_URL" ]; then
    URL="$DB_URL"
  elif [ -f "$PG_PW_FILE" ]; then
    URL="postgresql://${PG_USER}:$(tr -d '\n' < "$PG_PW_FILE")@127.0.0.1:5432/${PG_DB}"
  else
    PW="$(openssl rand -hex 20 2>/dev/null || head -c 40 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    if [ "$DRY_RUN" = "1" ]; then
      echo "   [dry-run] generate Postgres role password → $PG_PW_FILE (0600)"
    else
      mkdir -p "$(dirname "$PG_PW_FILE")" && printf '%s' "$PW" > "$PG_PW_FILE" && chmod 600 "$PG_PW_FILE"
    fi
    URL="postgresql://${PG_USER}:***@127.0.0.1:5432/${PG_DB}"
  fi
  REDACTED="$(printf '%s' "$URL" | sed -E 's#://([^:]+):[^@]*@#://\1:***@#')"

  NEED_PG=0
  if [ -n "$DB_URL" ]; then
    NEED_PG=0                       # operator supplied the URL — don't provision anything
    echo "   --db-url given — Postgres provisioning skipped"
  elif [ "$DRY_RUN" = "1" ]; then
    [ "$DO_PG_PROVISION" = "1" ] && NEED_PG=1
  elif ! command -v psql >/dev/null 2>&1; then
    NEED_PG=1
  else
    PGPASSWORD="$(tr -d '\n' < "$PG_PW_FILE" 2>/dev/null || true)" \
      psql -h 127.0.0.1 -U "$PG_USER" -d "$PG_DB" -tAc 'select 1' >/dev/null 2>&1 || NEED_PG=1
  fi

  if [ "$NEED_PG" = "1" ] && [ "$DO_PG_PROVISION" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      echo "   [dry-run] provision Postgres: apt install postgresql postgresql-${PG_MAJOR}-pgvector;"
      echo "             create role/db $PG_USER/$PG_DB; CREATE EXTENSION vector; GRANTs;"
      echo "             ALTER ROLE $PG_USER BYPASSRLS; pre-create v35 objects + ALTER FUNCTION OWNER"
    elif ! sudo -n true 2>/dev/null; then
      echo "❌ sudo required for Postgres provisioning. Run these manually, then re-run with --no-pg-provision:"
      echo "   sudo apt-get install -y postgresql postgresql-${PG_MAJOR}-pgvector"
      echo "   sudo -u postgres psql -c \"CREATE USER $PG_USER WITH PASSWORD '<pw from $PG_PW_FILE>';\""
      echo "   sudo -u postgres psql -c \"CREATE DATABASE $PG_DB OWNER $PG_USER;\""
      echo "   sudo -u postgres psql -d $PG_DB -c 'CREATE EXTENSION IF NOT EXISTS vector;'"
      echo "   sudo -u postgres psql -c \"GRANT ALL PRIVILEGES ON DATABASE $PG_DB TO $PG_USER;\""
      echo "   sudo -u postgres psql -d $PG_DB -c \"GRANT ALL ON SCHEMA public TO $PG_USER;\""
      echo "   sudo -u postgres psql -c \"ALTER ROLE $PG_USER BYPASSRLS;\""
      exit 1
    else
      echo "==> 3/10 provision Postgres (apt + role/db + grant)"
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql "postgresql-${PG_MAJOR}-pgvector" >/dev/null 2>&1 || \
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql >/dev/null 2>&1 || true
      sudo systemctl enable --now postgresql >/dev/null 2>&1 || true
      PW="$(tr -d '\n' < "$PG_PW_FILE")"
      sudo -u postgres psql -q -c "CREATE USER ${PG_USER} WITH PASSWORD '${PW}';" 2>/dev/null || true
      sudo -u postgres psql -q -c "CREATE DATABASE ${PG_DB} OWNER ${PG_USER};" 2>/dev/null || true
      sudo -u postgres psql -q -d "$PG_DB" -c "CREATE EXTENSION IF NOT EXISTS vector;" >/dev/null 2>&1 || true
      sudo -u postgres psql -q -c "GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO ${PG_USER};" >/dev/null 2>&1 || true
      sudo -u postgres psql -q -d "$PG_DB" -c "GRANT ALL ON SCHEMA public TO ${PG_USER};" >/dev/null 2>&1 || true
      sudo -u postgres psql -q -c "ALTER ROLE ${PG_USER} BYPASSRLS;" >/dev/null 2>&1 || true   # migrations v24 + v35
      # v35 needs superuser (CREATE EVENT TRIGGER) → pre-create (the migration is create-if-absent),
      # then hand the function to role gbrain (migration v120 asks for it).
      sudo -u postgres psql -q -d "$PG_DB" >/dev/null 2>&1 <<'SQL' || true
CREATE OR REPLACE FUNCTION public.auto_enable_rls() RETURNS event_trigger AS $body$
DECLARE obj record;
BEGIN
  FOR obj IN SELECT * FROM pg_event_trigger_ddl_commands() WHERE object_type='table' AND schema_name='public'
  LOOP EXECUTE format('ALTER TABLE %s ENABLE ROW LEVEL SECURITY', obj.object_identity); END LOOP;
END;
$body$ LANGUAGE plpgsql;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname='auto_rls_on_create_table') THEN
    CREATE EVENT TRIGGER auto_rls_on_create_table ON ddl_command_end
      WHEN TAG IN ('CREATE TABLE','CREATE TABLE AS','SELECT INTO') EXECUTE FUNCTION auto_enable_rls();
  END IF;
END $$;
SQL
      sudo -u postgres psql -q -d "$PG_DB" -c "ALTER FUNCTION public.auto_enable_rls() OWNER TO ${PG_USER};" >/dev/null 2>&1 || true
    fi
  fi
  echo "   URL: $REDACTED"
else
  URL=""
  echo "   engine=pglite (quickstart/dev) — not a fleet production configuration"
fi
# ── 4. Init brain (keyless) ───────────────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  echo "   [dry-run] gbrain init (engine=$ENGINE) --no-embedding --non-interactive  — skipped only if the brain is ALREADY configured"
elif gbrain_configured; then
  echo "==> 4/10 brain already configured — init skipped"
else
  echo "==> 4/10 gbrain init (keyless, engine=$ENGINE)"
  if [ "$ENGINE" = "pglite" ]; then
    gbrain init --pglite --no-embedding --non-interactive
  else
    gbrain init --url "$URL" --no-embedding --non-interactive
  fi
  if gbrain_configured; then
    echo "   ✓ brain configured"
  else
    echo "   ❌ INIT FAILED — brain still not configured (see error above)."
    FAILED+=("init")
  fi
fi

# ── 4b. Keyless posture: two required configs ─────────────────────────────
# A "successful" keyless install still lights false warnings without both:
# (1) `facts.extraction_enabled=false` — automatic fact extraction needs an LLM and a
#     keyless brain has NO worker daemon (autopilot intentionally not installed), so while
#     the flag is true every `put_page` queues a `facts-absorb` job that hangs forever →
#     doctor: "WEDGED QUEUE 'default': N waiting, 0 active (live-lock)".
# (2) `embedding_dimensions` on the FILE plane = the actual width of `content_chunks.embedding`.
#     `gbrain init --no-embedding` removes that field from config.json, so the gateway falls
#     back to a stale default while the keyless schema is sized for a new install (1024) →
#     `embedding_width_consistency` + `facts_embedding_width_consistency` warn on EVERY keyless
#     install. The width is taken from the doctor message itself, so it's never invented.
#     `gbrain config set embedding_dimensions` can't be used (DB plane; the gateway only reads
#     the file plane) → write it via gbrain's own API.
keyless_posture() {
  local msg dims src cand
  if gbrain config set facts.extraction_enabled false >/dev/null 2>&1; then
    echo "   ✓ facts.extraction_enabled=false (no hanging facts-absorb jobs)"
  else
    echo "   ⚠️ failed to set facts.extraction_enabled=false"
  fi

  msg=$(gbrain doctor --json 2>/dev/null | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    raise SystemExit
for c in d.get('checks',[]):
    if c.get('name')=='embedding_width_consistency':
        print(c.get('message',''))
        break
" 2>/dev/null)
  dims=$(printf '%s' "$msg" | sed -n 's/.*content_chunks\\.embedding is vector(\\([0-9][0-9]*\\)).*/\\1/p' | head -1)
  if [ -z "$dims" ]; then
    echo "   (embedding width already consistent — file plane not changed)"
    return 0
  fi

  src=""
  for cand in "$HOME/src/gbrain" "$HOME/.bun/install/global/node_modules/gbrain" \
              "$(dirname "$(dirname "$(readlink -f "$(command -v gbrain 2>/dev/null)" 2>/dev/null)")")"; do
    if [ -n "$cand" ] && [ -f "$cand/src/core/config.ts" ]; then src="$cand"; break; fi
  done
  if [ -z "$src" ]; then
    echo "   ⚠️ gbrain source not found — embedding_dimensions=$dims NOT written (width warning will appear)"
    return 0
  fi
  if GBRAIN_SRC="$src" DIMS="$dims" bun -e '
      const src = process.env.GBRAIN_SRC;
      const { loadConfigFileOnly, saveConfig } = await import(src + "/src/core/config.ts");
      const c = loadConfigFileOnly();
      if (!c) process.exit(1);
      c.embedding_dimensions = Number(process.env.DIMS);
      saveConfig(c);
    ' >/dev/null 2>&1; then
    echo "   ✓ embedding_dimensions=$dims (file plane, matches column width)"
  else
    echo "   ⚠️ failed to write embedding_dimensions=$dims to the file plane"
  fi
}

if [ "$DRY_RUN" = "1" ]; then
  echo "   [dry-run] 4b/10 keyless posture: facts.extraction_enabled=false + embedding_dimensions=<column width> (file plane)"
elif grep -q '"embedding_disabled": *true' "$HOME/.gbrain/config.json" 2>/dev/null; then
  echo "==> 4b/10 keyless posture (facts extraction off + embedding width aligned to schema)"
  keyless_posture
else
  echo "==> 4b/10 brain keyed (embedding_disabled absent) — keyless posture skipped"
fi

# ── 5. Brain dir + git + MECE skeleton ───────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  echo "   [dry-run] mkdir -p $BRAIN_DIR/{people,companies,projects,systems,concepts,ideas,meetings,inbox,archive,agents,fleet/bots,daily,decisions,tasks,handoffs} + git init/commit"
else
  mkdir -p "$BRAIN_DIR"/{people,companies,projects,systems,concepts,ideas,meetings,inbox,archive,originals,personal,agents,fleet/bots,daily,decisions,tasks,handoffs} 2>/dev/null
  # The skeleton must survive a clone: git doesn't track empty folders → .gitkeep.
  # `fleet/` = bot/fleet lane, `systems/` (plural) = infra lane — the one-letter difference
  # is INTENTIONAL; scope enforcement is left to the botmaker tooling.
  for d in agents archive companies concepts daily decisions handoffs ideas meetings people tasks originals personal; do
    touch "$BRAIN_DIR/$d/.gitkeep"
  done
  # gbrain ownership markers are machine-local state (contain a worktree token) — never commit them.
  for line in '.DS_Store' 'db-backups/' '*.dump' '.gbrain-owner.json' '.gbrain-managed'; do
    grep -qxF "$line" "$BRAIN_DIR/.gitignore" 2>/dev/null || echo "$line" >> "$BRAIN_DIR/.gitignore"
  done
  if [ ! -d "$BRAIN_DIR/.git" ]; then
    ( cd "$BRAIN_DIR" && git init -q && git add -A && \
      git -c user.name="${GIT_AUTHOR_NAME:-hermes}" -c user.email="${GIT_AUTHOR_EMAIL:-hermes@localhost}" \
          commit -qm "bootstrap: brain repo" ) 2>/dev/null || \
      echo "   ⚠️ git commit failed — check 'git config user.name/user.email'"
  fi
fi

# ── 6. Source registration (+ dedicated) ─────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  echo "   [dry-run] gbrain sources add default --path $BRAIN_DIR --federated"
  if [ "$SOURCE_MODE" = "dedicated" ]; then
    echo "   [dry-run] gbrain sources add ${DEDICATED_NAME:-work} --path \$HOME/brain-${DEDICATED_NAME:-work} --no-federated"
  fi
else
  if gbrain sources list 2>/dev/null | grep -qE '^[[:space:]]+default[[:space:]]'; then
    echo "==> 6/10 source 'default' already registered"
  else
    echo "==> 6/10 sources add default → $BRAIN_DIR (federated)"
    if gbrain sources add default --path "$BRAIN_DIR" --federated; then
      echo "   ✓ source 'default' registered"
    else
      echo "   ❌ sources add FAILED"; FAILED+=("sources-add")
    fi
  fi
  if [ "$SOURCE_MODE" = "dedicated" ]; then
    DED_NAME="${DEDICATED_NAME:-work}"; DED_PATH="$HOME/brain-$DED_NAME"
    mkdir -p "$DED_PATH"
    ( cd "$DED_PATH" && [ -d .git ] || { git init -q && git add -A && git commit -qm bootstrap; } ) 2>/dev/null || true
    gbrain sources add "$DED_NAME" --path "$DED_PATH" --no-federated >/dev/null 2>&1 || true
    echo "   source dedicated '$DED_NAME' → $DED_PATH"
  fi
fi

# ── 7. Writer claim + ACTIVATE (this is what actually turns on the write path + sync) ──
if [ "$DO_CLAIM" = "1" ]; then
  CLAIMED=""
  [ "$DRY_RUN" = "1" ] || CLAIMED="$(sql_brain "select count(*) from persistence_source_bindings where source_id='default';" || true)"
  if [ "$CLAIMED" = "1" ]; then
    echo "==> 7/10 source 'default' already claimed — claim skipped (idempotent)"
  elif [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] gbrain sources writer claim default --path $BRAIN_DIR"
  else
    echo "==> 7/10 writer claim (CLI may print a 'JSON.stringify BigInt' bug — claim still works)"
    gbrain sources writer claim default --path "$BRAIN_DIR" 2>&1 | tail -1 || true
    if [ "$(sql_brain "select count(*) from persistence_source_bindings where source_id='default';" || echo 0)" = "1" ]; then
      echo "   ✓ ownership claimed (binding visible in DB)"
    else
      echo "   ❌ claim NOT visible in DB (put_page will hit owner_unavailable later)"; FAILED+=("claim")
    fi
  fi
fi
if [ "$DO_ACTIVATE" = "1" ] && [ "$ENGINE" = "postgres" ] && [ "$DRY_RUN" != "1" ]; then
  ENABLED="$(sql_brain "select enabled from persistence_brain;" || true)"
  if [ "$ENABLED" = "t" ]; then
    echo "==> 7/10 managed persistence already active"
  else
    echo "==> 7/10 writer ACTIVATE (quiesce 'gbrain serve' first)"
    pkill -TERM -f "gbrain[ ]serve" 2>/dev/null || true; sleep 2
    gbrain sources writer activate --confirm-quiesced --json 2>&1 | tail -6
    if [ "$(sql_brain "select enabled from persistence_brain;" || echo f)" = "t" ]; then
      echo "   ✓ managed persistence active"
    else
      echo "   ❌ activation FAILED — managed sync & DB guard won't run"; FAILED+=("activate")
    fi
  fi
elif [ "$DRY_RUN" = "1" ] && [ "$DO_ACTIVATE" = "1" ]; then
  echo "   [dry-run] gbrain sources writer activate --confirm-quiesced (stop 'gbrain serve' first)"
fi

# ── 8. fm-check + MCP & CLI wrappers ──────────────────────────────────────
if [ "$DRY_RUN" = "1" ]; then
  echo "   [dry-run] cp tools/fm-check.py → ~/.hermes/scripts/ ; write ~/.hermes/bin/gbrain-mcp + ~/.local/bin/gbrain ; hermes mcp add gbrain"
else
  echo "==> 8/10 fm-check + MCP & CLI wrappers"
  mkdir -p "$HOME/.hermes/scripts" "$HOME/.hermes/bin"
  for CAND in "$SCRIPT_DIR/../tools/fm-check.py" "$SCRIPT_DIR/fm-check.py"; do
    if [ -f "$CAND" ]; then cp "$CAND" "$HOME/.hermes/scripts/fm-check.py"; chmod +x "$HOME/.hermes/scripts/fm-check.py"; break; fi
  done
  cat > "$HOME/.hermes/bin/gbrain-mcp" <<'WRAP'
#!/bin/sh
# wrapper: gbrain is a Bun script — ~/.bun/bin isn't always on the harness process PATH
export PATH="$HOME/.bun/bin:$PATH"
exec "$HOME/.bun/bin/gbrain" "$@"
WRAP
  chmod +x "$HOME/.hermes/bin/gbrain-mcp"

  # CLI wrapper — without it `gbrain search` in an agent/cron shell = "command not found":
  # the binary lives in ~/.bun/bin, but that dir is ONLY exported by ~/.bashrc
  # (interactive guard: the `case $- in *i*)` line makes a non-interactive shell `return` first).
  # ~/.local/bin is on the path of both login shells AND the harness → put the wrapper there.
  # Do NOT symlink cli.ts: its shebang is `#!/usr/bin/env bun` and it fails
  # "env: 'bun': No such file or directory" when ~/.bun/bin is off PATH.
  mkdir -p "$HOME/.local/bin"
  cat > "$HOME/.local/bin/gbrain" <<'WRAPCLI'
#!/bin/sh
# gbrain CLI wrapper — same pattern as ~/.hermes/bin/gbrain-mcp
export PATH="$HOME/.bun/bin:$PATH"
exec "$HOME/.bun/bin/gbrain" "$@"
WRAPCLI
  chmod +x "$HOME/.local/bin/gbrain"
  if env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
       /bin/sh -c 'command -v gbrain >/dev/null 2>&1 && gbrain --version >/dev/null 2>&1'; then
    echo "   ✓ CLI wrapper: gbrain resolvable WITHOUT ~/.bun/bin on PATH"
  else
    echo "   ❌ CLI wrapper failed — agent shell will hit 'gbrain: command not found'"; FAILED+=("cli-wrapper")
  fi

  ENV_ARGS=(--env GBRAIN_HOME="$HOME")
  [ "$SOURCE_MODE" = "dedicated" ] && ENV_ARGS+=(--env "GBRAIN_SOURCE=${DEDICATED_NAME:-work}")
  if [ "$PROFILE" = "default" ]; then
    if hermes mcp list 2>/dev/null | grep -q gbrain; then
      echo "   mcp_servers.gbrain already registered"
    else
      printf 'Y\n' | hermes mcp add gbrain "${ENV_ARGS[@]}" --connect-timeout 60 \
        --command "$HOME/.hermes/bin/gbrain-mcp" --args serve | tail -3
    fi
  else
    echo "   ⚠️ profile '$PROFILE': register the MCP entry in that profile (an agent can run it):"
    echo "      hermes -p $PROFILE mcp add gbrain --env GBRAIN_HOME=$HOME --command $HOME/.hermes/bin/gbrain-mcp --args serve"
  fi
fi

# ── 9. Maintenance crons (register now, not left optional) ──────────────
add_job() {  # add_job <name> <script> <schedule>
  if hermes cron list 2>/dev/null | grep -q "Name: *$1$"; then
    echo "   cron '$1' already exists"
  else
    if hermes cron create --name "$1" --script "$2" --no-agent "$3" >/dev/null 2>&1; then
      echo "   ✓ cron '$1' registered ($3)"
    else
      echo "   ⚠️ cron '$1' failed — schedule is a POSITIONAL argument, check 'hermes cron create --help'"
    fi
  fi
}
if [ "$DO_CRONS" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] cp scripts/maintenance/*.sh → ~/.hermes/scripts/ ; 3x hermes cron create (positional schedule)"
  else
    echo "==> 9/10 register maintenance crons"
    if [ -d "$MAINT_SRC" ]; then
      cp "$MAINT_SRC"/brain-sync.sh "$MAINT_SRC"/gbrain-maintain.sh "$MAINT_SRC"/gbrain-weekly-backup.sh "$HOME/.hermes/scripts/" 2>/dev/null || true
      chmod +x "$HOME/.hermes/scripts/"*.sh 2>/dev/null || true
    fi
    add_job brain-sync brain-sync.sh "0 */3 * * *"
    add_job gbrain-maintain gbrain-maintain.sh "every 2h"
    add_job gbrain-weekly-backup gbrain-weekly-backup.sh "0 0 * * 0"
  fi
fi

# ── 10. Plugin ───────────────────────────────────────────────────────────
if [ "$DO_PLUGIN" = "1" ]; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "   [dry-run] hermes plugins install kerrz2020/hermes-gbrain --enable --force"
  elif [ "$PROFILE" = "default" ]; then
    hermes plugins list 2>/dev/null | grep -q gbrain-plugin || \
      hermes plugins install kerrz2020/hermes-gbrain --enable --force >/dev/null 2>&1 || \
      echo "   ⚠️ plugins install failed (check gh auth) — continuing"
  else
    hermes -p "$PROFILE" plugins list 2>/dev/null | grep -q gbrain-plugin || \
      hermes -p "$PROFILE" plugins install kerrz2020/hermes-gbrain --enable --force >/dev/null 2>&1 || true
  fi
fi

# ── VERIFY ───────────────────────────────────────────────────────────────
echo ""
echo "==> VERIFY (report raw to the user)"
if [ "$DRY_RUN" = "1" ]; then
  echo "   [dry-run] gbrain --version | CLI wrapper (~/.local/bin/gbrain) | engine status --probe | sources list | hermes mcp test gbrain | fm-check | gbrain doctor"
else
  echo "   $(gbrain --version 2>/dev/null | tail -1)"
  echo -n "   CLI wrapper: "
  if env -i HOME="$HOME" PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin" \
       /bin/sh -c 'command -v gbrain >/dev/null 2>&1'; then
    echo "$HOME/.local/bin/gbrain (ok — resolvable without ~/.bun/bin on PATH)"
  else
    echo "MISSING — agent/cron shell will hit 'gbrain: command not found'"
  fi
  gbrain engine status --probe 2>&1 | sed -n '1,5p' | sed 's/^/   /'
  grep -iE 'embedding_disabled|embedding_dimensions' "$HOME/.gbrain/config.json" 2>/dev/null | sed 's/^/   /'
  echo "   facts.extraction_enabled=$(gbrain config get facts.extraction_enabled 2>/dev/null | head -1)"
  echo "   $(gbrain jobs stats 2>/dev/null | grep -E 'Queue health' | sed 's/^ *//')"
  gbrain sources list 2>&1 | sed -n '1,4p' | sed 's/^/   /'
  hermes mcp test gbrain 2>&1 | grep -E "Connected|Tools discovered|rror" | sed 's/^/   /'
  FMC="$(python3 "$HOME/.hermes/scripts/fm-check.py" "$BRAIN_DIR" 2>/dev/null | tail -1)"
  echo "   $FMC"
  case "$FMC" in
    "CHECKED 0 files"*) echo "   (normal: brain has no pages yet — the botmaker bootstrap fills readme/resolver/registry)";;
  esac
  echo -n "   doctor: "
  gbrain doctor --json 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
fails=[c for c in d.get('checks',[]) if c.get('status')=='fail']
print(d.get('status'), '| brain_score', d.get('health_score'), '| fails', len(fails))
for c in fails: print('     FAIL:', str(c.get('message','')).splitlines()[0][:150])
" 2>/dev/null || echo "manual check: gbrain doctor"
  echo "   (keyless: status 'warnings' + brain_score ~55 = NORMAL, embed ceiling 0/35)"
fi
echo ""
if [ ${#FAILED[@]} -gt 0 ]; then
  echo "❌ SETUP FAILED — critical steps failed: ${FAILED[*]}"
  echo "   Fix the cause (messages above), then re-run this script (idempotent)."
  exit 1
fi
echo "✅ Setup done. Final step: the user restarts the service from their shell (see docs/AGENT-GUIDE.md)."

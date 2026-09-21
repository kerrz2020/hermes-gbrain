#!/usr/bin/env bash
# verify-install-fresh.sh — prove setup.sh really produces a working brain,
# WITHOUT touching your real one: HOME sandbox + throwaway role/database, then cleaned up.
#
# Use on a freshly-installed server (or after any upgrade):
#   bash scripts/verify-install-fresh.sh
#
# Needs: the user has non-interactive sudo for the postgres superuser (same as the setup.sh
# provisioning). Safe to re-run — role/db are throwaway and dropped at the end.
#
# Why it exists: `gbrain doctor --fast` exits 0 EXACTLY when no brain exists, so an install
# could "succeed" without a brain. This script checks positive state: engine, binding, managed
# persistence, keyless posture (facts extraction off + embedding width), the keyless timeline
# path, crons, and a page write through the writer protocol.
set -uo pipefail

SB="${DRILL_HOME:-/tmp/gbrain-drill-home}"
R="${DRILL_PG_USER:-gbrain_drill}"
D="${DRILL_PG_DB:-gbrain_drill}"
LOG="$SB/drill.log"
SETUP="$(cd "$(dirname "$0")" && pwd)/setup.sh"

[ -f "$SETUP" ] || { echo "setup.sh not found in $(dirname "$SETUP")"; exit 1; }
command -v psql >/dev/null 2>&1 || { echo "psql missing — the drill needs local Postgres"; exit 1; }
sudo -n -u postgres psql -tAc 'select 1' >/dev/null 2>&1 || { echo "sudo -u postgres not available non-interactively — skip this drill"; exit 1; }

echo "=== clean up any previous drill leftover ==="
sudo -u postgres psql -q -c "DROP DATABASE IF EXISTS $D;" >/dev/null 2>&1
sudo -u postgres psql -q -c "DROP ROLE IF EXISTS $R;" >/dev/null 2>&1
rm -rf "$SB"; mkdir -p "$SB/.gbrain"
[ -d "$HOME/.bun" ] && ln -s "$HOME/.bun" "$SB/.bun"   # stub: on a fresh box setup.sh installs bun/gbrain

echo "=== run setup.sh (HOME sandbox, empty role/db, full provisioning) ==="
export PATH="$HOME/.bun/bin:$PATH"
HOME="$SB" bash "$SETUP" --engine postgres --pg-user "$R" --pg-db "$D" \
  --brain-dir "$SB/brain" --no-plugin > "$LOG" 2>&1
RC=$?
echo "  setup.sh rc=$RC  (log: $LOG)"
grep -E '==>|✓|❌|⚠️' "$LOG" | sed 's/^/  /' | head -30

echo
echo "=== positive-state checks ==="
HB="$HOME/.bun/bin/gbrain"
run() { HOME="$SB" "$HB" "$@"; }
Q() { sudo -u postgres psql -d "$D" -tAc "$1" 2>/dev/null | tr -d ' '; }
BAD=0
chk() { # chk <label> <expected> <got>
  if [ "$2" = "$3" ]; then printf '  ✓ %-32s %s\n' "$1" "$3"
  else printf '  ✗ %-32s got=%s expected=%s\n' "$1" "$3" "$2"; BAD=$((BAD+1)); fi
}
chk "brain alive (gbrain list rc=0)" 0 "$(run list >/dev/null 2>&1; echo $?)"
chk "effective_engine" "postgres" "$(run engine status --probe --json 2>/dev/null | grep -oE '"effective_engine": *"[^"]+"' | sed -E 's/.*: *"([^"]+)"/\1/')"
chk "embedding_disabled (keyless)" "True" "$(python3 -c "import json;print(json.load(open('$SB/.gbrain/config.json')).get('embedding_disabled'))" 2>/dev/null)"
chk "v35 objects from script" "1|1" "$(Q "select (select count(*) from pg_proc where proname='auto_enable_rls')||'|'||(select count(*) from pg_event_trigger where evtname='auto_rls_on_create_table');")"
chk "source default federated" "true" "$(Q "select config->>'federated' from sources where id='default';")"
chk "ownership claimed" "1" "$(Q 'select count(*) from persistence_source_bindings;')"
chk "managed persistence" "t" "$(Q 'select enabled from persistence_brain;')"
printf -- '---\ntype: note\ntitle: "drill smoke"\ndate: '"'"'2026-01-01'"'"'\ntags: [drill]\nai-first: true\n---\n\ndrill\n' > "$SB/smoke.md"
chk "write page (writer protocol)" "committed" "$(run put inbox/drill-smoke < "$SB/smoke.md" 2>&1 | grep -oE '"state": *"[a-z_]+"' | sed -E 's/.*"([a-z_]+)"/\1/' | head -1)"
chk "write-through file to disk" "yes" "$([ -f "$SB/brain/inbox/drill-smoke.md" ] && echo yes || echo no)"
# E2E keyless timeline path: dated bullets in the BODY → timeline entries in the DB, with no
# key, no worker, no autopilot. This is the path that feeds the timeline brain-score component.
printf -- '---\ntype: note\ntitle: "drill timeline"\ndate: '"'"'2026-01-01'"'"'\ntags: [drill]\nai-first: true\n---\n\n## Timeline\n\n- **2026-01-02** | entry one (drill)\n- **2026-01-01** | entry two (drill)\n' > "$SB/tl.md"
run put inbox/drill-timeline < "$SB/tl.md" >/dev/null 2>&1
chk "keyless timeline from body bullets" "2" "$(run timeline inbox/drill-timeline 2>/dev/null | grep -cE 'entry (one|two)')"
chk "auto bootstrap git commit" "yes" "$(git -C "$SB/brain" log --oneline 2>/dev/null | head -1 | grep -qc . >/dev/null && echo yes || echo no)"
chk "fleet/bots exists" "yes" "$([ -d "$SB/brain/fleet/bots" ] && echo yes || echo no)"
chk "3 crons registered" "3" "$(HOME="$SB" hermes cron list 2>/dev/null | grep -cE 'Name: +(brain-sync|gbrain-maintain|gbrain-weekly-backup)')"
chk "CLI wrapper ~/.local/bin/gbrain" "ok" "$([ -x "$SB/.local/bin/gbrain" ] && echo ok || echo no)"
chk "gbrain without ~/.bun/bin on PATH" "ok" "$(env -i HOME="$SB" PATH="$SB/.local/bin:/usr/bin:/bin" /bin/sh -c 'command -v gbrain >/dev/null 2>&1 && gbrain --version >/dev/null 2>&1' >/dev/null 2>&1 && echo ok || echo no)"
chk "final banner without failure" "ok" "$(grep -q 'SETUP FAILED' "$LOG" && echo fail || echo ok)"
# Keyless posture (setup.sh step 4b) — without it a "successful" install still lights false
# warnings: facts-absorb jobs hang with no worker, and the gateway falls back to a stale
# default width while the keyless schema is a different size.
chk "embedding_dimensions (file plane)" "1024" "$(python3 -c "import json;print(json.load(open('$SB/.gbrain/config.json')).get('embedding_dimensions'))" 2>/dev/null)"
chk "facts extraction off (keyless)" "false" "$(run config get facts.extraction_enabled 2>/dev/null | head -1 | tr -d ' ')"
DRJSON="$(run doctor --json 2>/dev/null)"
dstat() { printf '%s' "$DRJSON" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(next((c.get('status') for c in d.get('checks',[]) if c.get('name')=='$1'),'?'))
" 2>/dev/null; }
chk "doctor: embedding width consistent" "ok" "$(dstat embedding_width_consistency)"
chk "doctor: queue not wedged" "ok" "$(dstat wedged_queue)"

echo
if [ -n "${DRILL_LOG_OUT:-}" ]; then   # save the setup.sh log for archiving (e.g. into a repo)
  cp "$LOG" "$DRILL_LOG_OUT" && echo "  setup.sh log archived → $DRILL_LOG_OUT"
fi
echo "=== cleanup (role, db, sandbox dropped) ==="
sudo -u postgres psql -q -c "DROP DATABASE IF EXISTS $D;" >/dev/null 2>&1
sudo -u postgres psql -q -c "DROP ROLE IF EXISTS $R;" >/dev/null 2>&1
rm -rf "$SB"

if [ "$RC" -ne 0 ] || [ "$BAD" -ne 0 ]; then
  echo "❌ DRILL FAILED — setup.sh rc=$RC, $BAD checks mismatched. This fresh install can't be trusted."
  exit 1
fi
echo "✅ DRILL PASSED — fresh install yields a working brain (engine, ownership, managed, keyless posture, timeline, write, crons)."
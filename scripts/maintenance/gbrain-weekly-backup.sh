#!/bin/bash
# gbrain-weekly-backup.sh — weekly Postgres-native brain backup.
#
# Adapted from the (now removed) PGLite-era template, which
# stopped autopilot, copied ~/.gbrain/ and did a swap-to-export dance. On Postgres the
# data lives in the server, not in ~/.gbrain/ (that dir holds config only), so:
#   1. pg_dump the `gbrain` database (custom format, restorable with pg_restore)
#   2. rotate dumps in ~/.gbrain/backups/ (keeps last N, never inside the git repo)
#   3. push any pending markdown in ~/brain (offsite copy = the git repo)
# Facts saved via `remember` are DB-only, so the dump is what keeps them recoverable.
# Register (schedule is POSITIONAL): hermes cron create --name gbrain-weekly-backup --script gbrain-weekly-backup.sh --no-agent "0 0 * * 0"
set -uo pipefail

export PATH="$HOME/.bun/bin:$PATH"
BRAIN_DIR="$HOME/brain"
BK_DIR="$HOME/.gbrain/backups"
LOG="$HOME/.gbrain/weekly-backup.log"
KEEP=8
TAG=$(date '+%Y%m%d-%H%M')
TS=$(date '+%Y-%m-%d %H:%M:%S')

mkdir -p "$BK_DIR"

# Read the URL from config.json inside Python; the password never reaches stdout or the log.
PW=$(python3 - <<'PY' 2>/dev/null
import json, os
url = json.load(open(os.path.expanduser('~/.gbrain/config.json')))['database_url']
print(url.split('://', 1)[1].split('@', 1)[0].split(':', 1)[1])
PY
)
if [[ -z "${PW:-}" ]]; then
    echo "⚠️ weekly-backup: cannot read database_url from ~/.gbrain/config.json"
    exit 1
fi

DUMP="$BK_DIR/gbrain-$TAG.dump"
echo "=== weekly backup $TS ===" >> "$LOG"
if ! PGPASSWORD="$PW" pg_dump -h 127.0.0.1 -U gbrain -d gbrain -Fc -f "$DUMP" >>"$LOG" 2>&1; then
    echo "⚠️ weekly-backup: pg_dump FAILED — see $LOG"
    tail -3 "$LOG" | grep -v PGPASSWORD
    exit 1
fi
SIZE=$(du -h "$DUMP" | cut -f1)
TABLES=$(pg_restore -l "$DUMP" 2>/dev/null | grep -c 'TABLE DATA' || true)
echo "[dump] $DUMP size=$SIZE tables=$TABLES" >> "$LOG"

# Offsite: push pending markdown (the dump stays local + rotated).
cd "$BRAIN_DIR" || { echo "⚠️ $BRAIN_DIR does not exist"; exit 1; }
PUSHED=""
if [[ -n $(git status --porcelain) ]]; then
    git add -A
    git commit -qm "weekly-backup: $TAG" >/dev/null 2>&1 || true
fi
if git push origin main --quiet 2>>"$LOG"; then PUSHED="ok"; else PUSHED="FAILED"; fi

ls -1t "$BK_DIR"/gbrain-*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f
COUNT=$(ls -1 "$BK_DIR"/gbrain-*.dump 2>/dev/null | wc -l)

echo "🧠 Weekly backup done"
echo "💾 dump: $DUMP ($SIZE, $TABLES tables)"
echo "📦 dumps kept: $COUNT (rotate keep $KEEP)"
echo "🔗 git push: $PUSHED → $(git remote get-url origin 2>/dev/null)"
#!/bin/bash
# brain-sync.sh — auto-commit + push ~/brain (markdown source of truth) to the git remote.
# Silent when there is nothing to commit (stdout is delivered verbatim by cron --no-agent).
# Register (schedule is POSITIONAL): hermes cron create --name brain-sync --script brain-sync.sh --no-agent "0 */3 * * *"
set -uo pipefail

BRAIN_DIR="${BRAIN_DIR:-$HOME/brain}"
cd "$BRAIN_DIR" || { echo "⚠️ brain-sync: $BRAIN_DIR does not exist"; exit 1; }

CHANGES=$(git status --porcelain)
# Local commits not yet pushed are also unfinished work — don't exit silently.
AHEAD=$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
if [ -z "$CHANGES" ] && [ "${AHEAD:-0}" = "0" ]; then
    exit 0   # clean and in sync — silent
fi

if [ -n "$CHANGES" ]; then
    ADDED=$(printf '%s\n' "$CHANGES" | grep -cE '^(\?\?|[AM])' || true)
    MODIFIED=$(printf '%s\n' "$CHANGES" | grep -cE '^( ?M|R)' || true)
    DELETED=$(printf '%s\n' "$CHANGES" | grep -cE '^( ?D)' || true)
    FILES=$(printf '%s\n' "$CHANGES" | sed 's/^...//' | head -10)
    SUMMARY="+${ADDED} new ~${MODIFIED} changed -${DELETED} deleted"
    git add -A
    git commit -qm "auto-sync [$SUMMARY]: $(date '+%Y-%m-%d %H:%M')" || exit 0
else
    SUMMARY="${AHEAD} local commits not yet pushed"
    FILES=""
fi

if PUSH=$(git push origin main 2>&1); then
    echo "🧠 Brain synced to the git remote"
    echo "📊 $SUMMARY"
    [ -n "$FILES" ] && printf '%s\n' "$FILES" | sed 's/^/  • /'
    echo "🔗 $(git remote get-url origin 2>/dev/null)"
else
    echo "⚠️ brain-sync: local commit OK, PUSH FAILED"
    printf '%s\n' "$PUSH" | tail -3
    exit 1
fi
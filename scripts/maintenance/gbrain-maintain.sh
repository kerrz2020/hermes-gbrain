#!/bin/bash
# gbrain-maintain.sh — managed sync of the gbrain `default` source (git objects -> DB).
#
# Replaces the PGLite-era gbrain-export.sh. Why it changed:
#   * the brain is a writer-claimed worktree with managed persistence ACTIVATED, so
#     DB -> disk happens as write-through on put_page; a separate `gbrain export` +
#     copy into ~/brain/ is obsolete and would create out-of-band edits (source_changed).
#   * `gbrain sync` only works in managed mode, and only with --no-pull
#     (git pull needs an explicit drained maintenance window).
# Registered with a POSITIONAL schedule (--schedule is rejected on Hermes >=0.21.3):
#   hermes cron create --name gbrain-maintain --script gbrain-maintain.sh --no-agent "every 2h"
# Log: ~/.gbrain/maintain.log — silent on stdout unless pages were imported or it failed.
#
# Provider posture: on a brain upgraded to embedding, `gbrain embed --stale` needs the
# embedding key in ~/.gbrain/config.json (file plane). Dream phases that need a CHAT key
# (synthesize/patterns/consolidate/extract_facts/takes/enrich) are intentionally not run
# when no chat key is configured — that is an explicit, known choice.
set -uo pipefail

export PATH="$HOME/.bun/bin:$PATH"
LOG="$HOME/.gbrain/maintain.log"
TS=$(date '+%Y-%m-%d %H:%M:%S')
BRAIN_DIR="${BRAIN_DIR:-$HOME/brain}"

# 0) COMMIT FIRST — REQUIRED. `gbrain sync` walks git OBJECTS: a page whose write-through
#    file is on disk but NOT yet in the git tree counts as "missing from the source" and is
#    SOFT-DELETED. Committing here closes that hole regardless of cron ordering.
if [ -d "$BRAIN_DIR/.git" ] && [ -n "$(git -C "$BRAIN_DIR" status --porcelain)" ]; then
    git -C "$BRAIN_DIR" add -A
    if git -C "$BRAIN_DIR" commit -qm "pre-sync: write-through $(date '+%Y-%m-%d %H:%M')"; then
        echo "[pre-sync] commit write-through $(date '+%Y-%m-%d %H:%M')" >> "$LOG"
    fi
fi

OUT=$(gbrain sync --source default --no-pull 2>&1)
RC=$?
{ echo "=== $TS rc=$RC ==="; printf '%s\n' "$OUT"; } >> "$LOG"

if [[ $RC -ne 0 ]]; then
    echo "⚠️ gbrain-maintain: sync source 'default' FAILED (rc=$RC)"
    printf '%s\n' "$OUT" | grep -vE '^\[sync-watchdog\]' | tail -5
    exit 1
fi

IMPORTED=$(printf '%s' "$OUT" | grep -oE '[0-9]+ file\(s\) imported' | head -1 || true)
if [[ -n "${IMPORTED:-}" && "$IMPORTED" != "0 file(s) imported" ]]; then
    echo "🧠 gbrain sync: $IMPORTED"
fi

if printf '%s' "$OUT" | grep -qiE 'error|refus|failed'; then
    echo "⚠️ gbrain-maintain: sync ran but reports an error"
    printf '%s\n' "$OUT" | grep -iE 'error|refus|failed' | head -3
    exit 1
fi

# Edge extraction (links/timeline) on a MANAGED brain — do NOT use the WRITING `gbrain
# extract --stale`. That call exits 1 with
#   writer_coordinator_required: canonical writer must use the persistence coordinator
# because the managed guard only allows graph writes through the coordinator (put_page /
# trusted write), which already extracts inline while writing. Both `gbrain extract --stale`
# AND `gbrain sweep --once` are rejected the moment there is a new edge to write; when there
# is no work they both pass (stamping only) — which is why they once looked rc=0. So a writing
# step here is a false failure with a misleading message. The right move: a READ-ONLY probe
# for observability, and real edge writes stay inline via put_page.
EX=$(gbrain extract --stale --dry-run --json 2>&1)
RCX=$?
{ echo "--- extract --stale --dry-run rc=$RCX ---"; printf '%s\n' "$EX"; } >> "$LOG"
if [[ $RCX -ne 0 ]]; then
    echo "⚠️ gbrain-maintain: extract probe (--stale --dry-run) FAILED (rc=$RCX)"
    printf '%s\n' "$EX" | tail -3
    exit 1
fi
# This probe is intentionally kept as a safety net (don't remove it): on a brain under
# ~100 pages it is the only stale-signal surface — both the sync nudge and the
# `links_extraction_lag` doctor check are vacuous below EXTRACTION_LAG_MIN_PAGES=100. Only its
# NOISE is dropped: on a managed brain the number equals ALL pages and never changes, so this
# line only speaks when the number CHANGES from the previous run. The rc!=0 alarm above stays
# as-is.
STALE=$(printf '%s' "$EX" | grep -oE '"stale_pages":[0-9]+' | head -1 | cut -d: -f2 || true)
PROBE_STATE="$HOME/.gbrain/extract-probe.state"
PROBE_PREV=$(cat "$PROBE_STATE" 2>/dev/null || true)
if [[ -n "${STALE:-}" && "$STALE" != "0" && "$STALE" != "$PROBE_PREV" ]]; then
    echo "🔗 extract probe: $STALE pages stale (was ${PROBE_PREV:-?}) — normal on a managed brain, graph written inline"
fi
if [[ -n "${STALE:-}" ]]; then printf '%s\n' "$STALE" > "$PROBE_STATE"; fi

# Dream phase that needs NO chat key: lint (frontmatter), backlinks (link materialization), orphans.
# LLM phases (synthesize/patterns/consolidate/takes/extract_facts/extract_atoms/enrich) are
# intentionally not run here — not because keyless, but because they need a chat key. Embedding
# is not a chat-key concern: it runs below with the embedding key. Timeline + links are already
# covered by the `gbrain extract --stale` probe; this block adds frontmatter/backlink/orphan
# hygiene without a daemon. The CycleReport JSON is swallowed into the log (stdout speaks only
# on a change).
#
# MUST pass `--source default` : the `last_full_cycle_at` stamp is only written by `runCycle`
# when there's an explicit sourceId AND the status isn't failed/skipped. Without that flag the
# cycle runs but the stamp never lands → doctor `cycle_freshness` FAILs forever ("last cycled
# 25h ago"). With it: FAIL → OK. Note: the `lint` phase inside the cycle is rejected by the
# managed guard (`writer_coordinator_required: This file belongs to a managed canonical
# worktree`) because it writes the canonical .md directly — that makes the cycle status
# 'partial', but the stamp is still written, so freshness isn't blocked.
DR=$(gbrain dream --source default --phase lint --phase backlinks --phase orphans --json 2>&1)
RCD=$?
{ echo "--- dream (lint+backlinks+orphans) rc=$RCD ---"; printf '%s\n' "$DR"; } >> "$LOG"
if [[ $RCD -ne 0 ]]; then
    if printf '%s' "$DR" | grep -q 'writer_coordinator_required'; then
        echo "ℹ️ dream: writing phases skipped by the managed guard (graph written via put_page) — not a failure"
    else
        echo "⚠️ gbrain-maintain: dream subset FAILED (rc=$RCD)"
        printf '%s\n' "$DR" | tail -3
        exit 1
    fi
fi
DS=$(printf '%s' "$DR" | python3 -c '
import json,sys
try:
    t=json.load(sys.stdin).get("totals",{})
except Exception:
    print(""); raise SystemExit
n=(t.get("lint_fixes",0) or 0)+(t.get("backlinks_added",0) or 0)
print(n if n else "")
' 2>/dev/null || true)
if [[ -n "${DS:-}" && "$DS" != "0" ]]; then
    echo "🧹 dream: $DS fixes (lint + backlinks)"
fi

# 5) EMBEDDING — new/changed pages enter the DB at sync, but their VECTORS are generated here.
#    On a keyed brain: `gbrain embed --stale` uses the embedding model via the file-plane key.
#    Automatic for new pages; idempotent (a second run = "Embedded 0 chunks (0 stale found)").
#    A note that cost real debugging: a Voyage account under Tier 1 (no payment method) gets
#    429 constantly and a full-brain backfill can eat ~10 min of retry-backoff; once Tier 1
#    (payment method attached) the same chunk count finishes in seconds. If the log fills with
#    "[embed-retry] attempt N/5, waiting NNNNNms", that's rate limiting — not a wrong key.
#    On a keyless brain (no provider), the deferred-setup rejection is valid state, not a cron
#    failure.
EMB=$(gbrain embed --stale 2>&1)
RCE=$?
{ echo "--- embed --stale rc=$RCE ---"; printf '%s\n' "$EMB" | grep -vE '^\[embed\.pages\]'; } >> "$LOG"
if [[ $RCE -ne 0 ]]; then
    if printf '%s' "$EMB" | grep -qE "no-embedding|deferred setup|no embedding provider"; then
        echo "ℹ️ embed: skipped — brain without a provider (deferred setup), not a failure"
    else
        echo "⚠️ gbrain-maintain: embed --stale FAILED (rc=$RCE)"
        printf '%s\n' "$EMB" | grep -vE '^\[embed\.pages\]' | tail -3
        exit 1
    fi
fi
NEMB=$(printf '%s' "$EMB" | grep -oE 'Embedded [0-9]+ chunk' | grep -oE '[0-9]+' | head -1 || true)
if [[ -n "${NEMB:-}" && "$NEMB" != "0" ]]; then
    echo "🧠 embed: $NEMB chunks' vectors updated"
fi

exit 0
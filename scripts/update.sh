#!/usr/bin/env bash
# gbrain-plugin update — keep gbrain current + sync the plugin.
#
# Usage: bash update.sh          (from a repo clone)
# GUARD-SAFE: no gateway-restart command — restart is always done by the user.
set -euo pipefail

export PATH="$HOME/.bun/bin:$PATH"

echo "==> 1/3 gbrain self-upgrade (to latest)"
if command -v gbrain >/dev/null 2>&1; then
  gbrain self-upgrade >/dev/null 2>&1 && echo "   ✓ up-to-date / done" || \
    echo "   ⚠️ self-upgrade failed — check connectivity / `gbrain doctor`"
else
  echo "   ❌ gbrain not installed — run scripts/setup.sh first"
fi

echo "==> 2/4 sync brain repo + freshness graph (managed: --no-pull)"
if gbrain sync --source default --no-pull >/dev/null 2>&1; then
  echo "   ✓ sync ok (managed mode, --no-pull)"
  gbrain extract --stale >/dev/null 2>&1 && echo "   ✓ extract --stale ok" || echo "   (extract skipped)"
elif gbrain sync >/dev/null 2>&1; then
  echo "   ✓ sync ok (legacy path)"
else
  echo "   (no local_path / brain not claimed — skip)"
fi

echo "==> 4/4 hermes plugin update"
if command -v hermes >/dev/null 2>&1; then
  if hermes plugins list 2>/dev/null | grep -q gbrain-plugin; then
    hermes plugins update gbrain-plugin 2>/dev/null && echo "   ✓ plugin up-to-date" || \
      echo "   ⚠️ plugin update failed — check auth/source"
  else
    hermes plugins install kerrz2020/hermes-gbrain --enable 2>/dev/null && echo "   ✓ plugin installed" || \
      echo "   ⚠️ plugin install failed — check GitHub auth"
  fi
else
  echo "   (hermes CLI not on PATH — plugin step skipped)"
fi

echo ""
echo "✅ Update done. Final step: the user restarts from their shell (see docs/AGENT-GUIDE.md)."
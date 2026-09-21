"""gbrain-plugin — community Hermes plugin wiring GBrain's MCP into a /gbrain command.

GBrain connects to Hermes via MCP (the `gbrain serve` command in the profile's
mcp_servers config) — this plugin only adds the command and a desktop UI starter.
All setup/update logic lives in scripts/.

Fail-open: if the gbrain binary is missing, the command replies with setup guidance.
"""

import shutil
import subprocess


def register(ctx):
    """Register the /gbrain slash command (CLI + gateway)."""
    ctx.register_command(
        name="gbrain",
        handler=_gbrain_status,
        description="GBrain quick status: version, health, sources",
    )


def _gbrain_status(*_args, **_kwargs):
    if not shutil.which("gbrain"):
        return (
            "⚠️ gbrain binary not found. Install it first: "
            "`bash scripts/setup.sh` from the hermes-gbrain plugin "
            "(kerrz2020/hermes-gbrain)."
        )
    try:
        version = subprocess.run(
            ["gbrain", "--version"], capture_output=True, text=True, timeout=10
        ).stdout.strip().splitlines()
        vline = version[0] if version else "?"
        r = subprocess.run(
            ["gbrain", "doctor", "--fast"], capture_output=True, text=True, timeout=90
        )
        body = (r.stdout or r.stderr).strip()
        return f"🧠 {vline}\n{body[:1200]}"
    except Exception as e:  # noqa: BLE001
        return f"⚠️ gbrain status error: {e}"
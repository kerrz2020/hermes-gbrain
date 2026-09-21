# Contributing

Thanks for considering a contribution to **hermes-gbrain**, a community (non-official) Hermes
plugin for **GBrain** (`garrytan/gbrain`, MIT).

## Development gates

Every change must pass:

- `hermes plugins validate --json .` — the catalog admission gate (install changes, run it on
  the `public` branch).
- `bash -n` on every `*.sh`, and `python3 -m py_compile` on every `.py`.
- The CI workflow (`hermes plugins validate` + shell syntax + python compile).
- The security workflow (Gitleaks + ShellCheck).

## Pull requests

- Keep the plugin a *community helper*: no secrets, no private local paths, no hostnames, no
  personal operational logs.
- User-facing strings in English.
- If you change `setup.sh`, update `scripts/verify-install-fresh.sh` and the expected-values
  table in `docs/VALIDATION.md` in the same PR.
- Bump `version` in `plugin.yaml` and add a `CHANGELOG.md` entry.

## Behavior contract

The write path on a writer-claimed brain must stay coordinator-only (`put_page` / `gbrain
put`). Do not reintroduce direct file writes, writing `gbrain extract --stale`, or `--force` as
a workaround — those are the exact bugs this repo exists to prevent.
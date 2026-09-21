## [1.2.1] — 2026-09-21

Public-release hygiene, matching a polished plugin repo:
- Added a dedicated GitHub **security workflow** (`security.yml`): Gitleaks (secret scan) +
  ShellCheck on `*.sh`, with `.gitleaks.toml`, `SECURITY.md`, `CONTRIBUTING.md`,
  `CODE_OF_CONDUCT.md`, a real `LICENSE` (MIT) file, `.pre-commit-config.yaml`, and CI +
  Security + License badges in the README.
- Version bumped to 1.2.1.

## [1.2.0] — 2026-09-21

Public release. Translated to English, cleaned for open-source (no hostnames, usernames,
paths, or private-operation details committed), repo renamed to `hermes-gbrain`, and a CI
gate added (runs `hermes plugins validate`, the catalog admission check). Explicit
"non-official community plugin" credit added for the upstream `garrytan/gbrain` project.

## [1.1.x] — 2026-09-19..21 (pre-public history)

Internal development history prior to public release; summarized:

- **setup.sh** — rewrite into a guarded, idempotent, 10-step provisioning script: local
  Postgres + pgvector provision; role grant (BYPASSRLS + v35 objects); keyless `gbrain
  init`; MECE brain skeleton + git bootstrap; `sources add` + writer claim + ACTIVATE;
  `fm-check` + MCP & CLI wrappers; 3 maintenance crons registered; final verify. Fails
  hard (`exit 1`) if any critical step fails — no false-green.
- **keyless posture** — `facts.extraction_enabled=false` (no forever-wedged `facts-absorb`
  jobs) and `embedding_dimensions` written to the file plane to match the real column
  width, removing two false doctor warnings on every keyless install.
- **CLI wrapper** — `~/.local/bin/gbrain` PATH-independent wrapper so `gbrain` resolves in
  non-interactive shells (agent/cron/systemd), where `~/.bun/bin` is only exported by the
  interactive `.bashrc`.
- **AGENT-GUIDE / VALIDATION** — write protocol after claim+activate (coordinator-only
  writes), keyless timeline path, and a reproducible fresh-install drill that finds bugs
  before they reach a real box.

For full detail see the git history of the pre-release commits.
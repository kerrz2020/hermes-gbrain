# Security Policy

## Supported versions

This repository is a small Hermes Agent plugin. The `main` branch is the only supported
development line.

## Reporting a vulnerability

Do not open a public issue for suspected credential leaks or security-sensitive behavior.

Preferred reporting path: use GitHub's private
**[Report a vulnerability](https://github.com/kerrz2020/hermes-gbrain/security/advisories/new)**
flow. Do not include vulnerability details in a public issue.

Please include, privately:
- the affected commit or file path;
- a concise description of the issue;
- reproduction steps when applicable;
- whether any credential, private local path, or private document content was exposed.

## Secret handling

This plugin is a *helper* around **GBrain** (`garrytan/gbrain`): it installs a local Postgres
role, writes a role password to `$HOME/.gbrain/pgpass.secret` (0600), and reads brain config
from `~/.gbrain/config.json`. Do not commit `~/.gbrain`, `*.secret`, `.env`, or any generated
private state. The `.gitignore`, Gitleaks config, security workflow, and GitHub-native secret
scanning are intended to reduce accidental leaks, not replace manual review.

## Response expectations

Security fixes should be committed normally after local validation. If a real secret is
committed, rotate the secret first, then remove it from Git history if needed.
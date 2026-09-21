#!/usr/bin/env python3
"""fm-check.py — validate frontmatter of brain markdown files (single-file / dir).

Usage: python3 fm-check.py <file|dir>...
Exit 0 = all clean, 1 = any issue.

Checks (matches unified-agent-protocol + brain-mandatory-write):
- Frontmatter block exists and is closed (--- ... ---)
- YAML parses cleanly (catches unclosed quotes, bad indentation, stray ' )
- No duplicate keys (YAML silently keeps last — the 2026-08-13 corruption bug)
- Required keys present: type, title, date, tags, ai-first

Designed for cron agents to run right after creating/editing a file.
Vault-wide scan: use infra-brain-lint.py instead.
"""
import os
import sys

import yaml

REQUIRED = ["type", "title", "date", "tags", "ai-first"]


class DupCheckLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None, f"duplicate key {key!r}", key_node.start_mark
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


DupCheckLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping
)


def check_file(path):
    with open(path, encoding="utf-8") as f:
        text = f.read()
    if not text.lstrip().startswith("---"):
        return ["no frontmatter (file must start with ---)"]
    parts = text.split("---", 2)
    if len(parts) < 3 or not parts[2].strip():
        return ["frontmatter block not closed (missing closing ---)"]
    fm = parts[1]
    try:
        # SAFE: DupCheckLoader subclasses yaml.SafeLoader (no arbitrary object
        # construction; !!python/object is rejected). The only override adds
        # duplicate-key detection to the mapping constructor.
        data = yaml.load(fm, Loader=DupCheckLoader)
    except yaml.YAMLError as e:
        return [f"YAML error: {e}"]
    if not isinstance(data, dict):
        return ["frontmatter is not a YAML mapping"]
    issues = []
    for key in REQUIRED:
        if key not in data:
            issues.append(f"missing required key: {key}")
    return issues


def main(argv):
    paths = argv[1:] or ["."]
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, names in os.walk(p):
                for n in names:
                    if n.endswith(".md"):
                        files.append(os.path.join(root, n))
        else:
            files.append(p)
    files = sorted(set(files))
    broken = 0
    for f in files:
        if not os.path.exists(f):
            print(f"SKIP (not found): {f}")
            continue
        issues = check_file(f)
        if issues:
            broken += 1
            print(f"ISSUE {f}")
            for i in issues:
                print(f"  - {i}")
        else:
            print(f"OK {f}")
    print(f"CHECKED {len(files)} files, {broken} with issues")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

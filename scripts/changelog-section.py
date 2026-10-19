#!/usr/bin/env python3
"""Extract one CHANGELOG.md section and the GitHub release notes for it.

The release workflow runs this before it packs or publishes. A missing or
empty section exits non-zero and does not write the output files.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

INSTALL_LINE = (
    "Unzip into `Interface/AddOns/` so you get `Interface/AddOns/StockPiler/`."
)
SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
)
UI_MOD_VERSION = re.compile(r'<UiMod\b[^>]*\bversion="([^"]+)"')


def read_mod_version(path: Path) -> str:
    match = UI_MOD_VERSION.search(path.read_text(encoding="utf-8"))
    if not match:
        raise SystemExit(f"Could not read UiMod version= from {path}")
    return require_semver(match.group(1).strip())


def require_semver(version: str) -> str:
    if version[:1] in ("v", "V"):
        raise SystemExit(f"Version {version} must be semver with no leading v")
    if not SEMVER.fullmatch(version):
        raise SystemExit(f"Version {version} is not strict semver")
    return version


def extract_section(changelog: str, version: str) -> str:
    lines = changelog.lstrip("\ufeff").replace("\r\n", "\n").replace("\r", "\n").split("\n")
    header = re.compile(rf"^##\s+{re.escape(version)}\s*$")
    next_header = re.compile(r"^##\s+")
    start = None
    for index, line in enumerate(lines):
        if header.match(line):
            start = index
            break
    if start is None:
        raise SystemExit(
            f"CHANGELOG.md has no ## {version} section; refusing to publish without notes"
        )
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if next_header.match(lines[index]):
            end = index
            break
    body = "\n".join(lines[start + 1 : end]).strip()
    if not body:
        raise SystemExit(
            f"CHANGELOG.md section ## {version} is empty; refusing to publish without notes"
        )
    return f"## {version}\n\n{body}\n"


def release_notes(section: str) -> str:
    return section.rstrip() + "\n\n" + INSTALL_LINE + "\n"


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mod", default="StockPiler.mod")
    parser.add_argument("--changelog", default="CHANGELOG.md")
    parser.add_argument("--version", help="Override the version read from the .mod")
    parser.add_argument("--section-out", required=True)
    parser.add_argument("--notes-out", required=True)
    args = parser.parse_args(argv)

    version = require_semver(args.version.strip()) if args.version else read_mod_version(Path(args.mod))
    changelog_path = Path(args.changelog)
    if not changelog_path.is_file():
        raise SystemExit(f"Missing {changelog_path}")

    section = extract_section(changelog_path.read_text(encoding="utf-8"), version)
    notes = release_notes(section)
    section_out = Path(args.section_out)
    notes_out = Path(args.notes_out)
    section_out.parent.mkdir(parents=True, exist_ok=True)
    notes_out.parent.mkdir(parents=True, exist_ok=True)
    section_out.write_text(section, encoding="utf-8")
    notes_out.write_text(notes, encoding="utf-8")
    print(version)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

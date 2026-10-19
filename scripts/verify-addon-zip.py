#!/usr/bin/env python3
"""Check that an addon zip extracts as StockPiler/, matching the 1.0.0 upload."""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

REQUIRED = (
    "StockPiler/StockPiler.mod",
    "StockPiler/README.md",
)


def file_names(path: Path) -> list[str]:
    if not zipfile.is_zipfile(path):
        raise SystemExit(f"{path} is not a zip archive")
    names: list[str] = []
    with zipfile.ZipFile(path) as archive:
        for info in archive.infolist():
            name = info.filename
            if "\\" in name:
                raise SystemExit(f"Zip entry uses backslashes: {name}")
            if name.startswith("/") or (len(name) >= 2 and name[1] == ":"):
                raise SystemExit(f"Zip entry is absolute: {name}")
            parts = [part for part in name.split("/") if part not in ("", ".")]
            if any(part == ".." for part in parts):
                raise SystemExit(f"Zip entry escapes the archive: {name}")
            if name.endswith("/") or not parts:
                continue
            names.append("/".join(parts))
    return names


def verify(path: Path) -> None:
    names = file_names(path)
    if not names:
        raise SystemExit(f"{path} has no files")
    bad = [name for name in names if not name.startswith("StockPiler/")]
    if bad:
        preview = ", ".join(bad[:8])
        raise SystemExit(
            "Zip must extract to StockPiler/ (same layout as the 1.0.0 upload). "
            f"Unexpected entries: {preview}"
        )
    nested = [name for name in names if name.startswith("StockPiler/StockPiler/")]
    if nested:
        raise SystemExit("Zip is nested as StockPiler/StockPiler/")
    missing = [name for name in REQUIRED if name not in names]
    if missing:
        raise SystemExit("Zip is missing " + ", ".join(missing))
    if not any(name.startswith("StockPiler/Source/") for name in names):
        raise SystemExit("Zip is missing StockPiler/Source/")
    print(f"Zip layout ok: {len(names)} files under StockPiler/")


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        raise SystemExit("usage: verify-addon-zip.py <zip>")
    verify(Path(argv[0]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""Split the preserved Istrolid concatenated JavaScript into original sections.

Usage: python tools/split_bundle.py /path/to/istrolid.cat.js ./recovered
The header markers are kept verbatim. No evaluation or network access.
"""
from pathlib import Path
import re
import sys

def split(source: Path, destination: Path):
    text = source.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)
    indices = [(i, match.group(1)) for i, line in enumerate(lines)
               if (match := re.match(r"^//from (.+?)\s*$", line))]
    if not indices:
        raise ValueError("No //from sections found")
    destination.mkdir(parents=True, exist_ok=True)
    if indices[0][0]:
        (destination / "_preamble.js").write_text("".join(lines[:indices[0][0]]), encoding="utf-8")
    for n, (start, name) in enumerate(indices):
        end = indices[n + 1][0] if n + 1 < len(indices) else len(lines)
        path = destination / name
        if not path.resolve().is_relative_to(destination.resolve()):
            raise ValueError(f"unsafe section path: {name}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(lines[start:end]), encoding="utf-8")
    print(f"Wrote {len(indices)} section files to {destination}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: split_bundle.py INPUT_JS OUTPUT_DIRECTORY")
    split(Path(sys.argv[1]), Path(sys.argv[2]))

#!/usr/bin/env python3
"""The release notes of one version: its section of CHANGELOG.md (from its
"## <version> - <date>" heading up to the next "## "), without the heading.

    tools/release_notes.py <version> [CHANGELOG.md]

Prints the notes; exits 1 when the version has no section or an empty one, so a
tag without its changelog entry publishes nothing (.github/workflows/release.yml)."""
import re
import sys
from pathlib import Path


def notes(text, version):
    out, on = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            if on:
                break
            on = re.match(r"## v?%s(\s|$)" % re.escape(version), line) is not None
            continue
        if on:
            out.append(line)
    body = "\n".join(out).strip()
    return body or None


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.strip(), file=sys.stderr)
        return 2
    version = argv[1].removeprefix("v")
    path = Path(argv[2] if len(argv) == 3 else Path(__file__).resolve().parents[1] / "CHANGELOG.md")
    body = notes(path.read_text(encoding="utf-8"), version)
    if body is None:
        print(f"{path.name} has no notes for {version}: add its section before tagging", file=sys.stderr)
        return 1
    print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

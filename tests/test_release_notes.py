"""tools/release_notes.py: a version's section of CHANGELOG.md, and the
changelog itself well formed (every version heading "## X.Y.Z - date" with notes)."""
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import release_notes  # noqa: E402

SAMPLE = """# Changelog

## 1.1.0 - 2026-11-02

### Fixed
- One thing.

## 1.0.10 - 2026-11-01

- Ten.

## 1.0.1 - 2026-10-31

- First fix.
"""


class ReleaseNotesTests(unittest.TestCase):
    def test_section(self):
        self.assertEqual(release_notes.notes(SAMPLE, "1.1.0"), "### Fixed\n- One thing.")
        self.assertEqual(release_notes.notes(SAMPLE, "1.0.1"), "- First fix.")
        self.assertEqual(release_notes.notes(SAMPLE, "1.0.10"), "- Ten.")

    def test_missing_or_empty(self):
        self.assertIsNone(release_notes.notes(SAMPLE, "1.0"))
        self.assertIsNone(release_notes.notes(SAMPLE, "2.0.0"))
        self.assertIsNone(release_notes.notes("## 3.0.0 - 2026-12-01\n\n", "3.0.0"))

    def test_changelog(self):
        text = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        heads = [l for l in text.splitlines() if l.startswith("## ")]
        self.assertTrue(heads, "CHANGELOG.md has versions")
        for h in heads:
            m = re.match(r"## (\d+\.\d+\.\d+) - (\d{4}-\d{2}-\d{2}|unreleased)$", h)
            self.assertIsNotNone(m, h)
            self.assertIsNotNone(release_notes.notes(text, m.group(1)), h)
        self.assertNotRegex(text, "[‐-―−]", "only the hyphen-minus")


if __name__ == "__main__":
    unittest.main()

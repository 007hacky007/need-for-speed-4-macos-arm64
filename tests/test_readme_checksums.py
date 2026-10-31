import unittest
from pathlib import Path

from tools.game_source import SUPPORTED

ROOT = Path(__file__).resolve().parents[1]


class ReadmeChecksumTests(unittest.TestCase):
    def test_readme_tables_match_supported(self):
        lines = (ROOT / 'README.md').read_text().splitlines()
        row = next(line for line in lines if line.startswith('| User-supplied retail assets'))
        self.assertIn(f"All {SUPPORTED['assets']['files']:,} files", row)
        self.assertIn(f"{SUPPORTED['assets']['bytes']:,} total", row)
        self.assertIn(f"`{SUPPORTED['assets']['sha256']}`", row)
        icon = next(line for line in lines if line.startswith('| User-supplied Windows icon'))
        self.assertIn(f"| {SUPPORTED['icon']['bytes']} |", icon)
        self.assertIn(f"`{SUPPORTED['icon']['sha256']}`", icon)


if __name__ == '__main__':
    unittest.main()

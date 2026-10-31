import re
import unittest
from pathlib import Path

from tools import make_builder

ROOT = Path(__file__).resolve().parents[1]


class MakeBuilderTests(unittest.TestCase):
    def test_bundle_sources_cover_pipeline_and_exclude_private_dirs(self):
        names = {p.as_posix() for p in make_builder.build_sources(ROOT)}
        for required in ('build.sh', 'requirements.txt', 'tools/build_app.py', 'tools/builder_cli.py',
                         'tools/game_source.py', 'tools/addons.py', 'tools/disc.py', 'tools/downloads.py',
                         'tools/package.py', 'tools/prepare.py', 'tools/compile.py', 'tools/win32_args.json',
                         'runtime/scene.metal', 'runtime/scene.vert', 'runtime/scene.frag', 'launcher/main.m',
                         'third_party/SilentPatchNFS90s-LICENSE'):
            self.assertIn(required, names)
        self.assertFalse(any(n.split('/')[0] in ('tests', 'docs', 'gen', 'out', 'local', 'builder') for n in names))
        self.assertFalse(any('__pycache__' in n for n in names))

    def test_swift_and_python_bundle_entries_match(self):
        swift = (ROOT / 'builder/Sources/BuilderCore/Workspace.swift').read_text()
        match = re.search(r'bundledSourceEntries\s*=\s*\[([^\]]*)\]', swift)
        self.assertEqual(tuple(re.findall(r'"([^"]+)"', match.group(1))), make_builder.ENTRIES)
        self.assertEqual({p.parts[0] for p in make_builder.build_sources(ROOT)}, set(make_builder.ENTRIES))

    def test_parse_minos(self):
        out = 'Load command 9\n      cmd LC_BUILD_VERSION\n    platform 1\n       minos 12.0\n         sdk 15.0\n'
        self.assertEqual(make_builder.parse_minos(out), '12.0')
        with self.assertRaises(ValueError):
            make_builder.parse_minos('Load command 1\n cmd LC_SEGMENT_64\n')

    def test_info_plist(self):
        info = make_builder.info_plist('1.2.0')
        self.assertEqual(info['CFBundleIdentifier'], 'org.classicgames.nfsiv.builder')
        self.assertEqual(info['CFBundleExecutable'], 'NFSIVBuilder')
        self.assertEqual(info['CFBundleDisplayName'], 'NFSIV Builder')
        self.assertEqual(info['LSMinimumSystemVersion'], '12.0')
        self.assertEqual(info['CFBundleShortVersionString'], '1.2.0')
        self.assertEqual(info['CFBundleInfoDictionaryVersion'], '6.0')
        package = (ROOT / 'builder/Package.swift').read_text()
        self.assertIn('.macOS(.v12)', package)
        self.assertIn('name: "NFSIVBuilder"', package)


if __name__ == '__main__':
    unittest.main()

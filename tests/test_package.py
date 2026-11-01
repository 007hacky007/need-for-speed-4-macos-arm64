import json
from pathlib import Path
import tempfile
import unittest
import sys
import plistlib
import struct
import subprocess
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
import package


class PackageTests(unittest.TestCase):
    def test_package_converts_supplied_windows_icon_and_declares_it_in_bundle(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            game = root / 'Game'
            for name in ('data', 'savedata'):
                (game / name).mkdir(parents=True)
            for name in ('nfs4.exe', 'eacsnd.dll'):
                (game / name).write_bytes(b'synthetic executable fixture')
            bitmap = struct.pack('<IIIHHIIIIII', 40, 32, 64, 1, 32, 0, 4096, 0, 0, 0, 0)
            bitmap += b'\0\0\xff\xff' * 1024 + bytes(128)
            icon = struct.pack('<HHHBBBBHHII', 0, 1, 1, 32, 32, 0, 0, 1, 32, len(bitmap), 22) + bitmap
            (game / 'NFSHS.ICO').write_bytes(icon)
            (root / 'out').mkdir()
            for name in ('nfsiv', 'linked.exe'):
                (root / 'out' / name).write_bytes(b'synthetic native fixture')
            (root / 'third_party').mkdir()
            runtime = root / 'MoltenVK/MoltenVK'
            (runtime / 'dynamic/dylib/macOS').mkdir(parents=True)
            (runtime / 'dynamic/dylib/macOS/libMoltenVK.dylib').write_bytes(b'synthetic runtime')
            (runtime.parent / 'LICENSE').write_text('fixture notice')
            run = subprocess.run
            def command(args, **kwargs):
                if args[0] in ('/usr/bin/sips', '/bin/cp'):
                    return run(args, **kwargs)
                if args[0] == 'clang':
                    Path(args[args.index('-o') + 1]).write_bytes(b'synthetic launcher')
                return subprocess.CompletedProcess(args, 0)
            with patch.object(package, 'ROOT', root), \
                    patch.object(package.subprocess, 'run', side_effect=command), \
                    patch.object(package.subprocess, 'check_output', return_value='arm64'):
                app = package.package_app(game, moltenvk=runtime, builder_version='0.2.0')
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['NFSBuilderVersion'], '0.2.0')
            self.assertEqual((app / 'Contents/Resources/Game/nfshs.ico').read_bytes(), icon)
            self.assertTrue((app / 'Contents/Resources/Game/data').is_dir())
            # An update from an app built before the icon was kept reuses its converted icon.
            (game / 'NFSHS.ICO').unlink()
            (game / 'NFSIV.icns').write_bytes(b'icns reused')
            with patch.object(package, 'ROOT', root), \
                    patch.object(package.subprocess, 'run', side_effect=command), \
                    patch.object(package.subprocess, 'check_output', return_value='arm64'):
                again = package.package_app(game, moltenvk=runtime, output=root / 'again/NFSIV.app')
            self.assertEqual((again / 'Contents/Resources/NFSIV.icns').read_bytes(), b'icns reused')
            self.assertNotIn('NFSBuilderVersion', plistlib.loads((again / 'Contents/Info.plist').read_bytes()))
            self.assertFalse((again / 'Contents/Resources/Game/nfshs.ico').exists())
            converted = app / 'Contents/Resources' / info['CFBundleIconFile']
            data = converted.read_bytes()
            self.assertEqual(data[:4], b'icns')
            self.assertEqual(struct.unpack_from('>I', data, 4)[0], len(data))


    def fixture(self, root):
        game = root / 'Game'
        game.mkdir()
        (game / 'asset').write_bytes(b'base game fixture')
        addons = root / 'Addons'
        overlay = addons / 'bonus' / 'Overlay'
        overlay.mkdir(parents=True)
        (overlay / 'asset').write_bytes(b'community fixture v1')
        (addons / 'catalog.json').write_text(json.dumps({
            'build_id': 'a' * 64, 'profiles': [{'id': 'bonus', 'name': 'Bonus car'}]}))
        return game, addons, overlay

    def test_catalog_lists_profiles_without_a_cache_identity(self):
        with tempfile.TemporaryDirectory() as t:
            game, addons, overlay = self.fixture(Path(t))
            self.assertEqual(package.content_catalog(addons), {'profiles': [{'id': 'bonus', 'name': 'Bonus car'}]})
            (overlay / 'asset').unlink()
            overlay.rmdir()
            with self.assertRaises(ValueError):
                package.content_catalog(addons)

    def test_reserved_and_duplicate_profile_ids_are_rejected(self):
        with tempfile.TemporaryDirectory() as t:
            game, addons, _ = self.fixture(Path(t))
            for profiles in [[{'id': 'original', 'name': 'Wrong'}],
                             [{'id': 'bonus', 'name': 'One'}, {'id': 'bonus', 'name': 'Two'}],
                             [{'id': '../escape', 'name': 'Wrong'}]]:
                (addons / 'catalog.json').write_text(json.dumps({'profiles': profiles}))
                with self.assertRaises(ValueError):
                    package.content_catalog(addons)

    def test_symlinks_are_rejected_instead_of_packaging_files_outside_the_payload(self):
        with tempfile.TemporaryDirectory() as t:
            game, addons, overlay = self.fixture(Path(t))
            outside = Path(t) / 'outside'
            outside.write_bytes(b'outside fixture')
            (overlay / 'link').symlink_to(outside)
            with self.assertRaises(ValueError):
                package.content_catalog(addons)

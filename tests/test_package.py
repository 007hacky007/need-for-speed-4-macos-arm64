import hashlib
import json
from pathlib import Path
import shutil
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
import game_source


class PackageTests(unittest.TestCase):
    def make_inputs(self, root, game=None):
        """A prepared game (or `game`), native outputs and a MoltenVK runtime for package_app."""
        if game is None:
            game = root / 'Game'
            for name in ('data', 'savedata'):
                (game / name).mkdir(parents=True)
            for name in ('nfs4.exe', 'eacsnd.dll'):
                (game / name).write_bytes(b'synthetic executable fixture')
            (game / 'nfshs.ico').write_bytes(self.icon())
        (root / 'out').mkdir()
        for name in ('nfsiv', 'linked.exe'):
            shutil.copy('/usr/bin/true', root / 'out' / name)
        (root / 'third_party').mkdir()
        runtime = root / 'MoltenVK/MoltenVK'
        (runtime / 'dynamic/dylib/macOS').mkdir(parents=True)
        shutil.copy('/usr/bin/true', runtime / 'dynamic/dylib/macOS/libMoltenVK.dylib')
        (runtime.parent / 'LICENSE').write_text('fixture notice')
        return game, runtime

    @staticmethod
    def icon():
        bitmap = struct.pack('<IIIHHIIIIII', 40, 32, 64, 1, 32, 0, 4096, 0, 0, 0, 0)
        bitmap += b'\0\0\xff\xff' * 1024 + bytes(128)
        return struct.pack('<HHHBBBBHHII', 0, 1, 1, 32, 32, 0, 0, 1, 32, len(bitmap), 22) + bitmap

    def package(self, root, game, runtime, clones=True, **options):
        """package_app with clang and lipo stubbed; copying, xattr and codesign run for real.
        clones=False makes every cp -c fail, as on a volume without APFS clones."""
        run = subprocess.run
        def command(args, **kwargs):
            if args[0] == 'clang':
                shutil.copy('/usr/bin/true', args[args.index('-o') + 1])
                return subprocess.CompletedProcess(args, 0)
            if not clones and args[:2] == ['/bin/cp', '-c']:
                return subprocess.CompletedProcess(args, 1)
            return run(args, **kwargs)
        with patch.object(package, 'ROOT', root), \
                patch.object(package.subprocess, 'run', side_effect=command), \
                patch.object(package.subprocess, 'check_output', return_value='arm64'):
            return package.package_app(game, moltenvk=runtime, **options)

    def test_package_converts_supplied_windows_icon_and_declares_it_in_bundle(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            game, runtime = self.make_inputs(root)
            (game / 'SETUP.EXE').write_bytes(b'windows extra')
            (game / 'DIRECTX').mkdir()
            (game / 'DIRECTX/DXSETUP.EXE').write_bytes(b'windows extra')
            (game / 'game-files.json').write_text('{}')
            app = self.package(root, game, runtime, builder_version='0.2.0')
            info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['NFSBuilderVersion'], '0.2.0')
            bundled = app / 'Contents/Resources/Game'
            self.assertEqual((bundled / 'nfshs.ico').read_bytes(), self.icon())
            self.assertTrue((bundled / 'data').is_dir())
            # The whole prepared game goes in, with the two settings files written anew.
            self.assertEqual(sorted(p.relative_to(bundled).as_posix() for p in bundled.rglob('*') if p.is_file()),
                             ['DIRECTX/DXSETUP.EXE', 'SETUP.EXE', 'drivers/dx7/thrash.ini', 'eacsnd.dll',
                              'game-files.json', 'nfs4.exe', 'nfs4.ini', 'nfshs.ico'])
            converted = app / 'Contents/Resources' / info['CFBundleIconFile']
            data = converted.read_bytes()
            self.assertEqual(data[:4], b'icns')
            self.assertEqual(struct.unpack_from('>I', data, 4)[0], len(data))

    def test_no_macos_code_from_the_copy_and_its_quarantine_stays(self):
        """A downloaded copy may hide a Mac program: it never goes into the app, no file from the
        copy can be run, and the files copied from the copy keep the download's quarantine (only
        what the build made loses it), with APFS clones and without."""
        for clones in (True, False):
            with self.subTest(clones=clones):
                self.check_copy_from_a_download(clones)

    def check_copy_from_a_download(self, clones):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            copy = root / 'Repack'
            (copy / 'DATA').mkdir(parents=True)
            (copy / 'SAVEDATA').mkdir()
            (copy / 'DATA/file').write_bytes(b'asset')
            (copy / 'DATA/file').chmod(0o755)
            (copy / 'SAVEDATA/save').write_bytes(b'save')
            (copy / 'NFSHS.ICO').write_bytes(self.icon())
            (copy / 'DIRECTX').mkdir()
            (copy / 'DIRECTX/DXSETUP.EXE').write_bytes(b'MZ windows extra')
            (copy / 'DIRECTX/DXSETUP.EXE').chmod(0o755)
            shutil.copy('/usr/bin/true', copy / 'README.TXT')                      # a Mach-O under another name
            (copy / 'readme.dat').write_text('#!/bin/sh\necho hidden\n')       # a script under another name
            (copy / 'Tool.app/Contents/MacOS').mkdir(parents=True)
            shutil.copy('/usr/bin/true', copy / 'Tool.app/Contents/MacOS/Tool')
            (copy / 'Helper/Contents').mkdir(parents=True)                         # a bundle without an extension
            (copy / 'Helper/Contents/Info.plist').write_text('<plist/>')
            (copy / 'Helper/Contents/data.bin').write_bytes(b'payload')
            (copy / 'SETUPDIR').mkdir()
            (copy / 'SETUPDIR/run.command').write_text('#!/bin/sh\n')
            (copy / 'SETUPDIR/Tool.JAR').write_bytes(b'PK\x03\x04')
            (copy / 'SETUPDIR/open.terminal').write_text('<plist/>')
            (copy / 'SETUPDIR/SETUP.INI').write_text('[setup]\n')
            (copy / 'link').symlink_to('/usr/bin')
            mark = '0081;00000000;Test;'
            for path in ('DIRECTX', 'DIRECTX/DXSETUP.EXE', 'DATA/file'):
                subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.quarantine', mark, str(copy / path)], check=True)
            subprocess.run(['/usr/bin/xattr', '-wx', 'com.apple.FinderInfo', '00' * 31 + '01',
                            str(copy / 'SETUPDIR/SETUP.INI')], check=True)
            veg = root / 'veg'
            (veg / 'data').mkdir(parents=True)
            (veg / 'drivers/dx7').mkdir(parents=True)
            (veg / 'drivers/dx7/thrash.ini').write_text('[THRASH]\n')
            (veg / 'nfs4.exe').write_bytes(b'game')
            (veg / 'eacsnd.dll').write_bytes(b'sound')
            prepared = root / 'prepared/Game'
            sha = lambda data: hashlib.sha256(data).hexdigest()
            run = subprocess.run
            def no_clones(args, **kwargs):
                if not clones and args[:2] == ['/bin/cp', '-c']:
                    return subprocess.CompletedProcess(args, 1)
                return run(args, **kwargs)
            with patch.object(game_source, 'SOURCE', game_source.inventory(copy)), \
                    patch.object(game_source, 'ICON_SHA', sha(self.icon())), \
                    patch.object(game_source, 'ICON_SIZE', len(self.icon())), \
                    patch.object(game_source, 'GAME_SHA', sha(b'game')), \
                    patch.object(game_source, 'SOUND_SHA', sha(b'sound')), \
                    patch.object(game_source.subprocess, 'run', side_effect=no_clones), \
                    patch.object(game_source, 'extract_7z', lambda _, target, __: shutil.copytree(veg, target)):
                game_source.prepare_game(copy, root / 'veg.7z', root / '7zz', prepared)
            game, runtime = self.make_inputs(root, prepared)
            app = self.package(root, game, runtime, clones=clones)
            bundled = app / 'Contents/Resources/Game'
            self.assertEqual(sorted(p.relative_to(bundled).as_posix() for p in bundled.rglob('*')
                                    if p.is_file() or p.is_symlink()),
                             ['DIRECTX/DXSETUP.EXE', 'SETUPDIR/SETUP.INI', 'data/file', 'drivers/dx7/thrash.ini',
                              'eacsnd.dll', 'game-files.json', 'nfs4.exe', 'nfs4.ini', 'nfshs.ico', 'savedata/save'])
            self.assertEqual([p.relative_to(bundled).as_posix() for p in bundled.rglob('*')
                              if p.is_file() and p.stat().st_mode & 0o111], [], 'no file of the game can be run')
            for path in ('DIRECTX', 'DIRECTX/DXSETUP.EXE', 'data/file'):
                quarantine = subprocess.run(['/usr/bin/xattr', '-p', 'com.apple.quarantine', str(bundled / path)],
                                            capture_output=True, text=True)
                self.assertEqual(quarantine.stdout.strip(), mark, f'game data keeps its quarantine: {path}')
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True,
                           capture_output=True)
            with patch.object(game_source, 'PREPARED', game_source.inventory(bundled)), \
                    patch.object(game_source, 'GAME_SHA', sha(b'game')), \
                    patch.object(game_source, 'SOUND_SHA', sha(b'sound')):
                game_source.verify_bundle(app)

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

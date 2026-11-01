import contextlib
import hashlib
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import game_source
from tests.test_disc import image


class GameSourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='game source ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def folder(self):
        source = self.root / 'retail folder'
        (source / 'DATA').mkdir(parents=True)
        (source / 'SAVEDATA').mkdir()
        (source / 'DATA/file').write_bytes(b'asset')
        (source / 'SAVEDATA/save').write_bytes(b'save')
        (source / 'NFSHS.ICO').write_bytes(b'retail icon fixture')
        return source

    def test_source_icon_must_match_the_original_file(self):
        source = self.folder()
        with patch.object(game_source, 'SOURCE', game_source.inventory(source)):
            with self.assertRaisesRegex(ValueError, 'NFSHS.ICO does not match') as caught:
                game_source.verify_source(source)
        self.assertEqual(caught.exception.reason, 'icon')
        self.assertIsNone(caught.exception.detected)
        (source / 'NFSHS.ICO').unlink()
        with patch.object(game_source, 'SOURCE', game_source.inventory(source)):
            with self.assertRaisesRegex(ValueError, 'NFSHS.ICO is missing') as caught:
                game_source.verify_source(source)
        self.assertEqual(caught.exception.reason, 'icon-missing')

    def test_inventory_matches_documented_digest_algorithm(self):
        source = self.folder()
        expected = hashlib.sha256()
        for name, data in (('data/file', b'asset'), ('savedata/save', b'save')):
            expected.update(name.encode() + b'\0' + hashlib.sha256(data).digest())
        self.assertEqual(game_source.inventory(source), {'files': 2, 'bytes': 9, 'sha256': expected.hexdigest()})
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.verify_source(source)
        self.assertEqual(caught.exception.reason, 'assets')

    def test_modified_copy_is_rejected_with_plain_message_and_inventory(self):
        source = self.folder()
        (source / 'DATA/file').write_bytes(b'assEt')
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.verify_source(source)
        error = caught.exception
        self.assertEqual(error.reason, 'assets')
        self.assertIn('European retail CD', str(error))
        self.assertEqual(str(error), game_source.MESSAGES['assets'])
        self.assertEqual(error.detected, game_source.inventory(source))
        self.assertNotIn(error.detected['sha256'], str(error))
        self.assertNotIn(game_source.SOURCE['sha256'], str(error))

    def test_folder_without_icon_names_the_icon(self):
        source = self.folder()
        (source / 'NFSHS.ICO').unlink()
        with patch.object(game_source, 'SOURCE', game_source.inventory(source)):
            with self.assertRaises(game_source.SourceRejected) as caught:
                game_source.verify_source(source)
        self.assertEqual(caught.exception.reason, 'icon-missing')
        self.assertIn('NFSHS.ICO', str(caught.exception))

    def test_folder_without_data_is_not_a_game(self):
        for missing in ('DATA', 'SAVEDATA'):
            with self.subTest(missing=missing):
                source = self.folder()
                import shutil
                shutil.rmtree(source / missing)
                with self.assertRaises(game_source.SourceRejected) as caught:
                    game_source.verify_source(source)
                self.assertEqual(caught.exception.reason, 'not-game')
                self.assertIn('DATA and SAVEDATA', str(caught.exception))
                shutil.rmtree(source)

    def test_ccd_without_img_and_bad_layout(self):
        source = self.root / 'disc file.ccd'
        text = '[CloneCD]\nVersion=3\n[Disc]\nSessions=1\nDataTracksScrambled=0\n[TRACK 1]\nMODE=1\nINDEX 1=0\n'
        source.write_text(text)
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.resolve_image(source)
        self.assertEqual(caught.exception.reason, 'ccd-image')
        source.with_suffix('.img').write_bytes(image())
        for broken in (text.replace('DataTracksScrambled=0', 'DataTracksScrambled=1'), 'not an ini'):
            source.write_text(broken)
            with self.assertRaises(game_source.SourceRejected) as caught:
                game_source.resolve_image(source)
            self.assertEqual(caught.exception.reason, 'image-layout')
        cue = self.root / 'two tracks.cue'
        cue.write_text('FILE "x.bin" BINARY\nTRACK 1 MODE1/2352\nINDEX 1 00:00:00\nTRACK 2 AUDIO\n')
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.extract_source(cue, self.root / 'out')
        self.assertEqual(caught.exception.reason, 'image-layout')
        lonely = self.root / 'lonely.cue'
        lonely.write_text('FILE "missing.bin" BINARY\nTRACK 1 MODE1/2352\nINDEX 1 00:00:00\n')
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.extract_source(lonely, self.root / 'out')
        self.assertEqual(caught.exception.reason, 'cue-image')

    def test_wrong_type_missing_and_unreadable_inputs(self):
        sub = self.root / 'disc.sub'
        sub.write_bytes(b'x')
        cases = ((sub, 'unsupported-type'), (self.root / 'gone.iso', 'missing'))
        for path, reason in cases:
            with self.assertRaises(game_source.SourceRejected) as caught:
                game_source.resolve_image(path)
            self.assertEqual(caught.exception.reason, reason)
        broken = self.root / 'broken.iso'
        broken.write_bytes(b'\0' * 2048 * 20)
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.extract_source(broken, self.root / 'out')
        self.assertEqual(caught.exception.reason, 'unreadable')
        self.assertFalse((self.root / 'out').exists())

    def test_symlinked_source_is_link(self):
        source = self.folder()
        link = self.root / 'linked folder'
        link.symlink_to(source)
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.verify_source(link)
        self.assertEqual(caught.exception.reason, 'link')
        (source / 'NFSHS.ICO').unlink()
        (source / 'NFSHS.ICO').symlink_to(source / 'DATA/file')
        with patch.object(game_source, 'SOURCE', game_source.inventory(source)):
            with self.assertRaises(game_source.SourceRejected) as caught:
                game_source.verify_source(source)
        self.assertEqual(caught.exception.reason, 'link')

    def test_cli_message_keeps_detected_inventory(self):
        source = self.folder()
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.verify_source(source)
        text = game_source.describe_rejection(caught.exception)
        first, second = text.splitlines()
        self.assertEqual(first, game_source.MESSAGES['assets'])
        self.assertTrue(second.startswith('Detected: 2 files, 9 bytes, SHA-256 '))
        self.assertTrue(second.endswith('expected 1,328 files, 547,813,845 bytes.'))
        self.assertEqual(game_source.describe_rejection(game_source.SourceRejected('icon')), game_source.MESSAGES['icon'])

    def test_supported_release_metadata(self):
        supported = game_source.SUPPORTED
        self.assertEqual(supported['release'], 'Need for Speed: Road Challenge, European retail CD')
        self.assertEqual(game_source.SOURCE, {k: supported['assets'][k] for k in ('files', 'bytes', 'sha256')})
        self.assertEqual((game_source.ICON_SIZE, game_source.ICON_SHA),
                         (supported['icon']['bytes'], supported['icon']['sha256']))
        self.assertEqual(set(game_source.MESSAGES), {
            'missing', 'link', 'unsupported-type', 'ccd-image', 'cue-image', 'image-layout', 'unreadable',
            'not-game', 'assets', 'icon-missing', 'icon', 'not-app', 'bundle', 'old-app'})
        for text in [*game_source.MESSAGES.values(), *(v for v in supported.values() if isinstance(v, str))]:
            self.assertFalse(any(ord(c) > 127 for c in text), text)

    def test_symlinks_and_case_collisions_rejected(self):
        source = self.folder()
        (source / 'DATA/link').symlink_to(source / 'SAVEDATA/save')
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.inventory(source)
        self.assertEqual(caught.exception.reason, 'link')
        (source / 'DATA/link').unlink()
        # APFS cannot store case-colliding entries, so simulate the directory listing.
        original = Path.iterdir
        def entries(path):
            if path == source / 'DATA':
                return iter([source / 'DATA/file', source / 'DATA/FILE'])
            return original(path)
        with patch.object(Path, 'iterdir', entries):
            with self.assertRaisesRegex(ValueError, 'case-colliding'):
                game_source.inventory(source)

    def test_finder_metadata_does_not_change_inventory(self):
        source = self.folder()
        before = game_source.inventory(source)
        (source / 'DATA/.DS_Store').write_bytes(b'metadata')
        (source / 'DATA/._file').write_bytes(b'metadata')
        (source / 'DATA/__MACOSX').mkdir()
        (source / 'DATA/__MACOSX/ignored').write_bytes(b'metadata')
        self.assertEqual(game_source.inventory(source), before)

    def test_overlay_copy_replaces_retail_case_and_skips_metadata(self):
        source = self.folder()
        overlay = self.root / 'overlay'
        (overlay / 'data').mkdir(parents=True)
        (overlay / 'data/FILE').write_bytes(b'patch')
        (source / 'DATA/.DS_Store').write_bytes(b'metadata')
        destination = self.root / 'prepared'
        game_source.copy_assets(source, destination)
        game_source.copy_assets(overlay, destination)
        self.assertEqual(list((destination / 'data').iterdir()), [destination / 'data/file'])
        self.assertEqual((destination / 'data/file').read_bytes(), b'patch')

    def test_prepare_validates_veg_before_creating_game_and_normalizes_ini(self):
        source = self.folder()
        overlay = self.root / 'veg payload'
        (overlay / 'data').mkdir(parents=True)
        (overlay / 'drivers/dx7').mkdir(parents=True)
        (overlay / 'drivers/dx7/thrash.ini').write_text('[THRASH]\nFile=dx7a.dll\n')
        (overlay / 'nfs4.exe').write_bytes(b'game')
        (overlay / 'eacsnd.dll').write_bytes(b'sound')
        (source / 'SETUP.EXE').write_bytes(b'windows installer')
        (source / 'DIRECTX').mkdir()
        (source / 'DIRECTX/DXSETUP.EXE').write_bytes(b'directx')
        (source / 'EACSND.DLL').write_bytes(b'retail sound')
        destination = self.root / 'new game'
        def extract(_, target, __):
            import shutil
            shutil.copytree(overlay, target)
        with patch.object(game_source, 'SOURCE', game_source.inventory(source)), \
                patch.object(game_source, 'ICON_SHA', hashlib.sha256(b'retail icon fixture').hexdigest()), \
                patch.object(game_source, 'ICON_SIZE', len(b'retail icon fixture')), \
                patch.object(game_source, 'extract_7z', extract):
            with self.assertRaisesRegex(ValueError, 'VEG nfs4.exe checksum'):
                game_source.prepare_game(source, self.root / 'veg.7z', self.root / '7zz', destination)
            self.assertFalse(destination.exists())
            with patch.object(game_source, 'GAME_SHA', hashlib.sha256(b'game').hexdigest()), \
                    patch.object(game_source, 'SOUND_SHA', hashlib.sha256(b'sound').hexdigest()):
                game_source.prepare_game(source, self.root / 'veg.7z', self.root / '7zz', destination)
        self.assertEqual((destination / 'nfs4.ini').read_text(), game_source.INI)
        self.assertEqual((destination / 'savedata/save').read_bytes(), b'save')
        self.assertEqual((source / 'DATA/file').read_bytes(), b'asset')
        self.assertEqual((destination / 'nfshs.ico').read_bytes(), (source / 'NFSHS.ICO').read_bytes())
        self.assertFalse((source / 'nfs4.ini').exists())
        # The whole copy goes in; VEG's sound module replaces the retail one.
        self.assertEqual((destination / 'SETUP.EXE').read_bytes(), b'windows installer')
        self.assertEqual((destination / 'DIRECTX/DXSETUP.EXE').read_bytes(), b'directx')
        self.assertEqual([p.name for p in destination.iterdir() if p.name.casefold() == 'eacsnd.dll'], ['eacsnd.dll'])
        self.assertEqual((destination / 'eacsnd.dll').read_bytes(), b'sound')
        record = json.loads((destination / game_source.RECORD).read_text())
        self.assertEqual(record, game_source.tree_inventory(destination))
        self.assertEqual(record['files'], 7)  # data, savedata, icon, nfs4.exe, eacsnd.dll and the two extras
        with self.assertRaises(FileExistsError):
            game_source.prepare_game(source, self.root / 'veg.7z', self.root / '7zz', destination)

    def test_iso_and_cue_paths_with_spaces_extract_without_changing_source(self):
        for raw, suffix in ((False, '.iso'), (True, '.cue')):
            with self.subTest(suffix=suffix):
                source = self.root / ('disc file' + suffix)
                data = image(raw=raw)
                if raw:
                    sibling = self.root / 'image file.bin'
                    sibling.write_bytes(data)
                    source.write_text('FILE "image file.bin" BINARY\nTRACK 1 MODE1/2352\nINDEX 1 00:00:00\n')
                else:
                    source.write_bytes(data)
                original = source.read_bytes()
                destination = self.root / ('extracted ' + suffix)
                game_source.extract_source(source, destination)
                self.assertEqual((destination / 'Simulation/cop356_german.crp').read_bytes(), b'asset')
                self.assertEqual(source.read_bytes(), original)

    def test_ccd_requires_single_unscrambled_mode1_track(self):
        source = self.root / 'disc file.ccd'
        text = '[CloneCD]\nVersion=3\n[Disc]\nSessions=1\nDataTracksScrambled=0\n[TRACK 1]\nMODE=1\nINDEX 1=0\n'
        source.write_text(text)
        source.with_suffix('.img').write_bytes(image())
        self.assertEqual(game_source.resolve_image(source), source.with_suffix('.img'))
        source.write_text(text + '[TRACK 2]\nMODE=0\nINDEX 1=4\n')
        with self.assertRaisesRegex(ValueError, 'layout is not supported'):
            game_source.resolve_image(source)

    def test_invalid_truncated_and_symlink_images_rejected(self):
        source = self.root / 'disc.img'
        source.write_bytes(image()[:-1])
        with self.assertRaises(game_source.SourceRejected) as caught:
            game_source.extract_source(source, self.root / 'output')
        self.assertEqual(caught.exception.reason, 'unreadable')
        link = self.root / 'link.img'
        link.symlink_to(source)
        with self.assertRaisesRegex(ValueError, 'not an alias or link'):
            game_source.resolve_image(link)
        self.assertFalse((self.root / 'output').exists())


if __name__ == '__main__':
    unittest.main()


class BundleReuseTests(unittest.TestCase):
    """An update reuses the prepared game an existing NFSIV.app carries, reading it only."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='bundle reuse ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def app(self, stamp='0.1.0', record=True):
        app = self.root / 'Old' / 'NFSIV.app'
        game = app / 'Contents/Resources/Game'
        (game / 'data/cars/base').mkdir(parents=True)
        (game / 'savedata').mkdir()
        (game / 'data/cars/base/car.viv').write_bytes(b'prepared car')
        (game / 'savedata/menu.qfs').write_bytes(b'veg menu')
        (game / 'nfs4.exe').write_bytes(b'patched game')
        (game / 'eacsnd.dll').write_bytes(b'sound')
        (game / 'drivers/dx7').mkdir(parents=True)
        (game / 'drivers/dx7/thrash.ini').write_text('[THRASH]\n')
        (game / 'nfshs.ico').write_bytes(b'retail icon')
        (game / 'DIRECTX').mkdir()
        (game / 'DIRECTX/DXSETUP.EXE').write_bytes(b'windows extra')
        if record:
            (game / game_source.RECORD).write_text(json.dumps(game_source.tree_inventory(game)))
        (app / 'Contents/Resources/NFSIV.icns').write_bytes(b'icns converted')
        info = {'CFBundleIdentifier': 'org.classicgames.nfsiv'}
        if stamp:
            info['NFSBuilderVersion'] = stamp
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        return app

    def pinned(self, app):
        game = app / 'Contents/Resources/Game'
        sha = lambda name: hashlib.sha256((game / name).read_bytes()).hexdigest()
        return [patch.object(game_source, 'PREPARED', game_source.inventory(game)),
                patch.object(game_source, 'GAME_SHA', sha('nfs4.exe')),
                patch.object(game_source, 'SOUND_SHA', sha('eacsnd.dll')),
                patch.object(game_source, 'ICON_SHA', hashlib.sha256(b'retail icon').hexdigest())]

    def snapshot(self, folder):
        return {p.relative_to(folder).as_posix(): (p.read_bytes() if p.is_file() else None, p.stat().st_mtime_ns)
                for p in sorted(folder.rglob('*'))}

    def test_pinned_prepared_tree_is_what_prepare_game_makes(self):
        self.assertEqual(game_source.PREPARED['files'], game_source.SOURCE['files'])
        self.assertRegex(game_source.PREPARED['sha256'], '^[0-9a-f]{64}$')
        self.assertNotEqual(game_source.PREPARED['sha256'], game_source.SOURCE['sha256'])

    def test_existing_app_is_verified_and_reused_without_writing_to_it(self):
        app = self.app()
        before = self.snapshot(app.parent)
        with contextlib.ExitStack() as stack:
            for item in self.pinned(app):
                stack.enter_context(item)
            self.assertTrue(game_source.is_app(app))
            verified, stamp = game_source.verify_bundle(app)
            self.assertEqual(stamp, '0.1.0')
            destination = self.root / 'work/Game'
            self.assertEqual(game_source.reuse_bundle(app, destination), verified)
        self.assertEqual((destination / 'data/cars/base/car.viv').read_bytes(), b'prepared car')
        self.assertEqual((destination / 'nfshs.ico').read_bytes(), b'retail icon')
        self.assertEqual((destination / 'DIRECTX/DXSETUP.EXE').read_bytes(), b'windows extra')
        self.assertFalse((destination / 'NFSIV.icns').exists())
        game = app / 'Contents/Resources/Game'
        self.assertEqual({k for k in self.snapshot(destination)}, {k for k in self.snapshot(game)})
        self.assertEqual(self.snapshot(app.parent), before)

    def test_no_file_of_the_game_is_ignored(self):
        """A missing or changed extra, or the icon, is found like a retail asset."""
        for index, name in enumerate(('DIRECTX/DXSETUP.EXE', 'nfshs.ico')):
            for change in ('missing', 'changed'):
                with self.subTest(name=name, change=change):
                    app = self.app()
                    with contextlib.ExitStack() as stack:
                        for item in self.pinned(app):
                            stack.enter_context(item)
                        path = app / 'Contents/Resources/Game' / name
                        path.unlink() if change == 'missing' else path.write_bytes(b'changed')
                        with self.assertRaises(game_source.SourceRejected) as caught:
                            game_source.verify_bundle(app)
                        self.assertEqual(caught.exception.reason, 'bundle')
                    import shutil
                    shutil.rmtree(app.parent)

    def test_app_from_a_builder_that_left_the_extras_out_is_not_reused(self):
        app = self.app(stamp=None, record=False)
        with contextlib.ExitStack() as stack:
            for item in self.pinned(app):
                stack.enter_context(item)
            with self.assertRaises(game_source.SourceRejected) as caught:
                game_source.verify_bundle(app)
            self.assertEqual(caught.exception.reason, 'old-app')
            self.assertIn('original game copy', str(caught.exception))
            with self.assertRaises(game_source.SourceRejected):
                game_source.reuse_bundle(app, self.root / 'work/Game')
        self.assertFalse((self.root / 'work/Game').exists())

    def test_modified_or_foreign_app_asks_for_the_original_copy(self):
        app = self.app()
        with contextlib.ExitStack() as stack:
            for item in self.pinned(app):
                stack.enter_context(item)
            (app / 'Contents/Resources/Game/data/cars/base/car.viv').write_bytes(b'modded car')
            with self.assertRaises(game_source.SourceRejected) as caught:
                game_source.verify_bundle(app)
            self.assertEqual(caught.exception.reason, 'bundle')
            self.assertIn('original game copy', str(caught.exception))
            with self.assertRaises(game_source.SourceRejected):
                game_source.reuse_bundle(app, self.root / 'work/Game')
            self.assertFalse((self.root / 'work/Game').exists())
            (app / 'Contents/Resources/Game/nfs4.exe').unlink()
            with self.assertRaises(game_source.SourceRejected) as caught:
                game_source.verify_bundle(app)
            self.assertEqual(caught.exception.reason, 'bundle')
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'com.example.other'}))
            with self.assertRaises(game_source.SourceRejected) as caught:
                game_source.verify_bundle(app)
            self.assertEqual(caught.exception.reason, 'not-app')

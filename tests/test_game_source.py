import hashlib
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
            with self.assertRaisesRegex(ValueError, 'NFSHS.ICO.*checksum'):
                game_source.verify_source(source)
        (source / 'NFSHS.ICO').unlink()
        with patch.object(game_source, 'SOURCE', game_source.inventory(source)):
            with self.assertRaisesRegex(ValueError, 'NFSHS.ICO'):
                game_source.verify_source(source)

    def test_inventory_matches_documented_digest_algorithm(self):
        source = self.folder()
        expected = hashlib.sha256()
        for name, data in (('data/file', b'asset'), ('savedata/save', b'save')):
            expected.update(name.encode() + b'\0' + hashlib.sha256(data).digest())
        self.assertEqual(game_source.inventory(source), {'files': 2, 'bytes': 9, 'sha256': expected.hexdigest()})
        with self.assertRaisesRegex(ValueError, 'unsupported.*checksum'):
            game_source.verify_source(source)

    def test_symlinks_and_case_collisions_rejected(self):
        source = self.folder()
        (source / 'DATA/link').symlink_to(source / 'SAVEDATA/save')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            game_source.inventory(source)
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
        with self.assertRaisesRegex(ValueError, 'CCD'):
            game_source.resolve_image(source)

    def test_invalid_truncated_and_symlink_images_rejected(self):
        source = self.root / 'disc.img'
        source.write_bytes(image()[:-1])
        with self.assertRaises(ValueError):
            game_source.extract_source(source, self.root / 'output')
        link = self.root / 'link.img'
        link.symlink_to(source)
        with self.assertRaisesRegex(ValueError, 'symlink'):
            game_source.resolve_image(link)
        self.assertFalse((self.root / 'output').exists())


if __name__ == '__main__':
    unittest.main()

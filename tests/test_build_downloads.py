import hashlib
import io
import tarfile
import tempfile
import unittest
import subprocess
import shutil
from pathlib import Path
from unittest.mock import patch

from tools import downloads


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.payload = b'verified dependency'
        self.sha = hashlib.sha256(self.payload).hexdigest()

    def test_fetch_verifies_cached_bytes_on_every_use(self):
        cached = self.root / 'dependency.tar'
        cached.write_bytes(self.payload)
        self.assertEqual(downloads.fetch(self.root, cached.name, 'https://invalid.test/archive', self.sha), cached)
        cached.write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            downloads.fetch(self.root, cached.name, 'https://invalid.test/archive', self.sha)
        self.assertEqual(cached.read_bytes(), b'tampered')

    def test_download_is_atomic_and_checksum_failure_leaves_no_file(self):
        with patch.object(downloads.urllib.request, 'urlopen', return_value=io.BytesIO(b'bad')):
            with self.assertRaisesRegex(ValueError, 'checksum'):
                downloads.fetch(self.root, 'archive', 'https://invalid.test/archive', self.sha)
        self.assertEqual(list(self.root.iterdir()), [])

    def test_download_success(self):
        with patch.object(downloads.urllib.request, 'urlopen', return_value=io.BytesIO(self.payload)):
            target = downloads.fetch(self.root, 'archive', 'https://invalid.test/archive', self.sha)
        self.assertEqual(target.read_bytes(), self.payload)

    def test_cache_symlink_and_unsafe_name_are_rejected(self):
        original = self.root / 'original'
        original.write_bytes(self.payload)
        (self.root / 'archive').symlink_to(original)
        for name in ('archive', '../original', '/tmp/archive'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                downloads.fetch(self.root, name, 'https://invalid.test/archive', self.sha)
        self.assertEqual(original.read_bytes(), self.payload)

    def archive(self, name, kind=tarfile.REGTYPE):
        target = self.root / 'archive.tar'
        with tarfile.open(target, 'w') as tar:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.linkname = '/tmp/outside'
            member.size = 4 if kind == tarfile.REGTYPE else 0
            tar.addfile(member, io.BytesIO(b'data') if member.size else None)
        return target

    def test_safe_tar_extracts_regular_files_and_executable_mode(self):
        target = self.archive('folder/tool')
        destination = self.root / 'extracted'
        downloads.extract_tar(target, destination)
        self.assertEqual((destination / 'folder/tool').read_bytes(), b'data')

    def test_tar_rejects_traversal_links_and_existing_destination(self):
        for name, kind in (('../outside', tarfile.REGTYPE), ('/outside', tarfile.REGTYPE),
                           ('folder/link', tarfile.SYMTYPE), ('folder/hard', tarfile.LNKTYPE)):
            with self.subTest(name=name, kind=kind):
                destination = self.root / 'extracted'
                with self.assertRaises(ValueError):
                    downloads.extract_tar(self.archive(name, kind), destination)
                self.assertFalse(destination.exists())
        destination.mkdir()
        with self.assertRaises(FileExistsError):
            downloads.extract_tar(self.archive('file'), destination)

    def test_tar_extracts_only_selected_native_inputs_without_framework_links(self):
        archive = self.root / 'archive.tar'
        with tarfile.open(archive, 'w') as tar:
            member = tarfile.TarInfo('native/library')
            member.size = 4
            tar.addfile(member, io.BytesIO(b'data'))
            member = tarfile.TarInfo('framework/link')
            member.type = tarfile.SYMTYPE
            member.linkname = 'target'
            tar.addfile(member)
        destination = self.root / 'extracted'
        downloads.extract_tar(archive, destination, include=('native',))
        self.assertEqual((destination / 'native/library').read_bytes(), b'data')
        self.assertFalse((destination / 'framework').exists())

    def test_7zip_rejects_unsafe_listing_before_creating_output(self):
        for listing in ('Path = ../escape\nSize = 4\n',
                        'Path = link\nSymbolic Link = outside\nSize = 0\n',
                        'Path = file\nSize = 1\n\nPath = FILE\nSize = 1\n'):
            with self.subTest(listing=listing):
                result = subprocess.CompletedProcess([], 0, listing, '')
                with patch.object(downloads.subprocess, 'run', return_value=result) as run:
                    with self.assertRaises(ValueError):
                        downloads.extract_7z(self.root / 'patch.7z', self.root / 'output', self.root / '7zz')
                self.assertEqual(run.call_count, 1)
                self.assertFalse((self.root / 'output').exists())

    @unittest.skipUnless(shutil.which('7zz'), 'requires portable 7-Zip')
    def test_7zip_selected_files_ignore_excluded_duplicates_and_wildcards(self):
        archive = self.root / 'installer payload.tar'
        with tarfile.open(archive, 'w') as tar:
            for name, data in (('$SYSDIR/$R0', b'windows1'), ('$SYSDIR/$R0', b'windows2'),
                               ('$TEMP/Cars/car[1]/car.viv', b'car'),
                               ('$TEMP/Cars/car1/car.viv', b'other car'),
                               ('unrelated/payload', b'excluded')):
                member = tarfile.TarInfo(name)
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
        output = self.root / 'selected'
        downloads.extract_7z(archive, output, Path(shutil.which('7zz')),
                             include=('$TEMP/Cars/car[1]',))
        self.assertEqual((output / '$TEMP/Cars/car[1]/car.viv').read_bytes(), b'car')
        self.assertEqual([p.relative_to(output).as_posix() for p in output.rglob('*') if p.is_file()],
                         ['$TEMP/Cars/car[1]/car.viv'])

    def test_7zip_selection_still_rejects_all_traversal_spellings(self):
        for path in ('$TEMP/Cars/../escape', 'excluded/../escape'):
            listing = f'Path = {path}\nSize = 4\n'
            with self.subTest(path=path), patch.object(downloads.subprocess, 'run', return_value=
                    subprocess.CompletedProcess([], 0, listing, '')):
                with self.assertRaisesRegex(ValueError, 'unsafe archive path'):
                    downloads.extract_7z(self.root / 'patch.7z', self.root / 'output', self.root / '7zz',
                                         include=('$TEMP/Cars',))
                self.assertFalse((self.root / 'output').exists())


if __name__ == '__main__':
    unittest.main()

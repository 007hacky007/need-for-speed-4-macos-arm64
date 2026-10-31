import contextlib
import hashlib
import io
import json
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import build_app, builder_cli, game_source
from tests.test_disc import image

PREFIX = 'NFSIV-EVENT '


def snapshot(folder):
    return sorted((str(p.relative_to(folder)), p.stat().st_size, p.stat().st_mtime_ns)
                  for p in Path(folder).rglob('*'))


class BuilderCliTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='builder cli ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cache = self.root / 'cache'
        self.project = self.root / 'project'
        (self.project / 'local').mkdir(parents=True)
        (self.project / 'requirements.txt').write_text('capstone==5.0.6\n')
        for module in (builder_cli, build_app):
            patcher = patch.object(module, 'ROOT', self.project)
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_cli(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = builder_cli.main(list(argv))
        found = [json.loads(line[len(PREFIX):]) for line in out.getvalue().splitlines() if line.startswith(PREFIX)]
        return code, found

    def folder(self):
        folder = self.root / 'my game "copy"'
        (folder / 'DATA').mkdir(parents=True)
        (folder / 'SAVEDATA').mkdir()
        (folder / 'DATA/x').write_bytes(b'x')
        (folder / 'SAVEDATA/y').write_bytes(b'yy')
        (folder / 'NFSHS.ICO').write_bytes(b'icon')
        return folder

    def test_check_game_rejects_bad_copy_without_fetching_or_writing(self):
        folder = self.folder()
        before = snapshot(folder)
        with patch.object(builder_cli.downloads, 'fetch') as fetch:
            code, found = self.run_cli('check-game', '--cache', str(self.cache), '--', str(folder))
        self.assertEqual(code, 1)
        self.assertEqual(found[-1]['reason'], 'assets')
        self.assertEqual(found[-1]['error'], game_source.MESSAGES['assets'])
        self.assertEqual(found[-1]['detected']['files'], 2)
        fetch.assert_not_called()
        self.assertEqual(snapshot(folder), before)
        self.assertFalse(self.cache.exists())

    def test_check_game_accepts_supported_copy(self):
        folder = self.folder()
        with patch.object(builder_cli.game_source, 'verify_source', return_value=dict(game_source.SOURCE)):
            code, found = self.run_cli('check-game', '--', str(folder))
        self.assertEqual(code, 0)
        self.assertEqual(found[-1], {'game': 'ok', 'version': game_source.SUPPORTED['release'],
                                     'summary': 'European Road Challenge CD, 1,328 files verified'})

    def test_check_game_reports_missing_link_and_wrong_type(self):
        sub = self.root / 'disc.sub'
        sub.write_bytes(b'x')
        link = self.root / 'link'
        link.symlink_to(self.folder())
        for path, reason in ((self.root / 'gone', 'missing'), (link, 'link'), (sub, 'unsupported-type')):
            code, found = self.run_cli('check-game', '--', str(path))
            self.assertEqual(code, 1)
            self.assertEqual(found[-1]['reason'], reason)
            self.assertNotIn('detected', found[-1])

    def test_check_game_image_extracts_outside_the_image_folder(self):
        images = self.root / 'images'
        images.mkdir()
        iso = images / '-disc (EU).iso'
        iso.write_bytes(image(raw=False))
        before = snapshot(images)
        seen = []

        def verify(folder):
            seen.append(Path(folder))
            self.assertTrue((Path(folder) / 'Simulation/cop356_german.crp').is_file())
            return dict(game_source.SOURCE)

        with patch.object(builder_cli.game_source, 'verify_source', side_effect=verify):
            code, found = self.run_cli('check-game', '--', str(iso))
        self.assertEqual(code, 0, found)
        self.assertTrue(seen[0].is_relative_to(self.project / 'local'))
        self.assertEqual(snapshot(images), before)
        self.assertEqual([p.name for p in (self.project / 'local').iterdir()], [])

    def test_tools_status_missing_then_ready(self):
        self.assertEqual(self.run_cli('tools', 'status', '--cache', str(self.cache)), (0, [{'tools': 'missing'}]))
        environment = build_app.environment_path(self.cache)
        (environment / 'bin').mkdir(parents=True)
        (environment / 'bin/python').write_text('')
        self.assertEqual(self.run_cli('tools', 'status', '--cache', str(self.cache))[1], [{'tools': 'missing'}])
        stamp = hashlib.sha256((self.project / 'requirements.txt').read_bytes()).hexdigest()
        (environment / '.requirements-sha256').write_text(stamp)
        self.assertEqual(self.run_cli('tools', 'status', '--cache', str(self.cache))[1],
                         [{'tools': 'ready', 'python': str(environment / 'bin/python')}])
        (self.project / 'requirements.txt').write_text('changed\n')
        self.assertEqual(self.run_cli('tools', 'status', '--cache', str(self.cache))[1], [{'tools': 'missing'}])

    def pinned(self):
        """Fake pinned downloads whose checksums are the contents written into the cache."""
        self.cache.mkdir(exist_ok=True)
        sources, payloads = {}, {}
        for key, name in (('veg', 'veg.7z'), ('moltenvk', 'mvk.tar'), ('glslang', 'g.tar.gz'), ('7zip', '7z.tar.xz')):
            data = name.encode()
            payloads[name] = data
            sources[key] = (name, f'https://example.invalid/{name}', hashlib.sha256(data).hexdigest())
        return sources, payloads

    def test_downloads_status_missing_damaged_ready_and_community(self):
        sources, payloads = self.pinned()
        expansion = hashlib.sha256(b'pack').hexdigest()
        with patch.object(builder_cli.build_app, 'SOURCES', sources), \
                patch.object(builder_cli.addons, 'EXPANSION_SHA256', expansion):
            status = lambda *flags: self.run_cli('downloads', 'status', *flags, '--cache', str(self.cache))[1][-1]
            self.assertEqual(status(), {'downloads': 'missing'})
            for name, data in payloads.items():
                (self.cache / name).write_bytes(data)
            self.assertEqual(status(), {'downloads': 'ready'})
            self.assertEqual(status('--community'), {'downloads': 'missing'})
            (self.cache / 'hsfull.rar').write_bytes(b'pack')
            self.assertEqual(status('--community'), {'downloads': 'ready'})
            (self.cache / 'mvk.tar').write_bytes(b'mvk.taR')
            self.assertEqual(status(), {'downloads': 'damaged', 'file': 'mvk.tar'})
            (self.cache / 'veg.7z').unlink()
            self.assertEqual(status(), {'downloads': 'damaged', 'file': 'mvk.tar'})

    def test_downloads_fetch_replaces_only_damaged_pinned_files(self):
        sources, payloads = self.pinned()
        for name, data in payloads.items():
            (self.cache / name).write_bytes(data)
        (self.cache / 'mvk.tar').write_bytes(b'damaged')
        (self.cache / 'keep.txt').write_text('mine')
        fetched = []

        def fetch(cache, name, url, sha256):
            fetched.append(name)
            target = Path(cache) / name
            if target.exists():
                self.assertEqual(hashlib.sha256(target.read_bytes()).hexdigest(), sha256)
            else:
                target.write_bytes(payloads.get(name, b'pack'))
            return target

        with patch.object(builder_cli.build_app, 'SOURCES', sources), \
                patch.object(builder_cli.downloads, 'fetch', side_effect=fetch):
            code, found = self.run_cli('downloads', 'fetch', '--cache', str(self.cache))
        self.assertEqual((code, found[-1]), (0, {'downloads': 'ready'}))
        self.assertEqual(sorted(fetched), sorted(payloads))
        self.assertEqual((self.cache / 'mvk.tar').read_bytes(), b'mvk.tar')
        self.assertEqual((self.cache / 'keep.txt').read_text(), 'mine')

    def test_downloads_fetch_failure_names_the_site(self):
        failure = build_app.DownloadFailed('hsfull.rar', 'https://www.iplounge.net/dloads/hsfull.rar', OSError('x'))
        with patch.object(builder_cli.downloads, 'fetch', side_effect=failure):
            code, found = self.run_cli('downloads', 'fetch', '--community', '--cache', str(self.cache))
        self.assertEqual(code, 1)
        self.assertIn('download from iplounge.net failed', found[-1]['error'])

    def test_supported_matches_game_source(self):
        self.assertEqual(self.run_cli('supported'), (0, [{'supported': game_source.SUPPORTED}]))

    def test_unknown_command_is_an_error_event(self):
        code, found = self.run_cli('nonsense')
        self.assertEqual(code, 2)
        self.assertIn('error', found[-1])

    def test_sigterm_removes_the_check_folder(self):
        iso = self.root / 'disc.iso'
        iso.write_bytes(image(raw=False))
        script = (
            'import sys, time\n'
            'from pathlib import Path\n'
            'sys.path.insert(0, sys.argv[1])\n'
            'from tools import builder_cli\n'
            'builder_cli.ROOT = Path(sys.argv[2])\n'
            'def slow(folder):\n'
            '    print("slow", flush=True)\n'
            '    time.sleep(60)\n'
            'builder_cli.game_source.verify_source = slow\n'
            'sys.exit(builder_cli.main(sys.argv[3:]))\n')
        process = subprocess.Popen([sys.executable, '-B', '-c', script, str(builder_cli.__file__).rsplit('/tools/', 1)[0],
                                    str(self.project), 'check-game', '--', str(iso)],
                                   stdout=subprocess.PIPE, text=True)
        try:
            for line in process.stdout:
                if line.strip() == 'slow':
                    break
            self.assertTrue(list((self.project / 'local').glob('.check-*')))
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 143)
        finally:
            if process.poll() is None:
                process.kill()
            process.stdout.close()
        self.assertEqual(list((self.project / 'local').glob('.check-*')), [])


if __name__ == '__main__':
    unittest.main()

import argparse
import contextlib
import io
import json
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import build_app

PREFIX = 'NFSIV-EVENT '


def events(stdout):
    return [json.loads(line[len(PREFIX):]) for line in stdout.splitlines() if line.startswith(PREFIX)]


class BuildAppTests(unittest.TestCase):
    def test_custom_app_and_cache_payloads_are_ignored_without_hiding_source(self):
        with tempfile.TemporaryDirectory(prefix='build ignore ') as temporary:
            root = Path(temporary)
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            shutil.copyfile(build_app.ROOT / '.gitignore', root / '.gitignore')
            cache = root / 'custom cache'
            cache.mkdir()
            (cache / '.gitignore').write_text('/existing-private\n')
            options = argparse.Namespace(game_source=root, cache=cache,
                                         output=root / 'custom/NFSIV.app', community=True, prepare_only=True)
            with patch.object(build_app, 'ROOT', root), \
                    patch.object(build_app, 'verify_source', side_effect=ValueError('stop before downloads')):
                with self.assertRaisesRegex(ValueError, 'stop before downloads'):
                    build_app.build(options)
            for relative in ('custom/NFSIV.app/Contents/MacOS/NFSIVEngine',
                             'custom/NFSIV.app/Contents/Resources/Game/data/car.viv',
                             'custom cache/addons-test/bonus/Overlay/data/car.viv',
                             'custom cache/.build-test/disc/DATA/car.viv',
                             'custom cache/python-3.14-test/bin/python',
                             'custom cache/existing-private'):
                result = subprocess.run(['git', 'check-ignore', '-q', relative], cwd=root)
                self.assertEqual(result.returncode, 0, relative)
            for relative in ('tools/build_app.py', 'custom cache/source.py'):
                result = subprocess.run(['git', 'check-ignore', '-q', relative], cwd=root)
                self.assertEqual(result.returncode, 1, relative)

    def test_output_must_have_app_extension_before_touching_cache(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            options = argparse.Namespace(game_source=root, cache=root / 'cache', output=root / 'game')
            with self.assertRaisesRegex(ValueError, r'\.app'):
                build_app.build(options)
            self.assertFalse(options.cache.exists())

    def test_prepare_only_never_translates_or_packages(self):
        with tempfile.TemporaryDirectory(prefix='build app ') as temporary:
            root = Path(temporary)
            source = root / 'original game'
            source.mkdir()
            options = argparse.Namespace(game_source=source, cache=root / 'cache',
                                         output=root / 'out/NFSIV.app', community=False, prepare_only=True)
            dependencies = (root / '7zz', root / 'veg.7z', root / 'MoltenVK', root / 'glslang')
            with patch.object(build_app, 'ROOT', root), \
                    patch.object(build_app, 'bootstrap', return_value=root / 'python'), \
                    patch.object(build_app, 'dependencies', return_value=dependencies), \
                    patch.object(build_app, 'verify_source', return_value={'sha256': 'verified'}), \
                    patch.object(build_app, 'prepare_game', return_value={'sha256': 'verified'}), \
                    patch.object(build_app.subprocess, 'run') as run:
                result = build_app.build(options)
            self.assertTrue(result.parent.is_dir())
            self.assertFalse((root / 'out').exists())
            self.assertFalse((root / 'gen').exists())
            run.assert_not_called()

    def test_full_build_passes_private_dependencies_to_existing_tools(self):
        with tempfile.TemporaryDirectory(prefix='build app ') as temporary:
            root = Path(temporary)
            source = root / 'original game'
            source.mkdir()
            options = argparse.Namespace(game_source=source, cache=root / 'cache',
                                         output=root / 'custom output/NFSIV.app', community=True, prepare_only=False)
            dependencies = (root / '7zz', root / 'veg.7z', root / 'MoltenVK', root / 'glslang')
            with patch.object(build_app, 'ROOT', root), \
                    patch.object(build_app, 'bootstrap', return_value=root / 'private python'), \
                    patch.object(build_app, 'dependencies', return_value=dependencies), \
                    patch.object(build_app, 'verify_source', return_value={'sha256': 'verified'}), \
                    patch.object(build_app, 'prepare_game', return_value={'sha256': 'verified'}), \
                    patch.object(build_app.subprocess, 'run') as run, \
                    patch.object(build_app, 'package_app', return_value=options.output) as package, \
                    patch.object(build_app, 'prepare_addons', return_value=root / 'addon library') as addons:
                self.assertEqual(build_app.build(options), options.output)
            commands = [call.args[0] for call in run.call_args_list]
            self.assertEqual([c[1] for c in commands], ['-B', '-B'])
            self.assertEqual([Path(c[2]).name for c in commands], ['prepare.py', 'compile.py'])
            self.assertEqual(run.call_args_list[1].kwargs['env']['NFSIV_GLSLANG'], str(root / 'glslang'))
            addons.assert_called_once_with(options.cache, root / '7zz')
            self.assertEqual(package.call_args.kwargs['addons'], root / 'addon library')
            self.assertEqual(package.call_args.kwargs['moltenvk'], root / 'MoltenVK')


class ProgressTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='build events ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    @contextlib.contextmanager
    def mocked_pipeline(self, package=None):
        """The mocks of the full build test, plus an image source so 'extract' runs."""
        dependencies = (self.root / '7zz', self.root / 'veg.7z', self.root / 'MoltenVK', self.root / 'glslang')
        output = self.root / 'out/NFSIV.app'

        def addons(cache, extractor):
            return Path(tempfile.mkdtemp(prefix='addons-', dir=cache))

        with patch.object(build_app, 'ROOT', self.root), \
                patch.object(build_app, 'check_toolchain'), \
                patch.object(build_app, 'extract_source'), \
                patch.object(build_app, 'bootstrap', return_value=self.root / 'python'), \
                patch.object(build_app, 'dependencies', return_value=dependencies), \
                patch.object(build_app, 'verify_source', return_value={'sha256': 'verified'}), \
                patch.object(build_app, 'prepare_game', return_value={'sha256': 'verified'}), \
                patch.object(build_app.subprocess, 'run'), \
                patch.object(build_app, 'package_app', side_effect=package, return_value=output), \
                patch.object(build_app, 'prepare_addons', side_effect=addons):
            yield output

    def main(self, *argv):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(io.StringIO()):
            code = build_app.main(list(argv))
        return code, events(out.getvalue())

    def game(self):
        image = self.root / 'input folder/-game "copy".iso'
        image.parent.mkdir(exist_ok=True)
        image.write_bytes(b'image')
        return image

    def test_progress_mode_reports_missing_game_as_event(self):
        run = subprocess.run([sys.executable, '-B', str(build_app.ROOT / 'tools/build_app.py'), '--progress',
                              '--cache', str(self.root / 'cache'), '--', '/nonexistent/game.iso'],
                             text=True, capture_output=True)
        self.assertEqual(run.returncode, 1)
        self.assertIn('error', events(run.stdout)[-1])

    def test_argument_errors_are_events_in_progress_mode(self):
        code, found = self.main('--progress', '--no-such-option')
        self.assertEqual(code, 2)
        self.assertIn('error', found[-1])

    def test_step_ids_in_order_with_and_without_community(self):
        expected = ['extract', 'verify', 'setup', 'dependencies', 'prepare', 'translate', 'compile', 'package']
        for community in (False, True):
            with self.subTest(community=community), self.mocked_pipeline() as output:
                flags = ['--community'] if community else []
                code, found = self.main('--progress', '--cache', str(self.root / 'cache'), *flags,
                                        '--', str(self.game()))
                self.assertEqual(code, 0)
                steps = [e['step'] for e in found if 'step' in e]
                want = expected[:5] + ['community'] + expected[5:] if community else expected
                self.assertEqual(steps, want)
                self.assertTrue(all(e.get('title') for e in found if 'step' in e))
                self.assertEqual(found[-1], {'done': str(output)})

    def test_folder_source_has_no_extract_step(self):
        folder = self.root / 'game folder'
        folder.mkdir()
        with self.mocked_pipeline():
            code, found = self.main('--progress', '--cache', str(self.root / 'cache'), '--', str(folder))
        self.assertEqual(code, 0)
        self.assertEqual([e['step'] for e in found if 'step' in e][0], 'verify')

    def test_setup_only_never_runs_xcrun(self):
        calls = []
        real_which = shutil.which

        def which(name, *args, **kwargs):
            calls.append(name)
            return real_which(name, *args, **kwargs)

        def record(*args, **kwargs):
            calls.append(' '.join(map(str, args[0])))
            raise AssertionError('no subprocess expected')

        python = self.root / 'venv/bin/python'
        with patch.object(build_app, 'bootstrap', return_value=python) as bootstrap, \
                patch.object(build_app.shutil, 'which', which), \
                patch.object(build_app.subprocess, 'check_output', record), \
                patch.object(build_app.subprocess, 'run', record):
            code, found = self.main('--setup-only', '--progress', '--cache', str(self.root / 'cache'))
        self.assertEqual(code, 0)
        bootstrap.assert_called_once_with(self.root / 'cache')
        self.assertFalse(any('xcrun' in call for call in calls), calls)
        self.assertEqual(found[-1], {'tools': 'ready', 'python': str(python)})

    def test_environment_name_includes_interpreter(self):
        cache = self.root / 'cache'

        def venv(command, **kwargs):
            if command[1:3] == ['-m', 'venv']:
                Path(command[3]).mkdir(parents=True)

        with patch.object(build_app.subprocess, 'run', side_effect=venv) as run:
            first = build_app.bootstrap(cache)
        environment = first.parent.parent
        self.assertRegex(environment.name, r'^python-\d+\.\d+-[0-9a-f]{12}-[0-9a-f]{8}$')
        self.assertEqual(environment, build_app.environment_path(cache))
        self.assertEqual(run.call_args_list[0].args[0][:3], [sys.executable, '-m', 'venv'])
        with patch.object(build_app.sys, 'base_prefix', str(self.root / 'another python')):
            other = build_app.environment_path(cache)
        self.assertNotEqual(other, environment)
        self.assertEqual(other.name.rsplit('-', 1)[0], environment.name.rsplit('-', 1)[0])

    def test_discard_intermediates_removes_only_this_runs_trees(self):
        cache = self.root / 'cache'
        old_game = self.root / 'local/build-game/game-old'
        old_addons = cache / 'addons-old'

        def trees():
            return (sorted(p.name for p in (self.root / 'local/build-game').iterdir()),
                    sorted(p.name for p in cache.iterdir() if p.name.startswith('addons-')))

        def broken(*args, **kwargs):
            raise ValueError('packaging failed')

        for package in (None, broken):
            with self.subTest(failing=package is not None), self.mocked_pipeline(package):
                for folder in (old_game, old_addons):
                    folder.mkdir(parents=True, exist_ok=True)
                    (folder / 'keep').write_text('x')
                code, _ = self.main('--progress', '--cache', str(cache), '--discard-intermediates',
                                    '--community', '--', str(self.game()))
                self.assertEqual(code, 1 if package else 0)
                self.assertEqual(trees(), (['game-old'], ['addons-old']))
                self.assertEqual((old_game / 'keep').read_text(), 'x')

    def test_intermediates_are_kept_by_default(self):
        cache = self.root / 'cache'
        with self.mocked_pipeline():
            code, _ = self.main('--progress', '--cache', str(cache), '--community', '--', str(self.game()))
        self.assertEqual(code, 0)
        self.assertEqual(len(list((self.root / 'local/build-game').glob('game-*'))), 1)
        self.assertEqual(len(list(cache.glob('addons-*'))), 1)

    def test_failed_subprocess_is_a_plain_error_event(self):
        with self.mocked_pipeline():
            with patch.object(build_app.subprocess, 'run',
                              side_effect=subprocess.CalledProcessError(2, ['python', 'tools/prepare.py'])):
                code, found = self.main('--progress', '--cache', str(self.root / 'cache'), '--', str(self.game()))
        self.assertEqual(code, 1)
        self.assertEqual(found[-1], {'error': build_app.STEP_FAILED})
        self.assertEqual(build_app.STEP_FAILED,
                         'This step stopped with an error. Click Copy log and include it in a bug report.')

    def test_failed_download_names_the_site(self):
        error = build_app.DownloadFailed('nfs4_modern_patch.7z', 'https://veg.by/files/nfs4/nfs4_modern_patch.7z',
                                         OSError('offline'))
        with self.mocked_pipeline():
            with patch.object(build_app, 'dependencies', side_effect=error):
                code, found = self.main('--progress', '--cache', str(self.root / 'cache'), '--', str(self.game()))
        self.assertEqual(code, 1)
        self.assertEqual(found[-1], {'error': 'The VEG Modern Patch download from veg.by failed. '
                                              'Check your internet connection and try again.'})
        community = build_app.DownloadFailed('hsfull.rar', 'https://www.iplounge.net/dloads/hsfull.rar', OSError())
        self.assertEqual(build_app.download_message(community, progress=True),
                         'The High Stakes Expansion Pack download from iplounge.net failed. Check your internet '
                         'connection and try again, or untick Include community cars and tracks.')

    def test_rejected_copy_is_an_event_with_reason_and_inventory(self):
        detected = {'files': 1327, 'bytes': 10, 'sha256': 'ab'}
        rejected = build_app.SourceRejected('assets', detected=detected)
        with self.mocked_pipeline():
            with patch.object(build_app, 'verify_source', side_effect=rejected):
                code, found = self.main('--progress', '--cache', str(self.root / 'cache'), '--', str(self.game()))
        self.assertEqual(code, 1)
        self.assertEqual(found[-1], {'error': str(rejected), 'reason': 'assets', 'detected': detected})
        with self.mocked_pipeline():
            with patch.object(build_app, 'verify_source', side_effect=build_app.SourceRejected('icon')):
                _, found = self.main('--progress', '--cache', str(self.root / 'cache'), '--', str(self.game()))
        self.assertEqual(set(found[-1]), {'error', 'reason'})

    def test_cli_rejection_prints_detected_inventory(self):
        rejected = build_app.SourceRejected('assets', detected={'files': 1327, 'bytes': 10, 'sha256': 'ab'})
        err = io.StringIO()
        with self.mocked_pipeline(), patch.object(build_app, 'verify_source', side_effect=rejected), \
                contextlib.redirect_stdout(io.StringIO()) as out, contextlib.redirect_stderr(err):
            self.assertEqual(build_app.main(['--cache', str(self.root / 'cache'), str(self.game())]), 1)
        self.assertNotIn(PREFIX, out.getvalue())
        self.assertIn('Detected: 1,327 files, 10 bytes', err.getvalue())

    def test_unexpected_exception_is_an_event_with_its_type(self):
        with self.mocked_pipeline():
            with patch.object(build_app, 'verify_source', side_effect=KeyError('x')):
                code, found = self.main('--progress', '--cache', str(self.root / 'cache'), '--', str(self.game()))
        self.assertEqual(code, 1)
        self.assertEqual(found[-1], {'error': 'Unexpected error (KeyError). '
                                              'Click Copy log and include it in a bug report.'})

    def test_xcode_licence_failure_is_plain(self):
        failure = subprocess.CompletedProcess(['xcrun'], 69, '', 'You have not agreed to the Xcode license agreements.')
        with patch.object(build_app.shutil, 'which', return_value='/usr/bin/xcrun'), \
                patch.object(build_app.subprocess, 'run', return_value=failure):
            with self.assertRaisesRegex(ValueError, 'Open Xcode once to accept its licence'):
                build_app.check_toolchain()

    def test_sigterm_unwinds_temporary_directories(self):
        cache = self.root / 'cache'
        game = self.game()
        script = (
            'import sys, time\n'
            'from pathlib import Path\n'
            'sys.path.insert(0, sys.argv[1])\n'
            'from tools import build_app\n'
            'build_app.ROOT = Path(sys.argv[2])\n'
            'build_app.check_toolchain = lambda: None\n'
            'def slow(source, destination):\n'
            '    destination.mkdir(parents=True)\n'
            '    (destination / "partial").write_text("x")\n'
            '    print("slow", flush=True)\n'
            '    time.sleep(60)\n'
            'build_app.extract_source = slow\n'
            'sys.exit(build_app.main(sys.argv[3:]))\n')
        process = subprocess.Popen([sys.executable, '-B', '-c', script, str(build_app.ROOT), str(self.root),
                                    '--progress', '--cache', str(cache), '--', str(game)],
                                   stdout=subprocess.PIPE, text=True)
        try:
            for line in process.stdout:
                if line.strip() == 'slow':
                    break
            self.assertTrue(list(cache.glob('.build-*')))
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 143)
        finally:
            if process.poll() is None:
                process.kill()
            process.stdout.close()
        self.assertEqual(list(cache.glob('.build-*')), [])


if __name__ == '__main__':
    unittest.main()

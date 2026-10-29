import argparse
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from tools import build_app


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


if __name__ == '__main__':
    unittest.main()

from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LauncherFilesTests(unittest.TestCase):
    def test_profiles_run_from_the_bundle_without_copies(self):
        source = (ROOT / 'launcher/main.m').read_text()
        for call in ('linkItemAtURL', 'copyItemAtURL', 'moveItemAtURL', 'clonefile'):
            self.assertIsNone(re.search(r'\b' + call, source), call)
        self.assertIn('[self url:@"Game"].path', source)

    def test_stale_prepared_copies_are_removed_and_saves_kept(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'image.h').write_text('#define IMAGE_FILE_SIZE 1\n#define IMAGE_SHA256 "fixture"\n')
            support = root / 'Support'
            prepared = support / 'Prepared' / ('a' * 64) / 'ep-car-test'
            (prepared / 'data/cars/test').mkdir(parents=True)
            (prepared / 'data/cars/test/car.viv').write_bytes(b'x' * 10000)
            bundled = root / 'NFSIV.app/Contents/Resources/Game/nfs4.exe'
            bundled.parent.mkdir(parents=True)
            bundled.write_bytes(b'bundled game')
            (prepared / 'nfs4.exe').hardlink_to(bundled)
            saves = support / 'Profiles/ep-car-test/Saves'
            saves.mkdir(parents=True)
            (saves / 'registry').write_text('progress')
            (support / 'Logs').mkdir()
            check = root / 'check.m'
            check.write_text(r'''
#define main launcher_program_main
#include "launcher/main.m"
#undef main
int main(int argc,char **argv){@autoreleasepool{
 NSURL *support=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
 removeStalePrepared(support);removeStalePrepared(support);
 Launcher *launcher=[Launcher new];launcher.resources=[NSURL fileURLWithPath:@"/Bundle/Resources"];
 if(![[launcher overlay:@"ep-car-test"].path isEqual:@"/Bundle/Resources/Addons/ep-car-test/Overlay"])return 2;
 return 0;
}}
''')
            binary = root / 'check'
            compiled = subprocess.run(['clang', '-arch', 'arm64', '-fobjc-arc', '-I', str(root),
                                       '-I', str(ROOT), str(check), '-framework', 'Cocoa', '-o', str(binary)],
                                      capture_output=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr.decode())
            result = subprocess.run([str(binary), str(support)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertIn(b'Removed the old prepared game copies', result.stderr)
            self.assertEqual(result.stderr.count(b'Removed'), 1)
            self.assertFalse((support / 'Prepared').exists())
            self.assertEqual((saves / 'registry').read_text(), 'progress')
            self.assertEqual(bundled.read_bytes(), b'bundled game')
            self.assertTrue((support / 'Logs').is_dir())

    def test_a_linked_prepared_folder_is_unlinked_without_touching_its_target(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'image.h').write_text('#define IMAGE_FILE_SIZE 1\n#define IMAGE_SHA256 "fixture"\n')
            elsewhere = root / 'Elsewhere'
            elsewhere.mkdir()
            (elsewhere / 'keep').write_text('keep')
            support = root / 'Support'
            support.mkdir()
            (support / 'Prepared').symlink_to(elsewhere)
            check = root / 'check.m'
            check.write_text(r'''
#define main launcher_program_main
#include "launcher/main.m"
#undef main
int main(int argc,char **argv){@autoreleasepool{removeStalePrepared([NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]]);return 0;}}
''')
            binary = root / 'check'
            subprocess.run(['clang', '-arch', 'arm64', '-fobjc-arc', '-I', str(root), '-I', str(ROOT),
                            str(check), '-framework', 'Cocoa', '-o', str(binary)], check=True, capture_output=True)
            subprocess.run([str(binary), str(support)], check=True, capture_output=True)
            self.assertFalse((support / 'Prepared').is_symlink())
            self.assertEqual((elsewhere / 'keep').read_text(), 'keep')

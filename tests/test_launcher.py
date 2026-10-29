from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LauncherFilesTests(unittest.TestCase):
    def test_overlay_matches_existing_case_without_mutating_hardlinked_game_or_saves(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'image.h').write_text('#define IMAGE_FILE_SIZE 1\n#define IMAGE_SHA256 "fixture"\n')
            source = root / 'check.m'
            source.write_text(r'''
#define main launcher_program_main
#include "launcher/main.m"
#undef main
int main(int argc,char **argv){@autoreleasepool{
 NSURL *root=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
 NSFileManager *files=NSFileManager.defaultManager;NSError *error=nil;
 NSURL *base=[root URLByAppendingPathComponent:@"Base"],*stage=[root URLByAppendingPathComponent:@"Prepared"],*overlay=[root URLByAppendingPathComponent:@"Overlay"];
 NSURL *original=[base URLByAppendingPathComponent:@"Data/CARS/TEST/CAR.VIV"];
 [files createDirectoryAtURL:original.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
 [@"base" writeToURL:original atomically:YES encoding:NSUTF8StringEncoding error:&error];
 NSURL *replacement=[overlay URLByAppendingPathComponent:@"data/cars/test/car.viv"];
 [files createDirectoryAtURL:replacement.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
 [@"mod" writeToURL:replacement atomically:YES encoding:NSUTF8StringEncoding error:&error];
 NSURL *saves=[root URLByAppendingPathComponent:@"Saves/career"];
 [files createDirectoryAtURL:saves.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&error];
 [@"progress" writeToURL:saves atomically:YES encoding:NSUTF8StringEncoding error:&error];
 if(!copyTree(base,stage,YES,&error))return 1;
 NSURL *resolved=overlayTarget(stage,@"data/cars/test/car.viv",&error);
 if(![resolved.path hasSuffix:@"Prepared/Data/CARS/TEST/CAR.VIV"]){fprintf(stderr,"Resolved overlay path: %s\n",resolved.path.UTF8String);return 2;}
 if(!copyTree(overlay,stage,NO,&error))return 3;
 NSString *before=[NSString stringWithContentsOfURL:original encoding:NSUTF8StringEncoding error:&error];
 NSString *after=[NSString stringWithContentsOfURL:resolved encoding:NSUTF8StringEncoding error:&error];
 NSString *saved=[NSString stringWithContentsOfURL:saves encoding:NSUTF8StringEncoding error:&error];
 if(![before isEqual:@"base"]||![after isEqual:@"mod"]||![saved isEqual:@"progress"])return 4;
 return 0;
}}
''')
            binary = root / 'check'
            compiled = subprocess.run(['clang', '-arch', 'arm64', '-fobjc-arc', '-I', str(root),
                                       '-I', str(ROOT), str(source), '-framework', 'Cocoa', '-o', str(binary)],
                                      capture_output=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr.decode())
            result = subprocess.run([str(binary), str(root)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

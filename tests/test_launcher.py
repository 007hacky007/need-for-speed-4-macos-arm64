from pathlib import Path
import os
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


class UpdateCheckTests(unittest.TestCase):
    """The launcher's once-a-day check for a newer NFSIV Builder, with a fake fetcher."""

    def test_update_check(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / 'image.h').write_text('#define IMAGE_FILE_SIZE 1\n#define IMAGE_SHA256 "fixture"\n')
            check = root / 'check.m'
            check.write_text(r'''
#define main launcher_program_main
#include "launcher/main.m"
#undef main
static NSData *release(NSString *tag){
 NSString *page=[NSString stringWithFormat:@"https://github.com/007hacky007/need-for-speed-4-macos-arm64/releases/tag/%@",tag];
 NSString *dmg=[NSString stringWithFormat:@"https://github.com/007hacky007/need-for-speed-4-macos-arm64/releases/download/%@/NFSIV-Builder.dmg",tag];
 return [NSJSONSerialization dataWithJSONObject:@{@"tag_name":tag,@"html_url":page,@"assets":@[
  @{@"name":@"NFSIV-Builder.dmg.sha256",@"browser_download_url":[dmg stringByAppendingString:@".sha256"]},
  @{@"name":@"NFSIV-Builder.dmg",@"browser_download_url":dmg}]} options:0 error:nil];
}
static void spin(void){[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];}
#define EXPECT(...) do{if(!(__VA_ARGS__)){fprintf(stderr,"line %d: %s\n",__LINE__,#__VA_ARGS__);return 1;}}while(0)
int main(int argc,char **argv){@autoreleasepool{
 EXPECT(compareVersions(@"0.10.0",@"0.9.1")==NSOrderedDescending);
 EXPECT(compareVersions(@"1.0",@"1.0.0")==NSOrderedSame);
 EXPECT(compareVersions(@"0.1.0",@"0.1.1")==NSOrderedAscending);
 EXPECT(compareVersions(@"2",@"1.9.9")==NSOrderedDescending);
 NSString *suite=[NSString stringWithUTF8String:argv[1]];
 NSUserDefaults *settings=[[NSUserDefaults alloc] initWithSuiteName:suite];
 [settings registerDefaults:@{@"CheckForUpdates":@YES}];
 __block int requests=0;__block NSURLRequest *seen=nil;__block NSData *answer=release(@"v0.3.0");
 __block NSTimeInterval clock=1000000;
 UpdateChecker *checker=[UpdateChecker new];checker.settings=settings;checker.stamp=@"0.2.0";
 checker.now=^{return [NSDate dateWithTimeIntervalSince1970:clock];};
 checker.fetcher=^(NSURLRequest *request,void (^done)(NSData *)){requests++;seen=request;done(answer);};
 __block NSDictionary *found=nil;void (^got)(NSDictionary *)=^(NSDictionary *r){found=r;};
 /* off: no request at all */
 [settings setBool:NO forKey:@"CheckForUpdates"];
 EXPECT(![checker checkThen:got]&&requests==0);
 [settings setBool:YES forKey:@"CheckForUpdates"];
 /* a Terminal build has no stamp: no request */
 checker.stamp=nil;EXPECT(![checker checkThen:got]&&requests==0);checker.stamp=@"0.2.0";
 /* the first check asks GitHub, with nothing identifying but the launcher's name */
 EXPECT([checker checkThen:got]&&requests==1);spin();
 EXPECT([seen.URL.absoluteString isEqual:@"https://api.github.com/repos/007hacky007/need-for-speed-4-macos-arm64/releases/latest"]);
 EXPECT([seen.HTTPMethod isEqual:@"GET"]&&seen.timeoutInterval==5);
 EXPECT([seen.allHTTPHeaderFields[@"User-Agent"] isEqual:@"NFSIV-Launcher"]);
 EXPECT([[NSSet setWithArray:seen.allHTTPHeaderFields.allKeys] isEqual:[NSSet setWithArray:@[@"User-Agent",@"Accept",@"Accept-Language"]]]);
 EXPECT([found[@"version"] isEqual:@"0.3.0"]&&[found[@"download"] hasSuffix:@"/v0.3.0/NFSIV-Builder.dmg"]&&[found[@"page"] hasSuffix:@"/tag/v0.3.0"]);
 /* at most once a day */
 clock+=23*3600;found=nil;EXPECT(![checker checkThen:got]&&requests==1);
 clock+=2*3600;answer=release(@"v0.2.0");EXPECT([checker checkThen:got]&&requests==2);spin();EXPECT(found==nil);
 /* failures and foreign pages are silent */
 clock+=25*3600;answer=nil;EXPECT([checker checkThen:got]);spin();EXPECT(found==nil);
 clock+=25*3600;answer=[@"{\"tag_name\":\"v9.0.0\",\"html_url\":\"https://example.com/x\"}" dataUsingEncoding:NSUTF8StringEncoding];
 EXPECT([checker checkThen:got]);spin();EXPECT(found==nil);
 /* the notice: shown for a newer release, hidden by Not now until a newer one appears */
 UpdateNotice *notice=[[UpdateNotice alloc] initWithSettings:settings];__block NSURL *opened=nil;notice.open=^(NSURL *url){opened=url;};
 EXPECT(notice.view.hidden);
 [notice show:newerRelease(release(@"v0.3.0"),@"0.2.0")];
 EXPECT(!notice.view.hidden&&[notice.text.stringValue isEqual:@"NFSIV Builder 0.3.0 is available"]);
 [notice download:nil];EXPECT([opened.lastPathComponent isEqual:@"NFSIV-Builder.dmg"]);
 [notice whatsNew:nil];EXPECT([opened.lastPathComponent isEqual:@"v0.3.0"]);
 [notice notNow:nil];EXPECT(notice.view.hidden);
 [notice show:newerRelease(release(@"v0.3.0"),@"0.2.0")];EXPECT(notice.view.hidden);
 [notice show:newerRelease(release(@"v0.4.0"),@"0.2.0")];EXPECT(!notice.view.hidden);
 [settings removePersistentDomainForName:suite];
 return 0;
}}
''')
            binary = root / 'check'
            compiled = subprocess.run(['clang', '-arch', 'arm64', '-fobjc-arc', '-I', str(root), '-I', str(ROOT),
                                       str(check), '-framework', 'Cocoa', '-o', str(binary)], capture_output=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr.decode())
            suite = f'nfsiv-update-test-{os.getpid()}'
            try:
                result = subprocess.run([str(binary), suite], capture_output=True)
            finally:
                subprocess.run(['/usr/bin/defaults', 'delete', suite], capture_output=True)
                (Path.home() / 'Library/Preferences' / (suite + '.plist')).unlink(missing_ok=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

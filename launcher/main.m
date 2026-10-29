#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#include "image.h"
#include <errno.h>
#include <stdlib.h>

static void alert(NSString *text){
 NSAlert *a=[NSAlert new];a.messageText=@"NFSIV";a.informativeText=text;[a addButtonWithTitle:@"OK"];[a runModal];
}
static NSTextField *label(NSString *text){return [NSTextField labelWithString:text];}
static NSButton *check(NSString *title,BOOL enabled){
 NSButton *b=[NSButton checkboxWithTitle:title target:nil action:nil];b.state=enabled?NSControlStateValueOn:NSControlStateValueOff;return b;
}
static BOOL identifier(NSString *value){
 if(![value isKindOfClass:NSString.class]||!value.length)return NO;
 NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-_"];
 return value.length<=64&&[value rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound;
}
static NSURL *overlayTarget(NSURL *root,NSString *relative,NSError **error){
 NSFileManager *files=NSFileManager.defaultManager;NSURL *target=root;
 for(NSString *component in relative.pathComponents){
  NSError *problem=nil;NSArray<NSURL *> *entries=[files contentsOfDirectoryAtURL:target includingPropertiesForKeys:nil options:0 error:&problem];
  if(!entries&&[files fileExistsAtPath:target.path]){if(error)*error=problem;return nil;}
  NSURL *match=nil;
  for(NSURL *entry in entries)if([entry.lastPathComponent caseInsensitiveCompare:component]==NSOrderedSame){
   if(match){if(error)*error=[NSError errorWithDomain:@"NFSIV" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Prepared files have ambiguous filename casing."}];return nil;}
   match=entry;
  }
  target=match?:[target URLByAppendingPathComponent:component];
 }
 return target;
}
static BOOL copyTree(NSURL *source,NSURL *destination,BOOL links,NSError **error){
 char *canonical=realpath(source.fileSystemRepresentation,NULL);
 if(!canonical){if(error)*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];return NO;}
 source=[NSURL fileURLWithFileSystemRepresentation:canonical isDirectory:YES relativeToURL:nil];free(canonical);
 NSFileManager *files=NSFileManager.defaultManager;
 if(![files createDirectoryAtURL:destination withIntermediateDirectories:YES attributes:nil error:error])return NO;
 __block NSError *walkError=nil;
 NSDirectoryEnumerator *walk=[files enumeratorAtURL:source includingPropertiesForKeys:@[NSURLIsDirectoryKey,NSURLIsRegularFileKey,NSURLIsSymbolicLinkKey] options:0 errorHandler:^BOOL(NSURL *url,NSError *problem){(void)url;walkError=problem;return NO;}];
 if(!walk){if(error)*error=[NSError errorWithDomain:@"NFSIV" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot read the prepared game files."}];return NO;}
 for(NSURL *url in walk){
  NSNumber *directory=nil,*regular=nil,*symlink=nil;
  [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:error];
  [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:error];
  [url getResourceValue:&symlink forKey:NSURLIsSymbolicLinkKey error:error];
  if(symlink.boolValue||(!directory.boolValue&&!regular.boolValue)){
   if(error)*error=[NSError errorWithDomain:@"NFSIV" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Prepared game files must be regular files and directories."}];return NO;
  }
  NSString *relative=[url.path substringFromIndex:source.path.length+1];NSURL *target=links?[destination URLByAppendingPathComponent:relative]:overlayTarget(destination,relative,error);
  if(!target)return NO;
  if(directory.boolValue){if(![files createDirectoryAtURL:target withIntermediateDirectories:YES attributes:nil error:error])return NO;continue;}
  if([files fileExistsAtPath:target.path]&&![files removeItemAtURL:target error:error])return NO;
  if(links&&[files linkItemAtURL:url toURL:target error:nil])continue;
  if(![files copyItemAtURL:url toURL:target error:error])return NO;
 }
 if(walkError){if(error)*error=walkError;return NO;}
 return YES;
}

@interface Launcher : NSObject <NSApplicationDelegate,NSWindowDelegate>
@property NSWindow *window;
@property NSPopUpButton *resolution,*renderer,*content;
@property NSButton *fullscreen,*audio,*movies,*silent,*depth,*playButton;
@property NSTextField *status;
@property NSURL *resources,*support,*logs,*selectedSave;
@property NSArray<NSDictionary *> *profiles;
@property NSTask *game;
@property NSString *buildID;
@end
@implementation Launcher
- (NSURL *)url:(NSString *)path {return [self.resources URLByAppendingPathComponent:path];}
- (BOOL)validGame{
 NSData *data=[NSData dataWithContentsOfURL:[self url:@"linked.exe"] options:NSDataReadingMappedIfSafe error:nil];
 if(data.length!=IMAGE_FILE_SIZE)return NO;
 unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
 NSMutableString *hash=[NSMutableString new];for(unsigned i=0;i<sizeof digest;i++)[hash appendFormat:@"%02x",digest[i]];
 return [hash isEqualToString:@IMAGE_SHA256]&&[NSFileManager.defaultManager fileExistsAtPath:[self url:@"Game/data"].path];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification{
 (void)notification;self.resources=NSBundle.mainBundle.resourceURL;
 if(![self validGame]){alert(@"Game files are missing or do not match this build. Build the app again with ./build.sh and your own supported game copy.");[NSApp terminate:nil];return;}
 NSFileManager *files=NSFileManager.defaultManager;
 self.support=[[files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"NFSIV" isDirectory:YES];
 self.logs=[self.support URLByAppendingPathComponent:@"Logs" isDirectory:YES];NSError *error=nil;
 if(![files createDirectoryAtURL:self.logs withIntermediateDirectories:YES attributes:nil error:&error]){alert(error.localizedDescription);[NSApp terminate:nil];return;}
 NSData *manifest=[NSData dataWithContentsOfURL:[self url:@"Addons/catalog.json"]];
 NSDictionary *catalog=manifest?[NSJSONSerialization JSONObjectWithData:manifest options:0 error:nil]:nil;
 if(![catalog isKindOfClass:NSDictionary.class])catalog=nil;
 NSMutableArray *profiles=[NSMutableArray arrayWithObject:@{@"id":@"original",@"name":@"Original cars and tracks"}];
 NSArray *items=[catalog[@"profiles"] isKindOfClass:NSArray.class]?catalog[@"profiles"]:@[];
 NSMutableSet *used=[NSMutableSet setWithObject:@"original"];BOOL invalid=NO;
 for(NSDictionary *item in items){
  if(![item isKindOfClass:NSDictionary.class]||!identifier(item[@"id"])||[used containsObject:item[@"id"]]||![item[@"name"] isKindOfClass:NSString.class]||![item[@"name"] length]){invalid=YES;break;}
  if(![files fileExistsAtPath:[self url:[NSString stringWithFormat:@"Addons/%@/Overlay",item[@"id"]]].path]){invalid=YES;break;}
  [used addObject:item[@"id"]];[profiles addObject:item];
 }
 NSString *build=catalog[@"build_id"];
 NSCharacterSet *hex=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
 BOOL validID=[build isKindOfClass:NSString.class]&&build.length==64&&[build rangeOfCharacterFromSet:hex.invertedSet].location==NSNotFound;
 if(invalid||(profiles.count>1&&!validID)){alert(@"The community content catalog is invalid. Rebuild the app to prepare it again.");[NSApp terminate:nil];return;}
 self.profiles=profiles;self.buildID=validID?build:@IMAGE_SHA256;
 NSUserDefaults *settings=NSUserDefaults.standardUserDefaults;
 [settings registerDefaults:@{@"Resolution":@"1280x960",@"Renderer":@"vulkan",@"Fullscreen":@YES,@"Audio":@YES,@"Movies":@YES,@"SilentPatch":@YES,@"DepthFix":@YES,@"Content":@"original"}];
 self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,560,580) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
 self.window.title=@"NFSIV";self.window.delegate=self;self.window.releasedWhenClosed=NO;
 NSStackView *stack=[NSStackView new];stack.orientation=NSUserInterfaceLayoutOrientationVertical;stack.alignment=NSLayoutAttributeLeading;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=NO;
 [self.window.contentView addSubview:stack];
 [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:22],[stack.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-22],[stack.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:22],[stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.window.contentView.bottomAnchor constant:-18]]];
 NSTextField *title=label(@"Need for Speed IV");title.font=[NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];[stack addArrangedSubview:title];
 [stack addArrangedSubview:label(@"High Stakes / Road Challenge - Version 4.50")];
 self.resolution=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
 for(NSString *mode in @[@"640x480",@"800x600",@"1024x768",@"1280x960",@"1600x1200",@"1920x1440",@"2560x1920",@"2880x2160",@"4096x3072"])[self.resolution addItemWithTitle:mode];
 [self.resolution selectItemWithTitle:[settings stringForKey:@"Resolution"]];if(!self.resolution.selectedItem)[self.resolution selectItemAtIndex:3];
 self.renderer=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];[self.renderer addItemsWithTitles:@[@"Vulkan",@"Metal"]];[self.renderer selectItemAtIndex:[[settings stringForKey:@"Renderer"] isEqualToString:@"metal"]?1:0];
 self.content=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
 for(NSDictionary *item in self.profiles){[self.content addItemWithTitle:item[@"name"]];self.content.lastItem.representedObject=item[@"id"];}
 for(NSMenuItem *item in self.content.itemArray)if([item.representedObject isEqual:[settings stringForKey:@"Content"]])[self.content selectItem:item];
 NSGridView *grid=[NSGridView gridViewWithViews:@[@[label(@"Race resolution"),self.resolution],@[label(@"Renderer"),self.renderer],@[label(@"Game content"),self.content]]];grid.rowSpacing=9;grid.columnSpacing=18;[stack addArrangedSubview:grid];
 [self.content.widthAnchor constraintEqualToConstant:300].active=YES;self.content.enabled=self.profiles.count>1;
 self.fullscreen=check(@"Fullscreen",[settings boolForKey:@"Fullscreen"]);self.audio=check(@"Enable audio",[settings boolForKey:@"Audio"]);self.movies=check(@"Play intro movies",[settings boolForKey:@"Movies"]);
 self.silent=check(@"SilentPatch input fixes",[settings boolForKey:@"SilentPatch"]);self.depth=check(@"Projected headlights depth correction",[settings boolForKey:@"DepthFix"]);
 for(NSButton *button in @[self.fullscreen,self.audio,self.movies,self.silent,self.depth])[stack addArrangedSubview:button];
 NSTextField *note=label(@"Modern Patch 0.1.0 is required. Music and effects volume\ncan be adjusted in the game's Audio menu.");note.font=[NSFont systemFontOfSize:11];note.textColor=NSColor.secondaryLabelColor;[stack addArrangedSubview:note];
 self.status=label(@"Ready");self.status.font=[NSFont systemFontOfSize:11];[stack addArrangedSubview:self.status];
 self.playButton=[NSButton buttonWithTitle:@"Play" target:self action:@selector(play:)];self.playButton.keyEquivalent=@"\r";
 NSButton *saves=[NSButton buttonWithTitle:@"Open Saves" target:self action:@selector(openSaves:)];NSButton *logs=[NSButton buttonWithTitle:@"Open Logs" target:self action:@selector(openLogs:)];
 NSStackView *buttons=[NSStackView stackViewWithViews:@[self.playButton,saves,logs]];buttons.spacing=10;[stack addArrangedSubview:buttons];
 NSMenu *menu=[NSMenu new];NSMenuItem *app=[NSMenuItem new];[menu addItem:app];NSMenu *appMenu=[NSMenu new];app.submenu=appMenu;[appMenu addItemWithTitle:@"Quit NFSIV" action:@selector(terminate:) keyEquivalent:@"q"];NSApp.mainMenu=menu;
 [self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
 if([NSProcessInfo.processInfo.arguments containsObject:@"--play"])[self play:nil];
}
- (NSURL *)preparedGame:(NSString *)profile error:(NSError **)error{
 if([profile isEqualToString:@"original"])return [self url:@"Game"];
 NSFileManager *files=NSFileManager.defaultManager;
 NSURL *parent=[[self.support URLByAppendingPathComponent:@"Prepared"] URLByAppendingPathComponent:self.buildID];
 NSURL *destination=[parent URLByAppendingPathComponent:profile];
 if([files fileExistsAtPath:[destination URLByAppendingPathComponent:@".complete"].path])return destination;
 if(![files createDirectoryAtURL:parent withIntermediateDirectories:YES attributes:nil error:error])return nil;
 NSURL *stage=[parent URLByAppendingPathComponent:[@".prepare-" stringByAppendingString:NSUUID.UUID.UUIDString]];
 if(!copyTree([self url:@"Game"],stage,YES,error)||!copyTree([self url:[NSString stringWithFormat:@"Addons/%@/Overlay",profile]],stage,NO,error)){
  [files removeItemAtURL:stage error:nil];return nil;
 }
 if(![NSData.data writeToURL:[stage URLByAppendingPathComponent:@".complete"] options:NSDataWritingAtomic error:error]){[files removeItemAtURL:stage error:nil];return nil;}
 if(![files moveItemAtURL:stage toURL:destination error:error]){[files removeItemAtURL:stage error:nil];return nil;}
 return destination;
}
- (void)play:(id)sender{
 (void)sender;if(self.game)return;
 NSUserDefaults *settings=NSUserDefaults.standardUserDefaults;
 NSString *profile=self.content.selectedItem.representedObject?:@"original";
 NSString *resolution=self.resolution.titleOfSelectedItem?:@"1280x960";
 NSString *renderer=self.renderer.indexOfSelectedItem==1?@"metal":@"vulkan";
 [settings setObject:resolution forKey:@"Resolution"];[settings setObject:renderer forKey:@"Renderer"];[settings setObject:profile forKey:@"Content"];
 [settings setBool:self.fullscreen.state==NSControlStateValueOn forKey:@"Fullscreen"];[settings setBool:self.audio.state==NSControlStateValueOn forKey:@"Audio"];[settings setBool:self.movies.state==NSControlStateValueOn forKey:@"Movies"];[settings setBool:self.silent.state==NSControlStateValueOn forKey:@"SilentPatch"];[settings setBool:self.depth.state==NSControlStateValueOn forKey:@"DepthFix"];
 self.status.stringValue=@"Preparing game files...";[self.window displayIfNeeded];NSError *error=nil;
 NSURL *game=[self preparedGame:profile error:&error];if(!game){alert(error.localizedDescription?:@"Cannot prepare the selected content.");self.status.stringValue=@"Ready";return;}
 NSFileManager *files=NSFileManager.defaultManager;
 self.selectedSave=[[[self.support URLByAppendingPathComponent:@"Profiles"] URLByAppendingPathComponent:profile] URLByAppendingPathComponent:@"Saves"];
 if(![files createDirectoryAtURL:self.selectedSave withIntermediateDirectories:YES attributes:nil error:&error]){alert(error.localizedDescription);return;}
 NSString *ini=[NSString stringWithFormat:@"[NFS4]\nLanguage=english\nNoMovies=%d\nThrashDriver=dx7\nSingleProcAffinity=0\nOwnHeapLimitMb=64\nNoErrorReporting=0\nVariant=0\n",self.movies.state==NSControlStateValueOn?0:1];
 if(![ini writeToURL:[self.selectedSave URLByAppendingPathComponent:@"nfs4.ini"] atomically:YES encoding:NSUTF8StringEncoding error:&error]){alert(error.localizedDescription);return;}
 NSDateFormatter *format=[NSDateFormatter new];format.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];format.dateFormat=@"yyyyMMdd-HHmmss-SSS";
 NSURL *log=[self.logs URLByAppendingPathComponent:[NSString stringWithFormat:@"NFSIV-%@.log",[format stringFromDate:NSDate.date]]];
 if(![files createFileAtPath:log.path contents:nil attributes:nil]){alert(@"Cannot create the game log.");return;}
 NSFileHandle *output=[NSFileHandle fileHandleForWritingAtPath:log.path];
 NSTask *task=[NSTask new];task.executableURL=[NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"NFSIVEngine"];
 task.arguments=@[[self url:@"linked.exe"].path,game.path];task.currentDirectoryURL=self.support;
 NSMutableDictionary *environment=[NSProcessInfo.processInfo.environment mutableCopy];
 BOOL diagnostics=[NSProcessInfo.processInfo.arguments containsObject:@"--diagnostics"];
 if(!diagnostics)for(NSString *key in environment.allKeys.copy)if([key hasPrefix:@"NFSIV_"])[environment removeObjectForKey:key];
 environment[@"NFSIV_SAVE_DIR"]=self.selectedSave.path;environment[@"NFSIV_REGFILE"]=[self.selectedSave URLByAppendingPathComponent:@"registry"].path;
 environment[@"NFSIV_RESOLUTION"]=resolution;environment[@"NFSIV_RENDERER"]=renderer;environment[@"NFSIV_FULLSCREEN"]=[settings boolForKey:@"Fullscreen"]?@"1":@"0";
 environment[@"NFSIV_AUDIO"]=[settings boolForKey:@"Audio"]?@"1":@"0";environment[@"NFSIV_SILENTPATCH"]=[settings boolForKey:@"SilentPatch"]?@"1":@"0";environment[@"NFSIV_DEPTH_FIX"]=[settings boolForKey:@"DepthFix"]?@"1":@"0";
 if(!diagnostics||!environment[@"NFSIV_TIMEOUT"])environment[@"NFSIV_TIMEOUT"]=@"0";
 task.environment=environment;task.standardOutput=output;task.standardError=output;
 __weak Launcher *weakSelf=self;
 task.terminationHandler=^(NSTask *ended){dispatch_async(dispatch_get_main_queue(), ^{
  [output closeFile];Launcher *owner=weakSelf;owner.game=nil;owner.playButton.enabled=YES;owner.status.stringValue=@"Ready";
  [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];[owner.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
  if(ended.terminationStatus)alert(@"The game stopped unexpectedly. Open Logs to see the diagnostic log.");
 });};
 if(![task launchAndReturnError:&error]){[output closeFile];alert(error.localizedDescription);self.status.stringValue=@"Ready";return;}
 self.game=task;self.playButton.enabled=NO;self.status.stringValue=@"Game running";[self.window orderOut:nil];[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}
- (void)openSaves:(id)sender{(void)sender;NSString *profile=self.content.selectedItem.representedObject?:@"original";NSURL *path=[[[self.support URLByAppendingPathComponent:@"Profiles"] URLByAppendingPathComponent:profile] URLByAppendingPathComponent:@"Saves"];[NSFileManager.defaultManager createDirectoryAtURL:path withIntermediateDirectories:YES attributes:nil error:nil];[NSWorkspace.sharedWorkspace openURL:path];}
- (void)openLogs:(id)sender{(void)sender;[NSWorkspace.sharedWorkspace openURL:self.logs];}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application{(void)application;return self.game==nil;}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender{(void)sender;return self.game?NSTerminateCancel:NSTerminateNow;}
@end
int main(void){@autoreleasepool{
 if([NSProcessInfo.processInfo.arguments containsObject:@"--check"]){
  Launcher *check=[Launcher new];check.resources=NSBundle.mainBundle.resourceURL;
  if(![check validGame]){fputs("Prepared game data does not match this build\n",stderr);return 1;}
  puts("Prepared game checksum verified");return 0;
 }
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
 static Launcher *delegate;delegate=[Launcher new];NSApp.delegate=delegate;[NSApp run];
}return 0;}

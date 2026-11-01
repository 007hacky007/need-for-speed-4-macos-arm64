#import <Cocoa/Cocoa.h>
#import <CommonCrypto/CommonDigest.h>
#include "image.h"

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
/* Earlier versions ran a content profile from a copy of the game folder in
 * Application Support/NFSIV/Prepared.  Every profile now runs straight from
 * the bundle, so that copy is only wasted space: remove it (only that folder). */
static void removeStalePrepared(NSURL *support){
 NSURL *prepared=[support URLByAppendingPathComponent:@"Prepared" isDirectory:YES];
 NSFileManager *files=NSFileManager.defaultManager;
 NSDictionary *attributes=[files attributesOfItemAtPath:prepared.path error:nil];
 if(!attributes)return;
 BOOL link=[attributes.fileType isEqualToString:NSFileTypeSymbolicLink];
 NSArray *keys=@[NSURLIsRegularFileKey,NSURLTotalFileAllocatedSizeKey,NSURLFileResourceIdentifierKey];
 NSMutableSet *seen=[NSMutableSet new];unsigned long long bytes=0,count=0;
 for(NSURL *url in link?@[]:[files enumeratorAtURL:prepared includingPropertiesForKeys:keys options:0 errorHandler:nil]){
  NSDictionary *values=[url resourceValuesForKeys:keys error:nil];
  if(![values[NSURLIsRegularFileKey] boolValue])continue;
  count++;id identity=values[NSURLFileResourceIdentifierKey];
  if(identity&&[seen containsObject:identity])continue;
  if(identity)[seen addObject:identity];
  bytes+=[values[NSURLTotalFileAllocatedSizeKey] unsignedLongLongValue];
 }
 NSError *error=nil;
 if([files removeItemAtURL:prepared error:&error])fprintf(stderr,"Removed the old prepared game copies in %s: %llu files, %.1f MB allocated\n",prepared.path.fileSystemRepresentation,count,bytes/1048576.0);
 else fprintf(stderr,"Cannot remove the old prepared game copies in %s: %s\n",prepared.path.fileSystemRepresentation,error.localizedDescription.UTF8String);
}

@interface Launcher : NSObject <NSApplicationDelegate,NSWindowDelegate>
@property NSWindow *window;
@property NSPopUpButton *resolution,*renderer,*content;
@property NSButton *fullscreen,*audio,*movies,*silent,*depth,*playButton;
@property NSTextField *status;
@property NSURL *resources,*support,*logs,*selectedSave;
@property NSArray<NSDictionary *> *profiles;
@property NSTask *game;
@end
@implementation Launcher
- (NSURL *)url:(NSString *)path {return [self.resources URLByAppendingPathComponent:path];}
- (NSURL *)overlay:(NSString *)profile{return [self url:[NSString stringWithFormat:@"Addons/%@/Overlay",profile]];}
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
 NSURL *support=self.support;dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{removeStalePrepared(support);});
 NSData *manifest=[NSData dataWithContentsOfURL:[self url:@"Addons/catalog.json"]];
 NSDictionary *catalog=manifest?[NSJSONSerialization JSONObjectWithData:manifest options:0 error:nil]:nil;
 if(![catalog isKindOfClass:NSDictionary.class])catalog=nil;
 NSMutableArray *profiles=[NSMutableArray arrayWithObject:@{@"id":@"original",@"name":@"Original cars and tracks"}];
 NSArray *items=[catalog[@"profiles"] isKindOfClass:NSArray.class]?catalog[@"profiles"]:@[];
 NSMutableSet *used=[NSMutableSet setWithObject:@"original"];BOOL invalid=NO;
 for(NSDictionary *item in items){
  if(![item isKindOfClass:NSDictionary.class]||!identifier(item[@"id"])||[used containsObject:item[@"id"]]||![item[@"name"] isKindOfClass:NSString.class]||![item[@"name"] length]){invalid=YES;break;}
  BOOL folder=NO;
  if(![files fileExistsAtPath:[self overlay:item[@"id"]].path isDirectory:&folder]||!folder){invalid=YES;break;}
  [used addObject:item[@"id"]];[profiles addObject:item];
 }
 if(invalid){alert(@"The community content catalog is invalid. Rebuild the app to prepare it again.");[NSApp terminate:nil];return;}
 self.profiles=profiles;
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
- (void)play:(id)sender{
 (void)sender;if(self.game)return;
 NSUserDefaults *settings=NSUserDefaults.standardUserDefaults;
 NSString *profile=self.content.selectedItem.representedObject?:@"original";
 NSString *resolution=self.resolution.titleOfSelectedItem?:@"1280x960";
 NSString *renderer=self.renderer.indexOfSelectedItem==1?@"metal":@"vulkan";
 [settings setObject:resolution forKey:@"Resolution"];[settings setObject:renderer forKey:@"Renderer"];[settings setObject:profile forKey:@"Content"];
 [settings setBool:self.fullscreen.state==NSControlStateValueOn forKey:@"Fullscreen"];[settings setBool:self.audio.state==NSControlStateValueOn forKey:@"Audio"];[settings setBool:self.movies.state==NSControlStateValueOn forKey:@"Movies"];[settings setBool:self.silent.state==NSControlStateValueOn forKey:@"SilentPatch"];[settings setBool:self.depth.state==NSControlStateValueOn forKey:@"DepthFix"];
 NSError *error=nil;NSFileManager *files=NSFileManager.defaultManager;
 self.selectedSave=[[[self.support URLByAppendingPathComponent:@"Profiles"] URLByAppendingPathComponent:profile] URLByAppendingPathComponent:@"Saves"];
 if(![files createDirectoryAtURL:self.selectedSave withIntermediateDirectories:YES attributes:nil error:&error]){alert(error.localizedDescription);return;}
 NSString *ini=[NSString stringWithFormat:@"[NFS4]\nLanguage=english\nNoMovies=%d\nThrashDriver=dx7\nSingleProcAffinity=0\nOwnHeapLimitMb=64\nNoErrorReporting=0\nVariant=0\n",self.movies.state==NSControlStateValueOn?0:1];
 if(![ini writeToURL:[self.selectedSave URLByAppendingPathComponent:@"nfs4.ini"] atomically:YES encoding:NSUTF8StringEncoding error:&error]){alert(error.localizedDescription);return;}
 NSDateFormatter *format=[NSDateFormatter new];format.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];format.dateFormat=@"yyyyMMdd-HHmmss-SSS";
 NSURL *log=[self.logs URLByAppendingPathComponent:[NSString stringWithFormat:@"NFSIV-%@.log",[format stringFromDate:NSDate.date]]];
 if(![files createFileAtPath:log.path contents:nil attributes:nil]){alert(@"Cannot create the game log.");return;}
 NSFileHandle *output=[NSFileHandle fileHandleForWritingAtPath:log.path];
 NSTask *task=[NSTask new];task.executableURL=[NSBundle.mainBundle.executableURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"NFSIVEngine"];
 // Every profile runs straight from the bundle: the game folder is Resources/Game and a
 // community profile's overlay inside Resources/Addons is read first. Nothing is copied.
 NSMutableArray *arguments=[NSMutableArray arrayWithObjects:[self url:@"linked.exe"].path,[self url:@"Game"].path,nil];
 if(![profile isEqualToString:@"original"])[arguments addObject:[self overlay:profile].path];
 task.arguments=arguments;task.currentDirectoryURL=self.support;
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

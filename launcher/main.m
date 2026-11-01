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

/* --- Update check -----------------------------------------------------------
 * New features come only with a new NFSIV Builder, so the launcher of an app the Builder
 * stamped (NFSBuilderVersion) asks GitHub at most once a day, in the background, whether a
 * newer Builder is out, and offers its page and disk image in the browser. It never downloads
 * or runs anything itself. With "Check for updates" off it makes no request at all. */
static NSString *const UpdateReleaseURL=@"https://api.github.com/repos/007hacky007/need-for-speed-4-macos-arm64/releases/latest";
static NSString *const UpdatePagePrefix=@"https://github.com/007hacky007/need-for-speed-4-macos-arm64/";
static NSString *const UpdateDiskImage=@"NFSIV-Builder.dmg";
static const NSTimeInterval UpdateInterval=24*60*60;
/* Numeric compare per dot-separated component ("0.10.0" > "0.9.1"); missing components are 0. */
static NSComparisonResult compareVersions(NSString *a,NSString *b){
 NSArray<NSString *> *x=[a componentsSeparatedByString:@"."],*y=[b componentsSeparatedByString:@"."];
 for(NSUInteger i=0;i<MAX(x.count,y.count);i++){
  long long p=i<x.count?x[i].longLongValue:0,q=i<y.count?y[i].longLongValue:0;
  if(p!=q)return p<q?NSOrderedAscending:NSOrderedDescending;
 }
 return NSOrderedSame;
}
static BOOL plainVersion(NSString *value){
 if(![value isKindOfClass:NSString.class]||!value.length||value.length>32)return NO;
 NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"0123456789."];
 return [value rangeOfCharacterFromSet:allowed.invertedSet].location==NSNotFound;
}
/* The release the GitHub API describes, if it is newer than `stamp`:
 * {version, page, download}; nil for anything else. */
static NSDictionary *newerRelease(NSData *data,NSString *stamp){
 NSDictionary *release=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
 if(![release isKindOfClass:NSDictionary.class])return nil;
 NSString *tag=release[@"tag_name"],*page=release[@"html_url"];
 if(![tag isKindOfClass:NSString.class]||![page isKindOfClass:NSString.class]||![page hasPrefix:UpdatePagePrefix])return nil;
 NSString *version=[tag hasPrefix:@"v"]?[tag substringFromIndex:1]:tag;
 if(!plainVersion(version)||!plainVersion(stamp)||compareVersions(version,stamp)!=NSOrderedDescending)return nil;
 NSString *download=page;
 NSArray *assets=[release[@"assets"] isKindOfClass:NSArray.class]?release[@"assets"]:@[];
 for(NSDictionary *asset in assets){
  if(![asset isKindOfClass:NSDictionary.class]||![asset[@"name"] isEqual:UpdateDiskImage])continue;
  NSString *url=asset[@"browser_download_url"];
  if([url isKindOfClass:NSString.class]&&[url hasPrefix:UpdatePagePrefix])download=url;
 }
 return @{@"version":version,@"page":page,@"download":download};
}
typedef void (^UpdateFetcher)(NSURLRequest *request,void (^done)(NSData *data));
@interface UpdateChecker : NSObject
@property NSUserDefaults *settings;
@property NSString *stamp;
@property(copy) UpdateFetcher fetcher;
@property(copy) NSDate *(^now)(void);
@end
@implementation UpdateChecker
- (instancetype)init{
 if(!(self=[super init]))return nil;
 self.settings=NSUserDefaults.standardUserDefaults;self.now=^{return NSDate.date;};
 self.fetcher=^(NSURLRequest *request,void (^done)(NSData *)){
  NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
  configuration.timeoutIntervalForRequest=5;configuration.timeoutIntervalForResource=5;
  configuration.HTTPShouldSetCookies=NO;configuration.HTTPCookieAcceptPolicy=NSHTTPCookieAcceptPolicyNever;
  configuration.URLCache=nil;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
  NSURLSession *session=[NSURLSession sessionWithConfiguration:configuration];
  [[session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
   BOOL ok=!error&&[response isKindOfClass:NSHTTPURLResponse.class]&&((NSHTTPURLResponse *)response).statusCode==200;
   done(ok?data:nil);
  }] resume];
  [session finishTasksAndInvalidate];
 };
 return self;
}
- (NSURLRequest *)request{
 NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:UpdateReleaseURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:5];
 request.HTTPMethod=@"GET";request.HTTPShouldHandleCookies=NO;
 [request setValue:@"NFSIV-Launcher" forHTTPHeaderField:@"User-Agent"];
 [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
 [request setValue:@"en" forHTTPHeaderField:@"Accept-Language"];
 return request;
}
/* -> whether a request was started; `found` gets a newer release on the main queue. Failures are silent. */
- (BOOL)checkThen:(void (^)(NSDictionary *release))found{
 if(![self.settings boolForKey:@"CheckForUpdates"]||!plainVersion(self.stamp))return NO;
 NSTimeInterval now=self.now().timeIntervalSince1970,last=[self.settings doubleForKey:@"LastUpdateCheck"];
 if(last>0&&now>=last&&now-last<UpdateInterval)return NO;
 [self.settings setDouble:now forKey:@"LastUpdateCheck"];
 NSString *stamp=self.stamp;
 self.fetcher([self request],^(NSData *data){
  NSDictionary *release=newerRelease(data,stamp);
  if(release)dispatch_async(dispatch_get_main_queue(),^{found(release);});
 });
 return YES;
}
@end
/* "NFSIV Builder X.Y.Z is available" with What's new, Download and Not now; hidden until then. */
@interface UpdateNotice : NSObject
@property NSStackView *view;
@property NSTextField *text;
@property NSDictionary *offer;
@property NSUserDefaults *settings;
@property(copy) void (^open)(NSURL *url);
@end
@implementation UpdateNotice
- (instancetype)initWithSettings:(NSUserDefaults *)settings{
 if(!(self=[super init]))return nil;
 self.settings=settings;self.open=^(NSURL *url){[NSWorkspace.sharedWorkspace openURL:url];};
 self.text=[NSTextField labelWithString:@""];self.text.font=[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
 NSButton *news=[NSButton buttonWithTitle:@"What's new" target:self action:@selector(whatsNew:)];
 NSButton *download=[NSButton buttonWithTitle:@"Download" target:self action:@selector(download:)];
 NSButton *later=[NSButton buttonWithTitle:@"Not now" target:self action:@selector(notNow:)];
 for(NSButton *button in @[news,download,later])button.controlSize=NSControlSizeSmall;
 self.view=[NSStackView stackViewWithViews:@[self.text,news,download,later]];self.view.spacing=8;self.view.hidden=YES;
 return self;
}
- (void)show:(NSDictionary *)release{
 NSString *dismissed=[self.settings stringForKey:@"DismissedUpdate"];
 if(plainVersion(dismissed)&&compareVersions(release[@"version"],dismissed)!=NSOrderedDescending)return;
 self.offer=release;self.text.stringValue=[NSString stringWithFormat:@"NFSIV Builder %@ is available",release[@"version"]];
 self.view.hidden=NO;
}
- (void)whatsNew:(id)sender{(void)sender;if(self.offer)self.open([NSURL URLWithString:self.offer[@"page"]]);}
- (void)download:(id)sender{(void)sender;if(self.offer)self.open([NSURL URLWithString:self.offer[@"download"]]);}
- (void)notNow:(id)sender{(void)sender;if(self.offer)[self.settings setObject:self.offer[@"version"] forKey:@"DismissedUpdate"];self.view.hidden=YES;}
@end

@interface Launcher : NSObject <NSApplicationDelegate,NSWindowDelegate>
@property NSWindow *window;
@property NSPopUpButton *resolution,*renderer,*content;
@property NSButton *fullscreen,*audio,*movies,*silent,*depth,*updates,*playButton;
@property UpdateChecker *checker;
@property UpdateNotice *notice;
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
 [settings registerDefaults:@{@"Resolution":@"1280x960",@"Renderer":@"vulkan",@"Fullscreen":@YES,@"Audio":@YES,@"Movies":@YES,@"SilentPatch":@YES,@"DepthFix":@YES,@"Content":@"original",@"CheckForUpdates":@YES}];
 self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,560,620) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
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
 NSString *stamp=NSBundle.mainBundle.infoDictionary[@"NFSBuilderVersion"];
 self.updates=check(@"Check for updates",[settings boolForKey:@"CheckForUpdates"]);self.updates.target=self;self.updates.action=@selector(toggleUpdates:);
 NSTextField *updateNote=label(stamp?@"Once a day the launcher asks GitHub whether a newer NFSIV Builder is out.\nOff means no network request.":@"This app was built from Terminal: updates come from building it again.");
 updateNote.font=[NSFont systemFontOfSize:11];updateNote.textColor=NSColor.secondaryLabelColor;self.updates.enabled=stamp!=nil;
 [stack addArrangedSubview:self.updates];[stack addArrangedSubview:updateNote];
 self.notice=[[UpdateNotice alloc] initWithSettings:settings];[stack addArrangedSubview:self.notice.view];
 self.checker=[UpdateChecker new];self.checker.stamp=stamp;
 self.status=label(@"Ready");self.status.font=[NSFont systemFontOfSize:11];[stack addArrangedSubview:self.status];
 self.playButton=[NSButton buttonWithTitle:@"Play" target:self action:@selector(play:)];self.playButton.keyEquivalent=@"\r";
 NSButton *saves=[NSButton buttonWithTitle:@"Open Saves" target:self action:@selector(openSaves:)];NSButton *logs=[NSButton buttonWithTitle:@"Open Logs" target:self action:@selector(openLogs:)];
 NSStackView *buttons=[NSStackView stackViewWithViews:@[self.playButton,saves,logs]];buttons.spacing=10;[stack addArrangedSubview:buttons];
 NSMenu *menu=[NSMenu new];NSMenuItem *app=[NSMenuItem new];[menu addItem:app];NSMenu *appMenu=[NSMenu new];app.submenu=appMenu;[appMenu addItemWithTitle:@"Quit NFSIV" action:@selector(terminate:) keyEquivalent:@"q"];NSApp.mainMenu=menu;
 [self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
 [self checkForUpdates];
 if([NSProcessInfo.processInfo.arguments containsObject:@"--play"])[self play:nil];
}
- (void)checkForUpdates{
 __weak UpdateNotice *notice=self.notice;
 [self.checker checkThen:^(NSDictionary *release){[notice show:release];}];
}
- (void)toggleUpdates:(id)sender{
 (void)sender;BOOL on=self.updates.state==NSControlStateValueOn;
 [NSUserDefaults.standardUserDefaults setBool:on forKey:@"CheckForUpdates"];
 if(on)[self checkForUpdates];else self.notice.view.hidden=YES;
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

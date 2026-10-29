#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "runtime.h"
#include "input.h"
#include "display.h"
#include <stdatomic.h>

static NSWindow *window;
static CAMetalLayer *layer;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static unsigned width=640,height=480;
static _Atomic long frame_count;
static _Atomic int closing;
static BOOL fullscreen_active;
static NSRect windowed_frame;
static NSWindowStyleMask windowed_style;
static NSApplicationPresentationOptions windowed_presentation;

void *host_metal_device(void){if(!device)device=MTLCreateSystemDefaultDevice();return (__bridge void *)device;}
void *host_metal_queue(void){if(!queue){host_metal_device();queue=[device newCommandQueue];}return (__bridge void *)queue;}
void *host_metal_layer(void){return (__bridge void *)layer;}
void host_frame_presented(void){atomic_fetch_add(&frame_count,1);}
void host_toggle_fullscreen(void){
    if(!window)return;
    if(!fullscreen_active){
        windowed_frame=window.frame;windowed_style=window.styleMask;
        windowed_presentation=NSApp.presentationOptions;
        fullscreen_active=YES;window.styleMask=NSWindowStyleMaskBorderless;
        NSApp.presentationOptions=NSApplicationPresentationAutoHideDock|NSApplicationPresentationAutoHideMenuBar;
        [window setFrame:(window.screen?:NSScreen.mainScreen).frame display:YES];
    }else{
        fullscreen_active=NO;window.styleMask=windowed_style;
        NSApp.presentationOptions=windowed_presentation;
        [window setFrame:windowed_frame display:YES];
    }
    window.contentView.needsLayout=YES;[window.contentView layoutSubtreeIfNeeded];
    [window makeKeyAndOrderFront:nil];
}
void host_close_window(void){atomic_store(&closing,1);}
void host_window_info(void){
    NSView *v=window.contentView.subviews.firstObject;
    fprintf(stderr,"display fullscreen=%d view=%.0fx%.0f picture=%.0f,%.0f %.0fx%.0f drawable=%.0fx%.0f game=%ux%u\n",
        fullscreen_active,window.contentView.bounds.size.width,window.contentView.bounds.size.height,
        v.frame.origin.x,v.frame.origin.y,v.frame.size.width,v.frame.size.height,layer.drawableSize.width,layer.drawableSize.height,width,height);
}

typedef struct {unsigned scan,vk;} Key;
static Key key(unsigned code){
    static const Key map[128]={
        [0]={30,'A'},[1]={31,'S'},[2]={32,'D'},[3]={33,'F'},[4]={35,'H'},[5]={34,'G'},
        [6]={44,'Z'},[7]={45,'X'},[8]={46,'C'},[9]={47,'V'},[11]={48,'B'},
        [12]={16,'Q'},[13]={17,'W'},[14]={18,'E'},[15]={19,'R'},[16]={21,'Y'},[17]={20,'T'},
        [18]={2,'1'},[19]={3,'2'},[20]={4,'3'},[21]={5,'4'},[22]={7,'6'},[23]={6,'5'},
        [24]={13,0xbb},[25]={10,'9'},[26]={8,'7'},[27]={12,0xbd},[28]={9,'8'},[29]={11,'0'},
        [30]={27,0xdd},[31]={24,'O'},[32]={22,'U'},[33]={26,0xdb},[34]={23,'I'},[35]={25,'P'},
        [36]={28,13},[37]={38,'L'},[38]={36,'J'},[39]={40,0xde},[40]={37,'K'},[41]={39,0xba},
        [42]={43,0xdc},[43]={51,0xbc},[44]={53,0xbf},[45]={49,'N'},[46]={50,'M'},[47]={52,0xbe},
        [48]={15,9},[49]={57,32},[50]={41,0xc0},[51]={14,8},[53]={1,27},
        [54]={220,0x5c},[55]={219,0x5b},[56]={42,0x10},[57]={58,0x14},[58]={56,0x12},[59]={29,0x11},
        [60]={54,0x10},[61]={184,0x12},[62]={157,0x11},
        [122]={59,112},[120]={60,113},[99]={61,114},[118]={62,115},[96]={63,116},[97]={64,117},
        [98]={65,118},[100]={66,119},[101]={67,120},[109]={68,121},[103]={87,122},[111]={88,123},
        [114]={210,0x2d},[115]={199,0x24},[116]={201,0x21},[117]={211,0x2e},[119]={207,0x23},[121]={209,0x22},
        [123]={203,0x25},[124]={205,0x27},[125]={208,0x28},[126]={200,0x26}
    };
    return code<128?map[code]:(Key){0,0};
}

@interface NFSIVView : NSView
- (void)insertText:(id)text replacementRange:(NSRange)range;
@end
@implementation NFSIVView
- (BOOL)acceptsFirstResponder{return YES;}
- (BOOL)performKeyEquivalent:(NSEvent *)event{
    if(event.keyCode==9&&(event.modifierFlags&NSEventModifierFlagCommand)){[self paste:nil];return YES;}
    return [super performKeyEquivalent:event];
}
- (void)keyDown:(NSEvent *)event{
    if(event.keyCode==103){host_toggle_fullscreen();return;}
    if(event.keyCode==9&&(event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagControl))){[self paste:nil];return;}
    if(event.keyCode==118&&(event.modifierFlags&NSEventModifierFlagOption)){[self.window performClose:nil];return;}
    Key k=key(event.keyCode);if(k.scan)input_key(k.scan,k.vk,1);
    NSString *text=event.characters;
    for(NSUInteger i=0;i<text.length;i++){unichar ch=[text characterAtIndex:i];if(ch<0xf700)input_text(ch);}
}
- (void)insertText:(id)text replacementRange:(NSRange)range{
    (void)range;
    NSString *string=[text isKindOfClass:NSAttributedString.class]?[text string]:text;
    unsigned accepted=0;uint8_t bytes[1024];
    for(NSUInteger i=0;i<string.length&&accepted<1024;i++){
        NSData *encoded=[[string substringWithRange:NSMakeRange(i,1)] dataUsingEncoding:NSWindowsCP1252StringEncoding allowLossyConversion:NO];
        if(encoded.length!=1)continue;
        unsigned ch=((const unsigned char *)encoded.bytes)[0];if(ch<32||ch==127)continue;
        bytes[accepted++]=(uint8_t)ch;
    }
    input_paste(bytes,accepted);
}
- (void)paste:(id)sender{
    (void)sender;NSString *text=[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
    if(text)[self insertText:text replacementRange:NSMakeRange(NSNotFound,0)];
}
- (void)keyUp:(NSEvent *)event{if(event.keyCode==103)return;Key k=key(event.keyCode);if(k.scan)input_key(k.scan,k.vk,0);}
- (void)flagsChanged:(NSEvent *)event{
    Key k=key(event.keyCode);if(!k.scan)return;
    NSEventModifierFlags flag=k.vk==0x10?NSEventModifierFlagShift:k.vk==0x11?NSEventModifierFlagControl:
        k.vk==0x12?NSEventModifierFlagOption:k.vk==0x14?NSEventModifierFlagCapsLock:NSEventModifierFlagCommand;
    uint8_t state[256];input_keyboard_state(state);
    input_key(k.scan,k.vk,(event.modifierFlags&flag)&&!state[k.scan]);
}
- (void)updateTrackingAreas{
    for(NSTrackingArea *area in self.trackingAreas.copy)[self removeTrackingArea:area];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds
        options:NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect owner:self userInfo:nil]];
    [super updateTrackingAreas];
}
- (void)mouse:(NSEvent *)event button:(int)button down:(int)down wheel:(int)wheel{
    NSPoint p=[self convertPoint:event.locationInWindow fromView:nil];
    int x,y;display_mouse(width,height,self.bounds.size.width,self.bounds.size.height,p.x,self.bounds.size.height-p.y,&x,&y);
    input_mouse(x,y,button,down,wheel);
}
- (void)mouseMoved:(NSEvent *)event{[self mouse:event button:-1 down:0 wheel:0];}
- (void)mouseDragged:(NSEvent *)event{[self mouseMoved:event];}
- (void)rightMouseDragged:(NSEvent *)event{[self mouseMoved:event];}
- (void)mouseDown:(NSEvent *)event{[self mouse:event button:0 down:1 wheel:0];}
- (void)mouseUp:(NSEvent *)event{[self mouse:event button:0 down:0 wheel:0];}
- (void)rightMouseDown:(NSEvent *)event{[self mouse:event button:1 down:1 wheel:0];}
- (void)rightMouseUp:(NSEvent *)event{[self mouse:event button:1 down:0 wheel:0];}
- (void)otherMouseDown:(NSEvent *)event{[self mouse:event button:(int)event.buttonNumber down:1 wheel:0];}
- (void)otherMouseUp:(NSEvent *)event{[self mouse:event button:(int)event.buttonNumber down:0 wheel:0];}
- (void)scrollWheel:(NSEvent *)event{[self mouse:event button:-1 down:0 wheel:(int)(event.scrollingDeltaY*120)];}
@end

@interface NFSIVContentView : NSView
@property(nonatomic,strong) NFSIVView *gameView;
@end
@implementation NFSIVContentView
- (instancetype)initWithFrame:(NSRect)frame{
    if((self=[super initWithFrame:frame])){
        self.wantsLayer=YES;self.layer.backgroundColor=NSColor.blackColor.CGColor;
        self.gameView=[[NFSIVView alloc] initWithFrame:self.bounds];[self addSubview:self.gameView];
    }
    return self;
}
- (void)layout{
    [super layout];
    DisplayRect r=display_fit(width,height,self.bounds.size.width,self.bounds.size.height);
    self.gameView.frame=NSMakeRect(r.x,r.y,r.w,r.h);
}
- (void)resetCursorRects{
    /* AppKit restores the normal cursor outside this view or when it loses focus. */
    static NSCursor *invisible;
    if(!invisible){NSImage *image=[[NSImage alloc] initWithSize:NSMakeSize(16,16)];
        invisible=[[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];}
    [self addCursorRect:self.bounds cursor:invisible];
}
@end

@interface NFSIVWindow : NSWindow <NSWindowDelegate>
@end
@implementation NFSIVWindow
- (BOOL)canBecomeKeyWindow { return YES; }
- (void)toggleGameFullscreen:(id)sender{(void)sender;host_toggle_fullscreen();}
- (void)windowDidBecomeKey:(NSNotification *)notification{(void)notification;input_focus(1);}
- (void)windowDidResignKey:(NSNotification *)notification{(void)notification;input_focus(0);}
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; atomic_store(&closing,1); return NO; }
@end

static void fit_window(unsigned w,unsigned h){
    NSRect available=(window.screen?:NSScreen.mainScreen).visibleFrame;
    double scale=fmin(1,fmin(available.size.width*.9/w,available.size.height*.9/h));
    [window setContentSize:NSMakeSize(w*scale,h*scale)];
}

void host_open_window(unsigned w, unsigned h){
    dispatch_sync(dispatch_get_main_queue(), ^{
        width=w; height=h;
        if (!window){
            host_metal_device();
            if (!device){ fputs("no native Metal device\n",stderr); exit(1); }
            host_metal_queue();
            window=[[NFSIVWindow alloc] initWithContentRect:NSMakeRect(0,0,w,h)
                styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered defer:NO];
            window.title=@"NFSIV"; window.delegate=(id<NSWindowDelegate>)window;
            window.collectionBehavior=NSWindowCollectionBehaviorFullScreenNone;
            window.contentMinSize=NSMakeSize(320,240);
            NFSIVContentView *content=[[NFSIVContentView alloc] initWithFrame:NSMakeRect(0,0,w,h)];
            window.contentView=content;
            layer=[CAMetalLayer layer]; layer.device=device; layer.pixelFormat=MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly=NO; layer.drawableSize=CGSizeMake(w,h);
            content.gameView.wantsLayer=YES;content.gameView.layer=layer;
            [window makeFirstResponder:content.gameView];window.acceptsMouseMovedEvents=YES;
            NSMenu *menu=[NSMenu new];NSMenuItem *appItem=[NSMenuItem new];[menu addItem:appItem];
            NSMenu *appMenu=[NSMenu new];appItem.submenu=appMenu;
            [appMenu addItemWithTitle:@"Quit NFSIV" action:@selector(performClose:) keyEquivalent:@"q"];
            NSMenuItem *viewItem=[NSMenuItem new];viewItem.title=@"View";[menu addItem:viewItem];
            NSMenu *viewMenu=[[NSMenu alloc] initWithTitle:@"View"];viewItem.submenu=viewMenu;
            NSMenuItem *full=[viewMenu addItemWithTitle:@"Toggle Full Screen" action:@selector(toggleGameFullscreen:) keyEquivalent:@"f"];
            full.target=window;full.keyEquivalentModifierMask=NSEventModifierFlagControl|NSEventModifierFlagCommand;NSApp.mainMenu=menu;
            fit_window(w,h);
            [window center]; [window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
            const char *fullscreen=getenv("NFSIV_FULLSCREEN");
            if(!fullscreen||strcmp(fullscreen,"0"))dispatch_async(dispatch_get_main_queue(), ^{host_toggle_fullscreen();});
            fprintf(stderr,"native Metal device: %s\n",device.name.UTF8String);
        }
        /* Fullscreen is a presentation size, independent of the game's current video mode. */
        layer.contentsScale=window.backingScaleFactor;
        layer.drawableSize=CGSizeMake(w,h);window.contentView.needsLayout=YES;
        [window.contentView layoutSubtreeIfNeeded];
    });
}

void metal_game_size(unsigned *w,unsigned *h){ if(w)*w=width;if(h)*h=height; }
void metal_get_cursor(int *x,int *y){
    input_cursor(x,y);
}
long metal_frames(void){ return atomic_load(&frame_count); }
long autotest_frame(void){ return metal_frames(); }
int hfr_mode_off(void){ return 1; }
int hfr_display_live(void){ return window!=nil; }
void kbd_pump(void){ void input_pump(void);input_pump(); }
void lifecycle_pump(void){
    if (atomic_exchange(&closing,0)){ void win32_post_message(uint32_t,uint32_t,uint32_t); win32_post_message(0x10,0,0); }
}
int lifecycle_may_park(void){ return 0; }
int lifecycle_game_parked(void){ return 0; }

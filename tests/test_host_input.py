from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

# Runs the real game window code with fake cursor warping, so the check never
# moves the person's mouse. Exit 77 means the Mac has no window server or Metal.
CHECK = r'''
#import <Cocoa/Cocoa.h>
static int warps,associated=1;
static void fake_warp(CGPoint p){(void)p;warps++;}
static void fake_associate(boolean_t value){associated=value;}
#define CGWarpMouseCursorPosition(p) fake_warp(p)
#define CGAssociateMouseAndMouseCursorPosition(v) fake_associate(v)
#include "runtime/host.m"
#include "runtime/input.c"
#include "runtime/display.c"
#include <pthread.h>
uint32_t win32_alloc(uint32_t size,int zero){(void)size;(void)zero;return 0;}
void win32_signal_event(uint32_t handle){(void)handle;}
static uint32_t posted[64][2];static unsigned posted_count;
void win32_post_message(uint32_t m,uint32_t wp,uint32_t lp){(void)lp;if(posted_count<64){posted[posted_count][0]=m;posted[posted_count++][1]=wp;}}
static int posted_message(uint32_t m,uint32_t wp){
 for(unsigned i=0;i<posted_count;i++)if(posted[i][0]==m&&posted[i][1]==wp)return 1;
 return 0;
}
static void type_a(void){
 posted_count=0;
 [NSApp sendEvent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
  windowNumber:window.windowNumber context:nil characters:@"a" charactersIgnoringModifiers:@"a" isARepeat:NO keyCode:0]];
 input_pump();
}
static void move(double dx,double dy){
 CGEventRef e=CGEventCreateMouseEvent(NULL,kCGEventMouseMoved,CGPointMake(10,10),kCGMouseButtonLeft);
 CGEventSetIntegerValueField(e,kCGMouseEventDeltaX,(int64_t)dx);CGEventSetIntegerValueField(e,kCGMouseEventDeltaY,(int64_t)dy);
 NSEvent *event=[NSEvent eventWithCGEvent:e];CFRelease(e);
 [window sendEvent:event];
}
static void *check(void *unused){@autoreleasepool{
 (void)unused;host_open_window(640,480);
 __block int status=0;
 dispatch_sync(dispatch_get_main_queue(),^{
  if(!window.isKeyWindow){status=77;return;}
  host_toggle_fullscreen();
  if(!fullscreen_active){status=1;return;}
  type_a();
  if(!posted_message(0x100,'A')||!posted_message(0x102,'a')){status=2;return;}
  if(associated||!warps){status=3;return;}
  int32_t state[5];move(1,1);input_mouse_state(state,sizeof state);
  motion_x=0;move(100,0);input_mouse_state(state,sizeof state);
  int expected=(int)(100*640.0/game_view.bounds.size.width);
  if(state[0]!=expected){fprintf(stderr,"one move gave dx=%d, expected %d\n",state[0],expected);status=8;return;}
  for(int i=0;i<40;i++)move(200,0);
  int x,y;input_cursor(&x,&y);
  if(x!=639){fprintf(stderr,"cursor x=%d\n",x);status=4;return;}
  input_mouse_state(state,sizeof state);
  move(200,0);move(0,-50);input_mouse_state(state,sizeof state);
  if(state[0]<=0||state[1]>=0){fprintf(stderr,"motion at edge dx=%d dy=%d\n",state[0],state[1]);status=5;return;}
  [(NFSIVWindow *)window windowDidResignKey:[NSNotification notificationWithName:NSWindowDidResignKeyNotification object:window]];
  if(!associated){status=6;return;}
  host_toggle_fullscreen();
  type_a();
  if(!posted_message(0x102,'a')){status=7;return;}
 });
 exit(status);
}return NULL;}
int main(void){@autoreleasepool{
 setenv("NFSIV_FULLSCREEN","0",1);
 if(!MTLCreateSystemDefaultDevice())return 77;
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
 pthread_t thread;pthread_create(&thread,NULL,check,NULL);[NSApp run];
}return 8;}
'''


class HostInputTests(unittest.TestCase):
    def test_fullscreen_keeps_typing_and_mouse_motion_passes_screen_edges(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            source = directory / 'check.m'
            source.write_text(CHECK)
            binary = directory / 'check'
            compiled = subprocess.run(['clang', '-arch', 'arm64', '-fobjc-arc', '-w', '-I', str(ROOT), str(source),
                                       '-framework', 'Cocoa', '-framework', 'Metal', '-framework', 'QuartzCore',
                                       '-o', str(binary)], capture_output=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr.decode())
            result = subprocess.run([str(binary)], capture_output=True, timeout=60)
            if result.returncode == 77:
                self.skipTest('needs a window server and a Metal device')
            self.assertEqual(result.returncode, 0, result.stderr.decode())


if __name__ == '__main__':
    unittest.main()

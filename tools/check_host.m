/* Native window/presentation smoke check, with no game code or assets. */
#include "../runtime/host.m"
#include <pthread.h>
static void *check(void *unused){@autoreleasepool{
 (void)unused;host_open_window(640,480);
 dispatch_sync(dispatch_get_main_queue(), ^{
  NSRect old=window.frame;NSWindowStyleMask style=window.styleMask;
  NSApplicationPresentationOptions presentation=NSApp.presentationOptions;
  host_toggle_fullscreen();
  NSRect screen=(window.screen?:NSScreen.mainScreen).frame;
  if(!fullscreen_active||!NSEqualRects(window.frame,screen))exit(1);
  NFSIVContentView *view=(NFSIVContentView *)window.contentView;
  NSSize picture=view.gameView.frame.size;
  if(fabs(picture.width/picture.height-4.0/3.0)>.001)exit(2);
  host_window_info();host_toggle_fullscreen();
  if(fullscreen_active||!NSEqualRects(old,window.frame)||window.styleMask!=style||NSApp.presentationOptions!=presentation)exit(3);
  host_window_info();fputs("Native fullscreen sizing, aspect fit and window restoration passed\n",stderr);exit(0);
 });
}return NULL;}
int main(void){@autoreleasepool{
 setenv("NFSIV_FULLSCREEN","0",1);
 [NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
 pthread_t thread;pthread_create(&thread,NULL,check,NULL);[NSApp run];
}return 4;}

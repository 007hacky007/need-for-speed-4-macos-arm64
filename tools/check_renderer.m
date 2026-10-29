/* GPU integration check with synthetic geometry and pixels only. */
#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "render.h"
#include "cpu.h"
#include <pthread.h>
CPU *g_cur_cpu;
static CAMetalLayer *layer;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
void guest_unlock(void){}
void guest_lock(CPU *c){(void)c;}
void *host_metal_device(void){return (__bridge void *)device;}
void *host_metal_queue(void){return (__bridge void *)queue;}
void *host_metal_layer(void){return (__bridge void *)layer;}
void host_frame_presented(void){}
void host_open_window(unsigned w,unsigned h){dispatch_sync(dispatch_get_main_queue(), ^{layer.drawableSize=CGSizeMake(w,h);});}
static RenderState state;
static void quad(float x,float y,float w,float h,float z,uint32_t color){
 float xy[][2]={{x,y},{x+w,y},{x+w,y+h},{x,y},{x+w,y+h},{x,y+h}};
 RenderVertex vertices[6];for(int i=0;i<6;i++)vertices[i]=(RenderVertex){.x=xy[i][0]-.5f,.y=xy[i][1]-.5f,.z=z,.rhw=1,.diffuse=color,.u=i==1||i==2||i==4?1:0,.v=i==2||i==4||i==5?1:0};
 render_draw(vertices,6,0,&state);
}
static void expect(uint32_t *pixels,int x,int y,uint32_t want){uint32_t actual=pixels[y*64+x]&0xffffff;if(actual!=want){fprintf(stderr,"pixel %d,%d: %06x expected %06x\n",x,y,actual,want);exit(1);}}
static void *check(void *unused){@autoreleasepool{
 (void)unused;int clip[]={0,0,64,64};
 if(!render_init()||!render_mode(64,64))exit(2);
 state=(RenderState){.depth=1,.depth_write=1,.depth_func=3,.brightness=1};memcpy(state.clip,clip,sizeof clip);
 render_clear(0xff000000,1,0,clip);
 quad(0,0,64,64,.8f,0xffff0000);quad(16,16,32,32,.2f,0xff00ff00);quad(0,0,64,64,.9f,0xff0000ff);
 uint32_t pixels[4096];if(!render_read(0,0,64,64,pixels,0))exit(3);
 expect(pixels,2,2,0xff0000);expect(pixels,32,32,0x00ff00);
 uint32_t texels[]={0xff0000ff,0xff0000ff,0xff0000ff,0xff0000ff};
 if(!render_texture(1,2,2,0,1,texels))exit(4);state.texture[0]=1;quad(0,0,8,8,0,0xffffffff);
 if(!render_read(0,0,64,64,pixels,0))exit(5);expect(pixels,2,2,0x0000ff);
 state.texture[0]=0;state.blend=1;state.src_blend=2;state.dst_blend=3;quad(16,16,32,32,0,0x80ff0000);
 if(!render_read(0,0,64,64,pixels,0))exit(6);uint32_t mixed=pixels[32*64+32];if(((mixed>>16)&255)<127||((mixed>>8)&255)<126||((mixed>>8)&255)>128)exit(7);
 uint32_t white=0xffffffff;if(!render_write(60,60,1,1,&white,0)||!render_read(60,60,1,1,pixels,0)||pixels[0]!=white)exit(8);
 render_present(0);if(!render_read(60,60,1,1,pixels,1)||pixels[0]!=white)exit(9);
 /* Post-transform depth must be independent of reciprocal W, including decals. */
 state=(RenderState){.depth=1,.depth_write=1,.depth_func=3,.brightness=1};memcpy(state.clip,clip,sizeof clip);
 render_clear(0xff000000,1,0,clip);
 RenderVertex triangle[]={
  {.x=-.5f,.y=-.5f,.z=.13f,.rhw=.1f,.diffuse=0xffff0000},
  {.x=63.5f,.y=-.5f,.z=.64f,.rhw=.3f,.diffuse=0xffff0000},
  {.x=-.5f,.y=63.5f,.z=.93f,.rhw=.7f,.diffuse=0xffff0000}};
 render_draw(triangle,3,0,&state);
 for(unsigned i=0;i<3;i++){triangle[i].rhw=1;triangle[i].diffuse=0xff00ff00;triangle[i].z=nextafterf(nextafterf(triangle[i].z,1),1);}
 state.depth_write=0;state.blend=1;state.src_blend=2;state.dst_blend=0;render_draw(triangle,3,0,&state);
 if(!render_read(0,0,64,64,pixels,0))exit(14);
 unsigned hidden=0;for(unsigned y=4;y<27;y++)for(unsigned x=4;x<27;x++)if((pixels[y*64+x]&0xffffff)!=0xffff00)hidden++;
 int disabled=getenv("NFSIV_DEPTH_FIX")&&!strcmp(getenv("NFSIV_DEPTH_FIX"),"0");
 if((!disabled&&hidden)||(disabled&&!hidden)){fprintf(stderr,"Decal depth correction: %u hidden interior pixels (disabled=%d)\n",hidden,disabled);exit(15);}
 /* The small correction must not reveal lights behind closer geometry. */
 render_clear(0xff000000,1,0,clip);state.blend=0;state.depth_write=1;
 for(unsigned i=0;i<3;i++)triangle[i].diffuse=0xffff0000;
 render_draw(triangle,3,0,&state);
 for(unsigned i=0;i<3;i++){triangle[i].z+=.01f;triangle[i].diffuse=0xff00ff00;}
 state.depth_write=0;state.blend=1;render_draw(triangle,3,0,&state);
 if(!render_read(0,0,64,64,pixels,0))exit(16);
 for(unsigned y=4;y<27;y++)for(unsigned x=4;x<27;x++)if((pixels[y*64+x]&0xffffff)!=0xff0000)exit(17);
 /* EQUAL passes must keep their exact depth rather than receive a decal offset. */
 render_clear(0xff000000,1,0,clip);state.depth_func=3;state.blend=0;state.depth_write=1;
 for(unsigned i=0;i<3;i++)triangle[i].diffuse=0xffff0000;
 render_draw(triangle,3,0,&state);
 state.depth_func=2;state.depth_write=0;state.blend=1;
 for(unsigned i=0;i<3;i++)triangle[i].diffuse=0xff00ff00;
 render_draw(triangle,3,0,&state);
 if(!render_read(0,0,64,64,pixels,0))exit(18);
 for(unsigned y=4;y<27;y++)for(unsigned x=4;x<27;x++)if((pixels[y*64+x]&0xffffff)!=0xffff00)exit(19);
 if(!render_mode(800,600))exit(10);state.blend=0;state.depth_func=3;
 render_clear(0xff000000,1,0,(int[]){0,0,800,600});quad(0,0,64,64,0,0xff00ff00);
 if(!render_read(0,0,64,64,pixels,0))exit(11);expect(pixels,2,2,0x00ff00);render_present(0);
 /* Present repeatedly with an offscreen size different from the window. */
 for(unsigned i=0;i<5;i++)render_present(1);
 fprintf(stderr,"Test layer drawable: %.0fx%.0f\n",layer.drawableSize.width,layer.drawableSize.height);
 if(layer.drawableSize.width==1||layer.drawableSize.height==1)exit(12);
 if(getenv("NFSIV_RENDERER")&&!strcmp(getenv("NFSIV_RENDERER"),"vulkan")&&(layer.drawableSize.width!=256||layer.drawableSize.height!=256))exit(13);
 render_texture_free(1);fprintf(stderr,"Renderer depth, texture, blending, read/write and presentation passed\n");exit(0);
}return NULL;}
int main(void){@autoreleasepool{
 [NSApplication sharedApplication];device=MTLCreateSystemDefaultDevice();queue=[device newCommandQueue];
 NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,256,256) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
 layer=[CAMetalLayer layer];layer.device=device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=NO;layer.drawableSize=CGSizeMake(64,64);
 window.contentView.wantsLayer=YES;window.contentView.layer=layer;[window makeKeyAndOrderFront:nil];
 pthread_t thread;pthread_create(&thread,NULL,check,NULL);[NSApp run];
}return 10;}

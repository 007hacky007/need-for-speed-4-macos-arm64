#import <Metal/Metal.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#include "runtime.h"
#define BACKEND metal_
#include "backend_names.h"
#include "render.h"
#include "shader.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

void *host_metal_device(void);
void *host_metal_queue(void);
void *host_metal_layer(void);
void host_frame_presented(void);
void host_open_window(unsigned,unsigned);
void guest_unlock(void);
void guest_lock(CPU *);

static id<MTLDevice> gpu;
static id<MTLCommandQueue> queue;
static id<MTLLibrary> library;
static id<MTLTexture> color,front_color,depth,white;
static id<MTLBuffer> vertices;
static id<MTLCommandBuffer> command;
static id<MTLRenderCommandEncoder> encoder;
static id<MTLRenderPipelineState> pipelines[202];
static NSMutableDictionary<NSNumber *,id<MTLDepthStencilState>> *depths;
static id<MTLSamplerState> samplers[2][4][3][3];
static NSMutableDictionary<NSNumber *,id<MTLTexture>> *textures;
static unsigned width,height;
static size_t cursor;
static unsigned frames;
static _Atomic int capture_requested;
static _Atomic int capture_busy;
static dispatch_queue_t capture_queue;
void render_request_capture(void){atomic_store(&capture_requested,1);}
static void die(NSString *what){fprintf(stderr,"Metal: %s\n",what.UTF8String);exit(3);}
static void wait_command(id<MTLCommandBuffer> cmd){
 [cmd commit];
 // Keep the event thread and other guest threads live while the GPU runs.
 CPU *cpu=g_cur_cpu;guest_unlock();[cmd waitUntilCompleted];guest_lock(cpu);
 if(cmd.status==MTLCommandBufferStatusError)die(cmd.error.description);
}
int render_init(void){
 if(gpu)return 1;
 gpu=(__bridge id<MTLDevice>)host_metal_device();queue=(__bridge id<MTLCommandQueue>)host_metal_queue();
 if(!gpu||!queue)return 0;
 NSError *error=nil;MTLCompileOptions *options=[MTLCompileOptions new];options.fastMathEnabled=NO;
 library=[gpu newLibraryWithSource:[NSString stringWithUTF8String:metal_shader] options:options error:&error];
 if(!library)die(error.description);
 vertices=[gpu newBufferWithLength:32*1024*1024 options:MTLResourceStorageModeShared];
 textures=[NSMutableDictionary new];depths=[NSMutableDictionary new];
 MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
 d.storageMode=MTLStorageModeShared;white=[gpu newTextureWithDescriptor:d];uint32_t pixel=0xffffffff;
 [white replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&pixel bytesPerRow:4];
 return vertices&&white;
}
void render_flush(void){
 if(encoder){[encoder endEncoding];encoder=nil;}
 if(command){id<MTLCommandBuffer> cmd=command;command=nil;wait_command(cmd);}
 cursor=0;
}
static void begin(void){
 if(encoder)return;
 if(!color)die(@"draw before video mode");
 if(!command)command=[queue commandBuffer];
 MTLRenderPassDescriptor *d=[MTLRenderPassDescriptor renderPassDescriptor];
 d.colorAttachments[0].texture=color;d.colorAttachments[0].loadAction=MTLLoadActionLoad;d.colorAttachments[0].storeAction=MTLStoreActionStore;
 d.stencilAttachment.texture=depth;d.stencilAttachment.loadAction=MTLLoadActionLoad;d.stencilAttachment.storeAction=MTLStoreActionStore;
 d.depthAttachment.texture=depth;d.depthAttachment.loadAction=MTLLoadActionLoad;d.depthAttachment.storeAction=MTLStoreActionStore;
 encoder=[command renderCommandEncoderWithDescriptor:d];
 [encoder setViewport:(MTLViewport){0,0,width,height,0,1}];
}
int render_mode(unsigned w,unsigned h){
 if(!render_init()||!w||!h||w>4096||h>4096)return 0;
 render_flush();width=w;height=h;host_open_window(w,h);
 MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
 d.storageMode=MTLStorageModeShared;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead;color=[gpu newTextureWithDescriptor:d];front_color=[gpu newTextureWithDescriptor:d];
 uint32_t *blank=calloc((size_t)w*h,4);if(!blank)return 0;[front_color replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:0 withBytes:blank bytesPerRow:w*4];free(blank);
 d.pixelFormat=MTLPixelFormatDepth32Float_Stencil8;d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget;depth=[gpu newTextureWithDescriptor:d];
 int clip[]={0,0,(int)w,(int)h};render_clear(0xff000000,1,0,clip);return color&&depth;
}
void render_clear(uint32_t c,float z,int depth_only,const int *clip){
 if(!color)return;
 if(clip[0]>0||clip[1]>0||clip[2]<(int)width||clip[3]<(int)height){
  RenderState s={.depth=1,.depth_write=1,.depth_func=7,.brightness=1,.depth_only=!!depth_only,.stencil=1,.stencil_func=7,.stencil_pass=2};memcpy(s.clip,clip,sizeof s.clip);
  RenderVertex v[6];float xy[][2]={{0,0},{width,0},{width,height},{0,0},{width,height},{0,height}};
  for(unsigned i=0;i<6;i++)v[i]=(RenderVertex){.x=xy[i][0]-.5f,.y=xy[i][1]-.5f,.z=z,.rhw=1,.diffuse=c};
  render_draw(v,6,0,&s);return;
 }
 if(encoder){[encoder endEncoding];encoder=nil;}if(!command)command=[queue commandBuffer];
 MTLRenderPassDescriptor *d=[MTLRenderPassDescriptor renderPassDescriptor];
 d.colorAttachments[0].texture=color;d.colorAttachments[0].loadAction=depth_only?MTLLoadActionLoad:MTLLoadActionClear;d.colorAttachments[0].storeAction=MTLStoreActionStore;
 d.colorAttachments[0].clearColor=MTLClearColorMake(((c>>16)&255)/255.,((c>>8)&255)/255.,(c&255)/255.,(c>>24)/255.);
 d.stencilAttachment.texture=depth;d.stencilAttachment.loadAction=MTLLoadActionLoad;d.stencilAttachment.storeAction=MTLStoreActionStore;
 d.depthAttachment.texture=depth;d.depthAttachment.loadAction=MTLLoadActionClear;d.depthAttachment.storeAction=MTLStoreActionStore;d.depthAttachment.clearDepth=z;d.stencilAttachment.loadAction=MTLLoadActionClear;d.stencilAttachment.clearStencil=0;
 encoder=[command renderCommandEncoderWithDescriptor:d];[encoder setViewport:(MTLViewport){0,0,width,height,0,1}];
}
static MTLBlendFactor blend(unsigned f){
 static const MTLBlendFactor map[]={MTLBlendFactorOne,MTLBlendFactorZero,MTLBlendFactorSourceAlpha,MTLBlendFactorOneMinusSourceAlpha,MTLBlendFactorDestinationAlpha,MTLBlendFactorOneMinusDestinationAlpha,MTLBlendFactorSourceColor,MTLBlendFactorDestinationColor,MTLBlendFactorOneMinusSourceColor,MTLBlendFactorOneMinusDestinationColor};
 if(f>=10)die(@"invalid blend factor");return map[f];
}
void render_draw(const RenderVertex *v,unsigned count,unsigned primitive,const RenderState *s){
 if(!count)return;size_t bytes=(size_t)count*sizeof *v;if(bytes>vertices.length)die(@"vertex batch exceeds buffer");
 if(cursor+bytes>vertices.length)render_flush();begin();memcpy((char *)vertices.contents+cursor,v,bytes);
 unsigned key=(s->blend?1+s->src_blend*10+s->dst_blend:0)+(s->depth_only?101:0);
 if(key>=202)die(@"invalid pipeline key");
 if(!pipelines[key]){
  MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];d.vertexFunction=[library newFunctionWithName:@"scene_vertex"];d.fragmentFunction=[library newFunctionWithName:@"scene_fragment"];
  d.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;d.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;d.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  if(s->depth_only)d.colorAttachments[0].writeMask=MTLColorWriteMaskNone;
  d.colorAttachments[0].blendingEnabled=!!s->blend;d.colorAttachments[0].sourceRGBBlendFactor=blend(s->src_blend);d.colorAttachments[0].sourceAlphaBlendFactor=blend(s->src_blend);d.colorAttachments[0].destinationRGBBlendFactor=blend(s->dst_blend);d.colorAttachments[0].destinationAlphaBlendFactor=blend(s->dst_blend);
  NSError *error=nil;pipelines[key]=[gpu newRenderPipelineStateWithDescriptor:d error:&error];if(!pipelines[key])die(error.description);
 }
 [encoder setRenderPipelineState:pipelines[key]];
 unsigned df=s->depth?s->depth_func:7;
 if(df>7||s->stencil_func>7||s->stencil_fail>7||s->stencil_zfail>7||s->stencil_pass>7)die(@"invalid depth/stencil state");
 uint64_t dk=df|((uint64_t)!!s->depth_write<<3)|((uint64_t)!!s->stencil<<4)|((uint64_t)s->stencil_func<<5)|((uint64_t)s->stencil_fail<<8)|((uint64_t)s->stencil_zfail<<11)|((uint64_t)s->stencil_pass<<14);
 if(!depths[@(dk)]){
  MTLDepthStencilDescriptor *d=[MTLDepthStencilDescriptor new];d.depthCompareFunction=(MTLCompareFunction)df;d.depthWriteEnabled=!!s->depth_write;
  if(s->stencil){
   static const MTLStencilOperation ops[]={MTLStencilOperationKeep,MTLStencilOperationZero,MTLStencilOperationReplace,MTLStencilOperationIncrementClamp,MTLStencilOperationDecrementClamp,MTLStencilOperationInvert,MTLStencilOperationIncrementWrap,MTLStencilOperationDecrementWrap};
   MTLStencilDescriptor *st=[MTLStencilDescriptor new];st.stencilCompareFunction=(MTLCompareFunction)s->stencil_func;st.stencilFailureOperation=ops[s->stencil_fail];st.depthFailureOperation=ops[s->stencil_zfail];st.depthStencilPassOperation=ops[s->stencil_pass];d.frontFaceStencil=d.backFaceStencil=st;
  }
  depths[@(dk)]=[gpu newDepthStencilStateWithDescriptor:d];
 }
 [encoder setDepthBias:render_decal_bias(s) slopeScale:0 clamp:0];
 [encoder setDepthStencilState:depths[@(dk)]];[encoder setStencilReferenceValue:0];
 [encoder setFrontFacingWinding:MTLWindingClockwise];[encoder setCullMode:s->cull==0?MTLCullModeNone:s->cull==1?MTLCullModeBack:MTLCullModeFront];
 int x=MAX(0,s->clip[0]),y=MAX(0,s->clip[1]),r=MIN((int)width,s->clip[2]),b=MIN((int)height,s->clip[3]);
 if(r<=x||b<=y)return;[encoder setScissorRect:(MTLScissorRect){(NSUInteger)x,(NSUInteger)y,(NSUInteger)(r-x),(NSUInteger)(b-y)}];
 float size[]={(float)width,(float)height};[encoder setVertexBuffer:vertices offset:cursor atIndex:0];[encoder setVertexBytes:size length:sizeof size atIndex:1];[encoder setFragmentBytes:s length:sizeof *s atIndex:0];
 for(unsigned i=0;i<2;i++){
  unsigned f=s->filter[i]?1:0,m=s->mip[i],u=s->address_u[i],a=s->address_v[i];if(m>3||u>2||a>2)die(@"invalid sampler state");
  if(!samplers[f][m][u][a]){MTLSamplerDescriptor *d=[MTLSamplerDescriptor new];d.minFilter=d.magFilter=f?MTLSamplerMinMagFilterLinear:MTLSamplerMinMagFilterNearest;d.mipFilter=m==0?MTLSamplerMipFilterNotMipmapped:m==1?MTLSamplerMipFilterNearest:MTLSamplerMipFilterLinear;
   MTLSamplerAddressMode address[]={MTLSamplerAddressModeClampToEdge,MTLSamplerAddressModeRepeat,MTLSamplerAddressModeMirrorRepeat};d.sAddressMode=address[u];d.tAddressMode=address[a];samplers[f][m][u][a]=[gpu newSamplerStateWithDescriptor:d];}
  [encoder setFragmentSamplerState:samplers[f][m][u][a] atIndex:i];[encoder setFragmentTexture:textures[@(s->texture[i])]?:white atIndex:i];
 }
 [encoder drawPrimitives:primitive==0?MTLPrimitiveTypeTriangle:primitive==1?MTLPrimitiveTypeLine:MTLPrimitiveTypePoint vertexStart:0 vertexCount:count];cursor+=bytes;
}
int render_texture(unsigned handle,unsigned w,unsigned h,unsigned level,unsigned levels,const uint32_t *pixels){
 if(!render_init())return 0;
 id<MTLTexture> t=textures[@(handle)];if(!t){MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:levels>1];d.mipmapLevelCount=levels;d.storageMode=MTLStorageModeShared;t=[gpu newTextureWithDescriptor:d];if(!t)return 0;textures[@(handle)]=t;}
 if(level>=t.mipmapLevelCount)return 0;
 // CPU writes must not race a pending GPU read of this resource.
 render_flush();[t replaceRegion:MTLRegionMake2D(0,0,w,h) mipmapLevel:level withBytes:pixels bytesPerRow:w*4];return 1;
}
void render_texture_free(unsigned h){render_flush();[textures removeObjectForKey:@(h)];}
void render_present(int front){
 if(!color)return;if(encoder){[encoder endEncoding];encoder=nil;}
 CAMetalLayer *layer=(__bridge CAMetalLayer *)host_metal_layer();
 id<CAMetalDrawable> drawable=[layer nextDrawable];if(!drawable){render_flush();return;}
 if(!command)command=[queue commandBuffer];id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
 if(!front)[blit copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toTexture:front_color destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
 [blit copyFromTexture:front_color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toTexture:drawable.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];[blit endEncoding];[command presentDrawable:drawable];render_flush();host_frame_presented();
 frames++;
 if(frames==1||frames%120==0)fprintf(stderr,"Metal presented frame %u\n",frames);
 const char *capture=getenv("NFSIV_CAPTURE");unsigned interval=capture?(unsigned)strtoul(capture,NULL,10):0;
 if(atomic_exchange(&capture_requested,0)||(interval&&(frames==1||frames==30||frames==31||frames==120||frames==121||frames==300||frames==301||frames%(interval>1?interval:600)==0)))render_capture_frame(frames);
}
void render_capture_frame(unsigned frame){
 if(!front_color||atomic_exchange(&capture_busy,1))return;
 render_flush();
 NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:width*4 bitsPerPixel:32];
 if(!rep){atomic_store(&capture_busy,0);fputs("cannot allocate frame capture\n",stderr);return;}
 [front_color getBytes:rep.bitmapData bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
 if(!capture_queue)capture_queue=dispatch_queue_create("org.nfsiv.capture",DISPATCH_QUEUE_SERIAL);
 /* Bound memory to one owned snapshot; encoding and disk I/O never hold the guest lock. */
 dispatch_async(capture_queue, ^{@autoreleasepool{
  size_t bytes=(size_t)rep.pixelsWide*rep.pixelsHigh*4;
  if(frame==30){FILE *raw=fopen("out/frame-000030.bgra","wb");if(raw){fwrite(rep.bitmapData,1,bytes,raw);fclose(raw);}else fputs("cannot save raw frame capture\n",stderr);}
  for(size_t i=0;i<bytes;i+=4){uint8_t *p=rep.bitmapData+i;uint8_t b=p[0];p[0]=p[2];p[2]=b;p[3]=255;}
  NSString *path=[NSString stringWithFormat:@"out/frame-%06u.png",frame];
  if(![[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES])fputs("cannot save frame capture\n",stderr);
  atomic_store(&capture_busy,0);
 }});
}
void render_capture_wait(void){if(capture_queue)dispatch_sync(capture_queue, ^{});}
int render_read(unsigned x,unsigned y,unsigned w,unsigned h,uint32_t *out,int front){if(!color||x+w>width||y+h>height)return 0;render_flush();[(front?front_color:color) getBytes:out bytesPerRow:w*4 fromRegion:MTLRegionMake2D(x,y,w,h) mipmapLevel:0];return 1;}
int render_write(unsigned x,unsigned y,unsigned w,unsigned h,const uint32_t *in,int front){if(!color||x+w>width||y+h>height)return 0;render_flush();[(front?front_color:color) replaceRegion:MTLRegionMake2D(x,y,w,h) mipmapLevel:0 withBytes:in bytesPerRow:w*4];return 1;}

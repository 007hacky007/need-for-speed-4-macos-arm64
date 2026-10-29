#include "thrash.h"
#include "render.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

static const struct {const char *name;unsigned args;} exports[]={
 {"about",0},{"clearwindow",0},{"clip",4},{"drawline",2},{"drawlinemesh",3},{"drawlinestrip",3},{"drawlinestrip",2},
 {"drawpoint",1},{"drawpointmesh",3},{"drawpointstrip",2},{"drawquad",4},{"drawquadmesh",3},{"drawsprite",2},{"drawspritemesh",3},
 {"drawtri",3},{"drawtrifan",3},{"drawtrifan",2},{"drawtrimesh",3},{"drawtristrip",3},{"drawtristrip",2},
 {"flushwindow",0},{"getstate",1},{"idle",0},{"init",0},{"is",0},{"lockwindow",0},{"pageflip",0},{"readrect",5},
 {"restore",0},{"selectdisplay",1},{"setstate",2},{"settexture",1},{"setvideomode",3},{"sync",1},
 {"talloc",5},{"tfree",1},{"treset",0},{"tupdate",3},{"unlockwindow",1},{"window",1},{"writerect",5}
};
static unsigned calls[41];
/* Keep the original slots stable: saved settings contain mode indices. */
static const unsigned mode_sizes[][2]={
 {640,480},{800,600},{1024,768},{1280,1024},{1600,1200},
 {1920,1080},{1920,1200},{2048,1536},{2560,1440},{2560,1600},
 {2560,1920},{2880,1800},{2880,2160},{3024,1964},{3840,2160},{4096,3072},{1280,960},{1920,1440}
};
enum {MODE_COUNT=sizeof mode_sizes/sizeof mode_sizes[0]*2};
unsigned thrash_requested_mode(void){
 const char *value=getenv("NFSIV_RESOLUTION");unsigned w,h;char extra;
 if(!value||sscanf(value,"%ux%u%c",&w,&h,&extra)!=2)return 0;
 for(unsigned i=0;i<sizeof mode_sizes/sizeof mode_sizes[0];i++){
  if(mode_sizes[i][0]==w&&mode_sizes[i][1]==h)return i<5?i+6:12+(i-5)*2;
 }
 return 0;
}

static uint32_t descriptor,modes,states[512][8],selected_window,lockinfo,lockbits;
static unsigned width=640,height=480,bits=16;
static int locked;
static uint8_t *lock_snapshot;
static float clear_depth=1,depth_bias;
static uint32_t background;
static RenderState rs;
static uint8_t fogtable[256];
static int table_active;
static struct {uint32_t handle;unsigned w,h,format,levels,stage;uint8_t *pixels;uint32_t palette[256];} textures[2048];

uint32_t thrash_proc(const char *name){
 for(unsigned i=0;i<41;i++){char n[64];snprintf(n,sizeof n,"_THRASH_%s@%u",exports[i].name,exports[i].args*4);if(!strcmp(n,name))return 0xe2000000u+i;}
 return 0;
}
static uint32_t about(void){
 if(descriptor)return descriptor;
 descriptor=win32_alloc(208,1);modes=win32_alloc((MODE_COUNT+1)*40,1);uint32_t formats=win32_alloc(16*4,1),palettes=win32_alloc(16*4,1),author=win32_alloc(64,1);
 const char *backend=getenv("NFSIV_RENDERER");int vulkan=backend&&!strcmp(backend,"vulkan");
 strcpy((char *)guest_ptr(author,64),vulkan?"Native Vulkan renderer":"Native Metal renderer");
 MR32(descriptor)=0x44334437;MR32(descriptor+4)=208;MR32(descriptor+8)=0x6b;MR32(descriptor+12)=0x2f;
 MR32(descriptor+0x10)=MR32(descriptor+0x18)=MR32(descriptor+0x1c)=MR32(descriptor+0x24)=1;
 MR32(descriptor+0x14)=MR32(descriptor+0x20)=4096;
 MR32(descriptor+0x2c)=16;MR32(descriptor+0x30)=formats;MR32(descriptor+0x34)=16;MR32(descriptor+0x38)=palettes;
 for(unsigned i=3;i<=7;i++)if(i!=5)MR32(formats+4*i)=1;
 MR32(descriptor+0x3c)=MODE_COUNT;MR32(descriptor+0x40)=modes;MR32(descriptor+0x44)=2;
 MR32(descriptor+0x6c)=0x10;MR32(descriptor+0x70)=128*1024*1024;MR32(descriptor+0x78)=author;MR32(descriptor+0x7c)=7;
 strcpy((char *)guest_ptr(descriptor+0x80,80),vulkan?"Vulkan":"Metal");
 for(unsigned i=1;i<=MODE_COUNT;i++){
  unsigned size=i<=10?(i-1)%5:5+(i-11)/2,bpp=i<=10?(i<=5?16:32):((i-11)%2?32:16);
  uint32_t p=modes+i*40;MR32(p)=mode_sizes[size][0];MR32(p+4)=mode_sizes[size][1];MR32(p+8)=bpp;MR32(p+12)=bpp==16?4:6;MR32(p+16)=1;MR32(p+20)=3;MR32(p+24)=2;
 }
 return descriptor;
}
static float floating(uint32_t v){float f;memcpy(&f,&v,4);return f;}
static int texture_index(uint32_t h){for(unsigned i=0;i<2048;i++)if(textures[i].handle==h&&h)return (int)i;return -1;}
static int select_texture(uint32_t h){
 if(h<16){if(h==0)rs.texture[0]=rs.texture[1]=0;else if(h<=2)rs.texture[h-1]=0;else return 0;return 1;}
 int i=texture_index(h);if(i<0)return 0;rs.texture[textures[i].stage]=h;return 1;
}
static uint32_t primitive_packet(CPU *,uint32_t);
static uint32_t set_state(CPU *c,uint32_t id,uint32_t v){
 unsigned state=id&0xffff,stage=(id>>16)&7;if(stage>1)stage=1;
 switch(state){
 case 0:return 0; /* Verok disables default filtering by replacing its state ID with zero. */
 case 0x6c:return 0; /* Movie notification: the supplied dx7 driver reports unsupported. */
 case 1:return select_texture(v);
 case 2:if(v>2)return 0;rs.cull=v;break;
 case 3:background=v;break;
 case 4:if(v>2)return 0;rs.depth=!!v;rs.depth_write=!!v;break;
 case 5:break;
 case 6:if(v>2)return 0;rs.shade=v;break;
 case 7:if(v>2)return 0;rs.filter[stage]=v;break;
 case 8:break; // shortcut: LOD bias is not applied yet; add it if texture selection differs.
 case 9:break;
 case 0xa:rs.blend=v==2;break;
 case 0xb:if(v>3)return 0;rs.mip[stage]=v;break;
 case 0xc:case 0x10:case 0x11:case 0x31:case 0x32:case 0x33:case 0x25:case 0x26:case 0x3f:case 0x193:return 0;
 case 0xd:if(v>2)return 0;rs.address_u[stage]=rs.address_v[stage]=v;break;
 case 0xe:rs.fog_density=v>0x10000?floating(v):v?1.0f/v:0;break;
 case 0xf:rs.fog_color=v;break;
 case 0x12:break;
 case 0x13:if(v)guest_ptr(v,32);break;
 case 0x14:case 0x69:table_active=!!v;if(v){const uint8_t *p=guest_ptr(v,256);for(unsigned i=0;i<256;i++)fogtable[i]=255-p[i];}break;
 case 0x15:if(v>1)rs.fog_mode=v;rs.fog=v!=0;break;
 case 0x16:case 0x17:break;
 case 0x18:case 0x66:depth_bias=(int32_t)v*(1.0f/32768);break;
 case 0x19:break;
 /* Bookkeeping/callback slots in the original dx7z common state table. */
 case 0x1a:case 0x1b:case 0x1c:case 0x1e:case 0x1f:case 0x20:case 0x21:case 0x27:case 0x37:case 0x3a:case 0x3d:case 0x3e:break;
 case 0x23:return 1;
 case 0x24:rs.alpha_ref=v;break;
 case 0x28:if(v>7)return 0;rs.depth_func=v;break;
 case 0x29:if(v>8&&v!=0x61&&v!=0x62&&v!=0x63)return 0;rs.combine[stage]=v;break;
 case 0x2a:break;
 case 0x2e:case 0x65:rs.brightness=floating(v);break;
 case 0x2f:rs.stencil=!!v;break;
 case 0x30:if(v>7)return 0;rs.stencil_func=v;break;
 case 0x34:case 0x35:case 0x36:if(v>7)return 0;if(state==0x34)rs.stencil_fail=v;else if(state==0x35)rs.stencil_zfail=v;else rs.stencil_pass=v;break;
 case 0x38:case 0x68:
  if(v>3)return 0;
  {unsigned src[]={2,2,1,7},dst[]={3,0,3,1};rs.src_blend=src[v];rs.dst_blend=dst[v];}break;
 case 0x39:case 0x6a:rs.depth_write=!!v;break;
 case 0x3b:selected_window=v;break;
 case 0x3c:case 0x67:break;
 case 0x40:if(v>7)return 0;rs.alpha_func=v;break;
 case 0x41:if(v>2)return 0;rs.address_u[stage]=v;break;
 case 0x42:if(v>2)return 0;rs.address_v[stage]=v;break;
 case 0x43:clear_depth=floating(v);break;
 case 0x194:case 0x195:if(v>9)return 0;if(state==0x194)rs.src_blend=v;else rs.dst_blend=v;break;
 case 0x19a:rs.factor=v;break;
 case 0x1c3:return 1;
 case 0x1b3:return primitive_packet(c,v);
 default:
  /* The supplied DX7 driver rejects states beyond its 0x1c3 extension table. */
  if(state>0x1c3)return 0;
  runtime_fail(c,"unimplemented Thrash state",id);
 }
 if(state<512)states[state][stage]=v;return 1;
}
static RenderVertex vertex_stride(uint32_t p,unsigned stride,int raw){
 RenderVertex v={0};memcpy(&v,guest_ptr(p,stride),stride);
 if(stride==32){v.u1=v.u;v.v1=v.v;}
 if(!raw){v.z+=depth_bias;if(rs.shade==0)v.diffuse=0xffffffff;if(table_active){int idx=(int)(v.z*255);if(idx<0)idx=0;if(idx>255)idx=255;v.specular=(v.specular&0xffffff)|((uint32_t)fogtable[idx]<<24);}}
 return v;
}
static RenderVertex vertex(uint32_t p,int raw){return vertex_stride(p,states[0x2a][0]?40:32,raw);}
static uint32_t primitive_packet(CPU *c,uint32_t p){
 guest_ptr(p,24);
 unsigned type=MR32(p),format=MR32(p+4),vertices=MR16(p+12),count=vertices;
 uint32_t base=MR32(p+8),indices=MR32(p+16);
 if(type<1||type>6)return 0;
 if(format!=0x1c4&&format!=0x2c4)runtime_fail(c,"Thrash primitive vertex format",format);
 unsigned stride=format==0x2c4?40:32;
 if(indices&&MR16(p+20))count=MR16(p+20);else indices=0;
 if(!count)return 1;
 guest_ptr(base,(uint64_t)vertices*stride);if(indices)guest_ptr(indices,(uint64_t)count*2);
 /* Validate all indices before submitting any drawing. */
 for(unsigned i=0;indices&&i<count;i++)if(MR16(indices+i*2)>=vertices)return 0;
 unsigned primitive_count=type==1?count:type==2?count/2:type==3?count-1:type==4?count/3:count>2?count-2:0;
 for(unsigned i=0;i<primitive_count;i++){
  unsigned order[3],n=type==1?1:type<=3?2:3;
  if(type==1)order[0]=i;
  else if(type==2){order[0]=i*2;order[1]=i*2+1;}
  else if(type==3){order[0]=i;order[1]=i+1;}
  else if(type==4){order[0]=i*3;order[1]=i*3+1;order[2]=i*3+2;}
  else if(type==5){order[0]=i+(i&1);order[1]=i+1-(i&1);order[2]=i+2;}
  else{order[0]=0;order[1]=i+1;order[2]=i+2;}
  RenderVertex v[3];
  for(unsigned j=0;j<n;j++){unsigned index=indices?MR16(indices+order[j]*2):order[j];v[j]=vertex_stride(base+index*stride,stride,0);}
  render_draw(v,n,type==1?2:type<=3?1:0,&rs);
 }
 return 1;
}
static void polygon(const uint32_t *p,unsigned count){
 RenderVertex v[6];static const unsigned order[]={0,1,2,0,2,3};for(unsigned i=0;i<(count==3?3:6);i++)v[i]=vertex(p[order[i]],0);render_draw(v,count==3?3:6,0,&rs);
}
static void sprite(uint32_t a,uint32_t b){
 RenderVertex corners[]={vertex(a,0),vertex(b,0),vertex(b,0),vertex(b,0)},v[6];
 corners[1].y=corners[0].y;corners[1].v=corners[0].v;corners[1].v1=corners[0].v1;
 corners[3].x=corners[0].x;corners[3].u=corners[0].u;corners[3].u1=corners[0].u1;
 unsigned order[]={0,1,2,0,2,3};for(unsigned i=0;i<6;i++)v[i]=corners[order[i]];render_draw(v,6,0,&rs);
}
static uint32_t indexed(CPU *c,uint32_t base,uint32_t indices,unsigned i,unsigned stride){
 int32_t index=indices?(int32_t)*(uint32_t *)guest_ptr(indices+4*(uint64_t)i,4):(int32_t)i;
 uint64_t p=(uint64_t)base+(uint64_t)(uint32_t)index*stride;if(index<0||p>0xffffffff)runtime_fail(c,"invalid Thrash vertex index",(uint32_t)index);return (uint32_t)p;
}
static void draw_mesh(CPU *c,unsigned op,uint32_t *a){
 unsigned count=a[0],stride=states[0x2a][0]?40:32;uint32_t base=a[1],indices=a[2];
 if(count>1000000)runtime_fail(c,"invalid Thrash primitive count",count);
 if(op==6||op==9||op==16||op==19)indices=0;
 for(unsigned i=0;i<count;i++){
  uint32_t p[4];
  if(op==11||op==17||op==13){unsigned n=op==11?4:op==13?2:3;for(unsigned j=0;j<n;j++)p[j]=indexed(c,base,indices,i*n+j,op==13&&states[0x1e][0]?states[0x1e][0]:stride);if(op==13)sprite(p[0],p[1]);else polygon(p,n);}
  else if(op==15||op==16||op==18||op==19){unsigned order[]={op==15||op==16?0:i+(i&1),op==15||op==16?i+1:i+1-(i&1),i+2};RenderVertex v[3];for(unsigned j=0;j<3;j++)v[j]=vertex(indexed(c,base,indices,order[j],stride),1);render_draw(v,3,0,&rs);}
  else{unsigned n=op==8||op==9?1:2;RenderVertex v[2];for(unsigned j=0;j<n;j++)v[j]=vertex(indexed(c,base,indices,(op==5||op==6)?i+j:i*n+j,stride),0);render_draw(v,n,n==1?2:1,&rs);}
 }
}
static int unlock(void){
 if(!locked)return 1;locked=0;size_t count=(size_t)width*height,bytes=count*(bits/8);
 const void *data=guest_ptr(lockbits,bytes);if(!memcmp(data,lock_snapshot,bytes))return 1;
 uint32_t *pixels=malloc(count*4);if(!pixels)return 0;
 int front=selected_window==1;
 int ok=render_pixels(bits==16?4:6,width,height,data,bytes,NULL,pixels)&&render_write(0,0,width,height,pixels,front);free(pixels);
 if(ok&&front)render_present(1);return ok;
}
static uint32_t lock(void){
 if(!selected_window||selected_window==3||selected_window==5)return 0;if(locked)return lockinfo;
 size_t count=(size_t)width*height;uint32_t *pixels=malloc(count*4);if(!pixels)return 0;
 int ok=render_read(0,0,width,height,pixels,selected_window==1);
 if(ok){if(bits==32)memcpy(guest_ptr(lockbits,count*4),pixels,count*4);else for(size_t i=0;i<count;i++){uint32_t c=pixels[i];MR16(lockbits+2*i)=((c>>8)&0xf800)|((c>>5)&0x7e0)|((c>>3)&31);}size_t bytes=count*(bits/8);uint8_t *snapshot=realloc(lock_snapshot,bytes);if(!snapshot){free(pixels);return 0;}lock_snapshot=snapshot;memcpy(lock_snapshot,guest_ptr(lockbits,bytes),bytes);locked=1;}
 free(pixels);return ok?lockinfo:0;
}
void thrash_call(CPU *c,uint32_t address){
 unsigned op=address-0xe2000000u;if(op>=41)runtime_fail(c,"invalid Thrash export",address);
 POP32(c->eip);uint32_t a[5]={0};for(unsigned i=0;i<exports[op].args;i++)a[i]=*(uint32_t *)guest_ptr(c->esp+i*4,4);
 if(!calls[op]++||getenv("NFSIV_THRASH_TRACE")){fprintf(stderr,"Thrash %s from %08x",exports[op].name,c->eip);for(unsigned i=0;i<exports[op].args;i++)fprintf(stderr," %08x",a[i]);fputc('\n',stderr);}
 uint32_t r=1;
 switch(op){
 case 0:r=about();break;
 case 1:unlock();render_clear(background,clear_depth,selected_window==3||selected_window==5,rs.clip);break;
 case 2:for(unsigned i=0;i<4;i++)rs.clip[i]=(int32_t)a[i];break;
 case 3:{RenderVertex v[]={vertex(a[0],0),vertex(a[1],0)};render_draw(v,2,1,&rs);break;}
 case 7:{RenderVertex v=vertex(a[0],0);render_draw(&v,1,2,&rs);break;}
 case 10:polygon(a,4);break;
 case 12:sprite(a[0],a[1]);break;
 case 14:polygon(a,3);break;
 case 4:case 5:case 6:case 8:case 9:case 11:case 13:case 15:case 16:case 17:case 18:case 19:draw_mesh(c,op,a);break;
 case 20:case 33:render_flush();break;
 case 21:r=(a[0]&0xffff)<512?states[a[0]&0xffff][(a[0]>>16)&7]:0;break;
 case 22:break;
 case 23:r=render_init();break;
 case 24:r=0x55;break;
 case 25:r=lock();break;
 case 26:unlock();render_present(0);break;
 case 27:case 40:{
  unsigned x=a[0],y=a[1],w=a[2],h=a[3];if(!w||!h||x>width||y>height||w>width-x||h>height-y){r=0;break;}
  size_t bytes=(size_t)w*h*(bits/8);void *p=guest_ptr(a[4],bytes);uint32_t *pixels=malloc((size_t)w*h*4);if(!pixels){r=0;break;}
  unlock();if(op==27){r=render_read(x,y,w,h,pixels,selected_window==1);if(r){if(bits==32)memcpy(p,pixels,bytes);else for(size_t i=0;i<(size_t)w*h;i++)((uint16_t *)p)[i]=((pixels[i]>>8)&0xf800)|((pixels[i]>>5)&0x7e0)|((pixels[i]>>3)&31);}}
  else{r=render_pixels(bits==16?4:6,w,h,p,bytes,NULL,pixels)&&render_write(x,y,w,h,pixels,selected_window==1);}free(pixels);if(r&&op==40&&selected_window==1)render_present(1);break;}
 case 28:unlock();render_flush();break;
 case 29:r=a[0]==0||a[0]==0xffffffff;break;
 case 30:r=set_state(c,a[0],a[1]);break;
 case 31:r=select_texture(a[0]);break;
 case 32:{
  about();if(a[0]<1||a[0]>MODE_COUNT){r=0;break;}uint32_t mode=modes+a[0]*40;
  unlock();r=render_mode(MR32(mode),MR32(mode+4));if(!r)break;
  void gheap_free(int,uint32_t);gheap_free(1,lockbits);gheap_free(1,lockinfo);gheap_free(1,states[0x1d][0]);
  width=MR32(mode);height=MR32(mode+4);bits=MR32(mode+8);
  uint32_t changes=states[0x3e][0]+1;memset(states,0,sizeof states);states[0x3e][0]=changes;memset(&rs,0,sizeof rs);rs.clip[2]=width;rs.clip[3]=height;rs.factor=0xffffffff;rs.stencil_func=7;
  uint32_t defaults[][2]={{2,1},{7,1},{6,1},{0xa,2},{0x24,16},{0x40,4},{0xb,1},{0x38,0},{0x2e,0x3f800000},{0x28,3},{4,a[2]!=0}};
  for(unsigned i=0;i<sizeof defaults/sizeof defaults[0];i++)set_state(c,defaults[i][0],defaults[i][1]);
  lockinfo=win32_alloc(20,1);lockbits=win32_alloc(width*height*(bits/8),1);MR32(lockinfo)=lockbits;MR32(lockinfo+4)=width*(bits/8);MR32(lockinfo+8)=bits==16?4:6;MR32(lockinfo+12)=width;MR32(lockinfo+16)=height;
  states[0x1d][0]=win32_alloc(20,1);memcpy(guest_ptr(states[0x1d][0],20),guest_ptr(lockinfo,20),20);MR32(states[0x1d][0])=0;
  selected_window=0;locked=0;break;}
 case 34:{
  r=0;if(!render_pixel_bytes(a[2]&255,a[0],a[1]))break;
  for(unsigned i=0;i<2048;i++)if(!textures[i].handle){
   textures[i].handle=win32_alloc(32,1);textures[i].w=a[0];textures[i].h=a[1];textures[i].format=a[2]&255;
   unsigned max=1,n=a[0]>a[1]?a[0]:a[1];while(n>1){n>>=1;max++;}
   textures[i].levels=(int32_t)a[4]>0?(a[4]&0xffff)+1:1;if(textures[i].levels>max)textures[i].levels=max;
   textures[i].stage=(int32_t)a[4]>0&&(a[4]&0xffff0000)==0x10000?1:0;r=textures[i].handle;break;
  }break;}
 case 35:{int i=texture_index(a[0]);if(i<0){r=0;break;}render_texture_free(a[0]);for(unsigned s=0;s<2;s++)if(rs.texture[s]==a[0])rs.texture[s]=0;free(textures[i].pixels);void gheap_free(int,uint32_t);gheap_free(1,textures[i].handle);memset(&textures[i],0,sizeof textures[i]);break;}
 case 36:for(unsigned i=0;i<2048;i++)if(textures[i].handle){render_texture_free(textures[i].handle);free(textures[i].pixels);void gheap_free(int,uint32_t);gheap_free(1,textures[i].handle);memset(&textures[i],0,sizeof textures[i]);}rs.texture[0]=rs.texture[1]=0;break;
 case 37:{
  int i=texture_index(a[0]);r=0;if(i<0)break;
  unsigned w=textures[i].w,h=textures[i].h;size_t total=0;for(unsigned l=0;l<textures[i].levels;l++){total+=render_pixel_bytes(textures[i].format,w,h);w=w>1?w/2:1;h=h>1?h/2:1;}
  if(a[1]){uint8_t *p=realloc(textures[i].pixels,total);if(!p)break;textures[i].pixels=p;memcpy(p,guest_ptr(a[1],total),total);}if(!textures[i].pixels)break;
  if(a[2])memcpy(textures[i].palette,guest_ptr(a[2],1024),1024);
  w=textures[i].w;h=textures[i].h;size_t offset=0;uint32_t *converted=malloc((size_t)w*h*4);if(!converted)break;
  r=a[0];for(unsigned l=0;l<textures[i].levels;l++){size_t bytes=render_pixel_bytes(textures[i].format,w,h);if(!render_pixels(textures[i].format,w,h,textures[i].pixels+offset,bytes,textures[i].palette,converted)||!render_texture(a[0],w,h,l,textures[i].levels,converted)){r=0;break;}offset+=bytes;w=w>1?w/2:1;h=h>1?h/2:1;}free(converted);break;}
 case 38:r=unlock();break;
 case 39:selected_window=a[0];states[0x3b][0]=a[0];r=a[0]!=0;break;
 }
 c->eax=r;c->esp+=exports[op].args*4;
}

#ifndef NFSIV_RENDER_H
#define NFSIV_RENDER_H
#include <stddef.h>
#include <stdint.h>
typedef struct {float x,y,z,rhw;uint32_t diffuse,specular;float u,v,u1,v1;} RenderVertex;
typedef struct {
 uint32_t cull,depth,depth_write,depth_func,blend,src_blend,dst_blend;
 uint32_t alpha_ref,alpha_func,shade,combine[2],filter[2],mip[2],address_u[2],address_v[2];
 uint32_t texture[2],factor,fog,fog_color,fog_mode;
 float fog_density,brightness;
 uint32_t stencil,stencil_func,stencil_fail,stencil_zfail,stencil_pass,depth_only;
 int clip[4];
} RenderState;
size_t render_pixel_bytes(unsigned format,unsigned w,unsigned h);
int render_pixels(unsigned format,unsigned w,unsigned h,const void *,size_t,const uint32_t *,uint32_t *);
float render_decal_bias(const RenderState *);
int render_init(void);
int render_mode(unsigned,unsigned);
void render_clear(uint32_t,float,int,const int *);
void render_draw(const RenderVertex *,unsigned,unsigned,const RenderState *);
int render_texture(unsigned,unsigned,unsigned,unsigned,unsigned,const uint32_t *);
void render_texture_free(unsigned);
void render_flush(void);
void render_present(int front);
void render_capture_frame(unsigned);
void render_capture_wait(void);
int render_read(unsigned,unsigned,unsigned,unsigned,uint32_t *,int front);
int render_write(unsigned,unsigned,unsigned,unsigned,const uint32_t *,int front);
#endif

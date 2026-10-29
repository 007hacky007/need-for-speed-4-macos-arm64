#include "render.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int backend=-1;
static int selected(void){
 if(backend<0){const char *s=getenv("NFSIV_RENDERER");
  if(!s||!strcmp(s,"metal"))backend=0;
  else if(!strcmp(s,"vulkan"))backend=1;
  else{fprintf(stderr,"Unknown renderer: %s\n",s);exit(3);}
 }
 return backend;
}
#define R(ret,name,args,call) extern ret metal_##name args; extern ret vulkan_##name args; \
 ret render_##name args {if(selected())return vulkan_##name call;return metal_##name call;}
#include "render_backend.inc"
#undef R

float render_decal_bias(const RenderState *s){
 static int enabled=-1;
 if(enabled<0){const char *value=getenv("NFSIV_DEPTH_FIX");enabled=!value||strcmp(value,"0");}
 /* Projected lights share a surface with a previous opaque pass. Keep the
    offset in floating-point depth units, with no change to depth writes. */
 return enabled&&s->depth&&s->depth_func==3&&!s->depth_write&&s->blend&&s->src_blend==2&&s->dst_blend==0?-4.f:0.f;
}

#include <metal_stdlib>
using namespace metal;
struct V {float x,y,z,rhw;uint diffuse,specular;float u,v,u1,v1;};
struct State {
 uint cull,depth,depth_write,depth_func,blend,src_blend,dst_blend;
 uint alpha_ref,alpha_func,shade,combine[2],filter[2],mip[2],address_u[2],address_v[2];
 uint texture[2],factor,fog,fog_color,fog_mode;
 float fog_density,brightness;
 uint stencil,stencil_func,stencil_fail,stencil_zfail,stencil_pass,depth_only;
 int clip[4];
};
struct Out {float4 pos [[position]];float4 color [[center_no_perspective]];float4 spec [[center_no_perspective]];float2 uv;float2 uv1;float fogz;};
float4 argb(uint c){return float4((c>>16)&255,(c>>8)&255,c&255,c>>24)/255.0;}
vertex Out scene_vertex(uint id [[vertex_id]],device const V *v [[buffer(0)]],constant float2 &size [[buffer(1)]]){
 V a=v[id];float w=a.rhw!=0?1.0/a.rhw:1.0;Out o;
 o.pos=float4((2.0*(a.x+0.5)/size.x-1.0)*w,(1.0-2.0*(a.y+0.5)/size.y)*w,a.z*w,w);
 o.color=argb(a.diffuse);o.spec=argb(a.specular);o.uv=float2(a.u,a.v);o.uv1=float2(a.u1,a.v1);o.fogz=w;return o;
}
float4 combine(float4 t,float4 c,uint mode,uint stage,float4 factor){
 switch(mode){
 case 0: return stage==0?t*c:c;
 case 1:return t+c;
 case 2:return c;
 case 3:return t*c;
 case 4:return float4(t.rgb-c.rgb,t.a);
 case 5:return float4(c.rgb,1.0-t.a+c.a-0.5);
 case 6:return t*c*2.0;
 case 7:return t*c*4.0;
 case 8:return stage==0?t*c:float4(mix(c.rgb,t.rgb,t.a),c.a);
 case 0x61:return t+c-0.5;
 case 0x62:return float4(t.rgb+c.rgb,mix(factor.a,t.a,factor.a));
 case 0x63:return float4(mix(c.rgb,t.rgb,factor.a),t.a);
 default:return c;
 }
}
bool compare_alpha(float a,float b,uint fn){switch(fn){case 0:return false;case 1:return a<b;case 2:return a==b;case 3:return a<=b;case 4:return a>b;case 5:return a!=b;case 6:return a>=b;default:return true;}}
fragment float4 scene_fragment(Out v [[stage_in]],constant State &s [[buffer(0)]],texture2d<float> t0 [[texture(0)]],texture2d<float> t1 [[texture(1)]],sampler p0 [[sampler(0)]],sampler p1 [[sampler(1)]]){
 float4 c=v.color,factor=argb(s.factor);
 if(s.texture[0]&&s.combine[0]!=2)c=combine(t0.sample(p0,v.uv),c,s.combine[0],0,factor);
 if(s.texture[1]&&s.combine[1]!=0&&s.combine[1]!=2)c=combine(t1.sample(p1,v.uv1),c,s.combine[1],1,factor);
 if(s.alpha_ref&&!compare_alpha(c.a,float(s.alpha_ref&255)/255.0,s.alpha_func))discard_fragment();
 if(s.shade==2)c.rgb+=v.spec.rgb;
 if(s.fog){float f=v.spec.a;
  if(s.fog_mode==4)f=exp(-v.fogz*s.fog_density);
  else if(s.fog_mode==8){float d=v.fogz*s.fog_density;f=exp(-d*d);}
  c.rgb=mix(argb(s.fog_color).rgb,c.rgb,clamp(f,0.0,1.0));
 }
 c.rgb*=s.brightness;return saturate(c);
}

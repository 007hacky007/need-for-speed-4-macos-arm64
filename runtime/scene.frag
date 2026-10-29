#version 450
layout(location=0) noperspective in vec4 color;
layout(location=1) noperspective in vec4 specular;
layout(location=2) in vec2 uv;
layout(location=3) in vec2 uv1;
layout(location=4) in float fogz;
layout(location=0) out vec4 output_color;
layout(std430,set=0,binding=0) readonly buffer State {
 uint cull,depth,depth_write,depth_func,blend,src_blend,dst_blend;
 uint alpha_ref,alpha_func,shade,combine[2],filter_mode[2],mip[2],address_u[2],address_v[2];
 uint texture_id[2],factor,fog,fog_color,fog_mode;
 float fog_density,brightness;
 uint stencil,stencil_func,stencil_fail,stencil_zfail,stencil_pass,depth_only;
 int clip[4];
} s;
layout(set=0,binding=1) uniform sampler2D t0;
layout(set=0,binding=2) uniform sampler2D t1;
vec4 argb(uint c){return vec4((c>>16)&255,(c>>8)&255,c&255,c>>24)/255.0;}
vec4 combine(vec4 t,vec4 c,uint mode,uint stage,vec4 factor){
 switch(mode){
 case 0:return stage==0?t*c:c;
 case 1:return t+c;
 case 2:return c;
 case 3:return t*c;
 case 4:return vec4(t.rgb-c.rgb,t.a);
 case 5:return vec4(c.rgb,1.0-t.a+c.a-0.5);
 case 6:return t*c*2.0;
 case 7:return t*c*4.0;
 case 8:return stage==0?t*c:vec4(mix(c.rgb,t.rgb,t.a),c.a);
 case 0x61:return t+c-0.5;
 case 0x62:return vec4(t.rgb+c.rgb,mix(factor.a,t.a,factor.a));
 case 0x63:return vec4(mix(c.rgb,t.rgb,factor.a),t.a);
 default:return c;
 }
}
bool compare_alpha(float a,float b,uint fn){switch(fn){case 0:return false;case 1:return a<b;case 2:return a==b;case 3:return a<=b;case 4:return a>b;case 5:return a!=b;case 6:return a>=b;default:return true;}}
void main(){
 vec4 c=color,factor=argb(s.factor);
 if(s.texture_id[0]!=0&&s.combine[0]!=2)c=combine(texture(t0,uv),c,s.combine[0],0,factor);
 if(s.texture_id[1]!=0&&s.combine[1]!=0&&s.combine[1]!=2)c=combine(texture(t1,uv1),c,s.combine[1],1,factor);
 if(s.alpha_ref!=0&&!compare_alpha(c.a,float(s.alpha_ref&255)/255.0,s.alpha_func))discard;
 if(s.shade==2)c.rgb+=specular.rgb;
 if(s.fog!=0){float f=specular.a;
  if(s.fog_mode==4)f=exp(-fogz*s.fog_density);
  else if(s.fog_mode==8){float d=fogz*s.fog_density;f=exp(-d*d);}
  c.rgb=mix(argb(s.fog_color).rgb,c.rgb,clamp(f,0.0,1.0));
 }
 c.rgb*=s.brightness;output_color=clamp(c,0.0,1.0);
}

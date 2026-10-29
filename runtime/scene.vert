#version 450
layout(location=0) in vec4 position;
layout(location=1) in uvec2 colors;
layout(location=2) in vec4 texcoord;
layout(push_constant) uniform Size {vec2 size;} screen;
layout(location=0) noperspective out vec4 color;
layout(location=1) noperspective out vec4 specular;
layout(location=2) out vec2 uv;
layout(location=3) out vec2 uv1;
layout(location=4) out float fogz;
vec4 argb(uint c){return vec4((c>>16)&255,(c>>8)&255,c&255,c>>24)/255.0;}
void main(){
 float w=position.w!=0?1.0/position.w:1.0;
 gl_Position=vec4((2.0*(position.xy+0.5)/screen.size-1.0)*w,position.z*w,w);
 gl_PointSize=1.0;color=argb(colors.x);specular=argb(colors.y);uv=texcoord.xy;uv1=texcoord.zw;fogz=w;
}

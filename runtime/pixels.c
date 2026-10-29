#include "render.h"
#include <string.h>
size_t render_pixel_bytes(unsigned f,unsigned w,unsigned h){
 if(!w||!h||w>4096||h>4096)return 0;
 size_t count=(size_t)w*h;
 switch(f){case 1:return (count+1)/2;case 2:return count;case 3:case 4:case 7:return count*2;case 5:return count*3;case 6:return count*4;default:return 0;}
}
int render_pixels(unsigned f,unsigned w,unsigned h,const void *source,size_t bytes,const uint32_t *pal,uint32_t *out){
 size_t need=render_pixel_bytes(f,w,h);if(!need||bytes<need||!source||!out||((f==1||f==2)&&!pal))return 0;
 const uint8_t *p=source;
 for(size_t i=0;i<(size_t)w*h;i++){
  uint32_t c=0;
  if(f==1||f==2)c=0xff000000| (pal[f==1?((p[i/2]>>(4*(i%2)))&15):p[i]]&0xffffff);
  else if(f==5)c=0xff000000|p[i*3]|(p[i*3+1]<<8)|(p[i*3+2]<<16);
  else if(f==6)memcpy(&c,p+i*4,4);
  else{
   uint16_t v;memcpy(&v,p+i*2,2);unsigned r,g,b,a;
   if(f==4){r=(v>>11)&31;g=(v>>5)&63;b=v&31;a=255;r=(r<<3)|(r>>2);g=(g<<2)|(g>>4);b=(b<<3)|(b>>2);}
   else if(f==3){r=(v>>10)&31;g=(v>>5)&31;b=v&31;a=(v&0x8000)?255:0;r=(r<<3)|(r>>2);g=(g<<3)|(g>>2);b=(b<<3)|(b>>2);}
   else{r=((v>>8)&15)*17;g=((v>>4)&15)*17;b=(v&15)*17;a=(v>>12)*17;}
   c=(a<<24)|(r<<16)|(g<<8)|b;
  }
  out[i]=c;
 }
 return 1;
}

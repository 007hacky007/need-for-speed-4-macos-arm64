#include "display.h"
#include <math.h>
DisplayRect display_fit(unsigned w,unsigned h,double vw,double vh){
    if(!w||!h||vw<=0||vh<=0)return (DisplayRect){0};
    double scale=fmin(vw/w,vh/h),width=w*scale,height=h*scale;
    return (DisplayRect){(vw-width)/2,(vh-height)/2,width,height};
}
void display_mouse(unsigned w,unsigned h,double vw,double vh,double px,double py,int *x,int *y){
    *x=*y=0;if(!w||!h||vw<=0||vh<=0)return;
    *x=(int)fmax(0,fmin(w-1,floor(px*w/vw)));
    *y=(int)fmax(0,fmin(h-1,floor(py*h/vh)));
}

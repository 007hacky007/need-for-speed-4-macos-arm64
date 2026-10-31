#include "display.h"
#include <math.h>
DisplayRect display_fit(unsigned w,unsigned h,double vw,double vh){
    if(!w||!h||vw<=0||vh<=0)return (DisplayRect){0};
    double scale=fmin(vw/w,vh/h),width=w*scale,height=h*scale;
    return (DisplayRect){(vw-width)/2,(vh-height)/2,width,height};
}
/* Converts host pointer motion in view points to whole game pixels, keeping
   the fraction so slow trackpad motion is not lost. */
int display_motion(double delta,double pixels_per_point,double *remainder){
    if(!(pixels_per_point>0)||!isfinite(delta))return 0;
    double total=*remainder+delta*pixels_per_point,whole=trunc(total);
    *remainder=total-whole;return (int)whole;
}

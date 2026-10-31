#ifndef NFSIV_DISPLAY_H
#define NFSIV_DISPLAY_H
typedef struct {double x,y,w,h;} DisplayRect;
DisplayRect display_fit(unsigned,unsigned,double,double);
int display_motion(double,double,double *);
#endif

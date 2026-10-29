#ifndef NFSIV_THRASH_H
#define NFSIV_THRASH_H
#include "runtime.h"
#define THRASH_MODULE 0xd1000000u
uint32_t thrash_proc(const char *);
unsigned thrash_requested_mode(void);
void thrash_call(CPU *,uint32_t);
#endif

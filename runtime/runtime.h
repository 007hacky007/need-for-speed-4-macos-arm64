#ifndef NFSIV_RUNTIME_H
#define NFSIV_RUNTIME_H
#include "cpu.h"
int mem_valid(uint32_t address, uint64_t size);
void *guest_ptr(uint32_t address, uint64_t size);
void guest_backtrace(CPU *, int);
void runtime_fail(CPU *, const char *, uint32_t);
void dispatch_init(void);
void platform_init(void);
void platform_call(CPU *, uint32_t);
void guest_stack_register(uint32_t base,uint32_t size);
uint32_t call_guest(CPU *, uint32_t, int, const uint32_t *);
uint32_t win32_alloc(uint32_t, int);
void win32_set_last_error(CPU *, uint32_t);
extern CPU *g_cur_cpu;
extern uint32_t g_image_base, g_image_size;
#endif

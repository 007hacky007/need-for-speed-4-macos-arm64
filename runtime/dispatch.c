#include "runtime.h"
#include "image.h"
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

extern const uint32_t g_fn_count, g_fn_addr[];
extern const guest_fn_t g_fn_ptr[];
guest_fn_t g_dtab[DISPATCH_TEXT_SIZE];

void dispatch_init(void){
    for (uint32_t i = 0; i < g_fn_count; i++){
        uint32_t offset = g_fn_addr[i] - DISPATCH_TEXT_BASE;
        if (offset >= DISPATCH_TEXT_SIZE){ fputs("generated function outside image\n", stderr); exit(1); }
        g_dtab[offset] = g_fn_ptr[i];
    }
    fprintf(stderr, "%u native functions bound\n", g_fn_count);
}

void guest_backtrace(CPU *c, int count){
    if (!c) return;
    fprintf(stderr, "  eax=%08x ebx=%08x ecx=%08x edx=%08x\n  esp=%08x ebp=%08x esi=%08x edi=%08x eip=%08x\n",
            c->eax, c->ebx, c->ecx, c->edx, c->esp, c->ebp, c->esi, c->edi, c->eip);
    for (int i = 0; i < 256 && count; i++){
        uint32_t p = c->esp + (uint32_t)i * 4;
        if (!mem_valid(p, 4)) break;
        uint32_t value = MR32(p);
        if (value >= DISPATCH_TEXT_BASE && value < DISPATCH_TEXT_BASE + DISPATCH_TEXT_SIZE){
            fprintf(stderr, "  stack +%03x: %08x\n", i * 4, value); count--;
        }
    }
    uint64_t end = g_itrace_n;
    uint64_t n = end < 16 ? end : 16;
    fputs("  recent instructions:", stderr);
    for (uint64_t i = end - n; i < end; i++) fprintf(stderr, " %08x", g_itrace[i & ITRACE_MASK]);
    fputc('\n', stderr);
}

void runtime_fail(CPU *c, const char *reason, uint32_t address){
    fprintf(stderr, "\nNFSIV stopped: %s at %08x (last guest instruction %08x)\n", reason, address, g_watch_prev_ip);
    guest_backtrace(c, 16);
    exit(3);
}

void unsupported_insn(CPU *c, uint32_t address, const char *mnemonic){ runtime_fail(c, mnemonic, address); }
#include "patches.h"
void guest_hook(CPU *c, uint32_t ip){ if(!native_patch_hook(c,ip))runtime_fail(c, "unregistered instruction hook", ip); }

void dispatch_indirect(CPU *c, uint32_t address){
    guest_fn_t fn = dispatch_fast(address);
    if (fn){ fn(c); return; }
    if (address >= 0xf0000000u){ platform_call(c, address - 0xf0000000u); return; }
    if ((address&0xff000000u)==0xe1000000u){ void com_call(CPU *,uint32_t);com_call(c,address);return; }
    if ((address&0xff000000u)==0xe2000000u){ void thrash_call(CPU *,uint32_t);thrash_call(c,address);return; }
    runtime_fail(c, "unresolved guest call", address);
}
void dispatch_tail(CPU *c){ dispatch_indirect(c, c->eip); }

uint32_t call_guest(CPU *c, uint32_t fn, int count, const uint32_t *args){
    uint32_t saved_sp = c->esp, saved_ip = c->eip;
    for (int i = count - 1; i >= 0; i--) PUSH32(args[i]);
    PUSH32(0xdeadc0deu);
    dispatch_indirect(c, fn);
    if (c->esp != saved_sp || c->eip != 0xdeadc0deu) runtime_fail(c, "callback stack imbalance", fn);
    c->eip = saved_ip;
    return c->eax;
}

void cpuid_shim(CPU *c){
    switch (c->eax){
    case 0: c->eax=1; c->ebx=0x756e6547; c->edx=0x49656e69; c->ecx=0x6c65746e; break;
    case 1: c->eax=0x000006d8; c->ebx=0; c->ecx=0; c->edx=0x0383fbff; break;
    default: c->eax=c->ebx=c->ecx=c->edx=0; break;
    }
}
uint64_t rdtsc_shim(void){
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return ((uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec) / 2;
}

/* Reserved guest address space and hash-checked mapping of generated PE metadata. */
#include "cpu.h"
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#ifndef NFSIV_NO_IMAGE
#include "image.h"
#include <CommonCrypto/CommonDigest.h>
#endif

uint8_t *g_mem;
uint8_t g_cbits[1u << 15];
CPU *g_cur_cpu;
uint32_t g_image_base, g_image_size, g_res_dir_va, g_res_dir_size;
uint32_t g_itrace[ITRACE_SIZE];
uint64_t g_itrace_n;
uint32_t g_watch_addr, g_watch_val, g_watch_prev_ip;
uint32_t *g_cov, g_last_fn;
int g_prof_on;
__attribute__((weak)) void guest_backtrace(CPU *c, int n){ (void)c; (void)n; }
void watch_report_change(uint32_t ip, uint32_t old, uint32_t value){
    fprintf(stderr, "guest write at %08x: %08x -> %08x\n", ip, old, value);
}

int mem_valid(uint32_t address, uint64_t size){
    uint64_t end = (uint64_t)address + size;
    if (end > GSZ || end < address) return 0;
    if (!size) return 1;
    uint64_t page = address & ~0x3fffull;
    for (; page < end; page += 0x4000) if (!mem_is_committed((uint32_t)page)) return 0;
    return 1;
}

void *guest_ptr(uint32_t address, uint64_t size){
    if (!address || !mem_valid(address, size)){
        fprintf(stderr, "invalid guest pointer %08x + %llu at %08x\n", address,
                (unsigned long long)size, g_watch_prev_ip);
        guest_backtrace(g_cur_cpu, 16);
        exit(3);
    }
    return g_mem + address;
}

void mem_init(void){
    if (g_mem) return;
    if (getpagesize() != 16384){
        fputs("this runtime requires the Apple Silicon 16 KB page size\n", stderr);
        exit(1);
    }
    g_mem = mmap(NULL, GSZ, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0);
    if (g_mem == MAP_FAILED){ perror("reserve guest memory"); exit(1); }
}

void mem_commit(uint32_t address, uint32_t size){
    uint64_t lo = address & ~0x3fffull;
    uint64_t hi = ((uint64_t)address + size + 0x3fff) & ~0x3fffull;
    if (!size) return;
    if (!g_mem || hi > GSZ || mprotect(g_mem + lo, hi - lo, PROT_READ | PROT_WRITE)){
        fprintf(stderr, "cannot commit guest memory %08x + %u\n", address, size);
        exit(1);
    }
    for (uint64_t a = lo; a < hi; a += 0x4000){
        uint32_t page = (uint32_t)(a >> 14);
        g_cbits[page >> 3] |= 1u << (page & 7);
    }
}

void mem_release(uint32_t address, uint32_t size, int rw){
    uint64_t lo = ((uint64_t)address + 0x3fff) & ~0x3fffull;
    uint64_t hi = ((uint64_t)address + size) & ~0x3fffull;
    if (hi <= lo) return;
    if (hi > GSZ){ fputs("invalid guest release range\n", stderr); exit(1); }
    if (mmap(g_mem + lo, hi - lo, rw ? PROT_READ | PROT_WRITE : PROT_NONE,
             MAP_FIXED | MAP_PRIVATE | MAP_ANON, -1, 0) == MAP_FAILED){
        perror("release guest memory"); exit(1);
    }
    for (uint64_t a = lo; a < hi; a += 0x4000){
        uint32_t page = (uint32_t)(a >> 14), mask = 1u << (page & 7);
        if (rw) g_cbits[page >> 3] |= mask;
        else g_cbits[page >> 3] &= ~mask;
    }
}

static void fault(int sig, siginfo_t *info, void *context){
    (void)context;
    fprintf(stderr, "guest fault: signal %d, address offset %llx, instruction %08x\n", sig,
            (unsigned long long)((uintptr_t)info->si_addr - (uintptr_t)g_mem), g_watch_prev_ip);
    guest_backtrace(g_cur_cpu, 16);
    _exit(3);
}

void mem_altstack_install(void){
    stack_t ss = {.ss_sp = malloc(SIGSTKSZ * 8), .ss_size = SIGSTKSZ * 8};
    if (!ss.ss_sp || sigaltstack(&ss, NULL)){ perror("guest signal stack"); exit(1); }
}

void mem_fault_handler_install(void){
    mem_altstack_install();
    struct sigaction sa = {.sa_sigaction = fault, .sa_flags = SA_SIGINFO | SA_ONSTACK};
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, NULL) || sigaction(SIGBUS, &sa, NULL)){
        perror("guest signal handler"); exit(1);
    }
}

#ifndef NFSIV_NO_IMAGE
int mem_load_pe(const char *path){
    FILE *f = fopen(path, "rb");
    if (!f){ perror(path); return -1; }
    uint8_t *data = malloc(IMAGE_FILE_SIZE);
    if (!data){ fclose(f); return -1; }
    int ok = fread(data, 1, IMAGE_FILE_SIZE, f) == IMAGE_FILE_SIZE && fgetc(f) == EOF;
    fclose(f);
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    char hex[65];
    if (ok){
        CC_SHA256(data, IMAGE_FILE_SIZE, digest);
        for (unsigned i = 0; i < sizeof digest; i++) snprintf(hex + 2 * i, 3, "%02x", digest[i]);
        ok = !strcmp(hex, IMAGE_SHA256);
    }
    if (!ok){ fputs("unsupported executable: size or SHA-256 differs from this build\n", stderr); free(data); return -1; }
    mem_init();
    mem_commit(IMAGE_BASE, IMAGE_SIZE);
    memcpy(g_mem + IMAGE_BASE, data, 4096);
    for (uint32_t i = 0; i < nfsiv_section_count; i++){
        const ImageSection *s = &nfsiv_sections[i];
        memcpy(g_mem + s->address, data + s->offset, s->size);
    }
    uint32_t nt, resource_rva, resource_size;
    memcpy(&nt,data+0x3c,4);
    memcpy(&resource_rva,data+nt+24+96+16,4);
    memcpy(&resource_size,data+nt+24+96+20,4);
    free(data);
    g_image_base = IMAGE_BASE; g_image_size = IMAGE_SIZE;
    g_res_dir_va=resource_rva ? IMAGE_BASE+resource_rva : 0; g_res_dir_size=resource_size;
    fprintf(stderr, "verified PE mapped at %08x, entry %08x\n", IMAGE_BASE, IMAGE_ENTRY);
    return 0;
}
#endif

#ifndef NFSIV_PATCHES_H
#define NFSIV_PATCHES_H
#include "cpu.h"
/* Instruction hooks for the checksum-pinned VEG 4.50 baseline. */
#define NFSIV_PATCH_RACE_MODE 0x4f73d6u
#define NFSIV_PATCH_MOUSE 0x46d781u
#define NFSIV_PATCH_POLL 0x46de06u
int native_patch_hook(CPU *,uint32_t);
#endif

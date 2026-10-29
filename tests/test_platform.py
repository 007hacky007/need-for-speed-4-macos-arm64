from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PlatformTests(unittest.TestCase):
    def test_unicode_module_path_uses_wide_characters_and_capacity(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            (directory / 'image.h').write_text('''
#include <stdint.h>
#define IMAGE_BASE 0x400000u
#define SOUND_MODULE 0x1100000u
typedef struct {uint32_t iat;const char *dll,*name;int nargs;} Import;
typedef struct {const char *name;uint32_t address;} GuestExport;
extern const Import nfsiv_imports[];
extern const uint32_t nfsiv_import_count,nfsiv_sound_export_count;
extern const GuestExport nfsiv_sound_exports[];
''')
            source = directory / 'check.c'
            source.write_text(r'''
#include "runtime/platform.c"
uint8_t *g_mem;
uint8_t g_cbits[1u<<15];
uint32_t g_watch_prev_ip;
CPU *g_cur_cpu;
const Import nfsiv_imports[1];
const GuestExport nfsiv_sound_exports[1];
const uint32_t nfsiv_import_count=0,nfsiv_sound_export_count=0;
void *guest_ptr(uint32_t p,uint64_t n){if(p+n>65536)abort();return g_mem+p;}
void heap_init(void){}
uint32_t gheap_alloc(int h,uint32_t n,int z){static uint32_t next=8192;uint32_t p=next;next+=n;if(next>65536)abort();return p;}
int main(void){
    g_mem=calloc(1,65536);CPU cpu={.esp=64};
    MR32(64)=0;MR32(68)=1024;MR32(72)=260;
    Import imp={.dll="KERNEL32.dll",.name="GetModuleFileNameW",.nargs=3};uint32_t result=0;
    if(!core_call(&cpu,&imp,&result))return 1;
    const char *expected="C:\\NFSIV\\nfs4.exe";
    if(result!=strlen(expected))return 2;
    for(unsigned i=0;i<=strlen(expected);i++)if(MR16(1024+2*i)!=(uint8_t)expected[i])return 3;
    MR32(72)=4;MR16(1032)=0xabcd;
    if(!core_call(&cpu,&imp,&result)||MR16(1032)!=0xabcd)return 4;
    platform_init();imp.name="GetCommandLineW";
    if(!core_call(&cpu,&imp,&result)||!result)return 5;
    const char *command="nfs4.exe";
    for(unsigned i=0;i<=strlen(command);i++)if(MR16(result+2*i)!=(uint8_t)command[i])return 6;
    imp.name="CharUpperBuffA";MR32(64)=1024;MR32(68)=3;
    MR8(1024)='a';MR8(1025)=0;MR8(1026)=0xe9;MR8(1027)='z';
    if(!core_call(&cpu,&imp,&result)||result!=3)return 7;
    if(MR8(1024)!='A'||MR8(1025)||MR8(1026)!=0xc9||MR8(1027)!='z')return 8;
    cpu.fs_base=6000;imp.name="SetWindowsHookExA";MR32(64)=2;
    if(!core_call(&cpu,&imp,&result)||result||MR32(6000+0x34)!=120)return 9;
    imp.name="CompareFileTime";MR32(64)=1024;MR32(68)=1040;
    uint64_t left=0x8000000000000001ull,right=0x8000000000000002ull;
    memcpy(g_mem+1024,&left,8);memcpy(g_mem+1040,&right,8);
    if(!core_call(&cpu,&imp,&result)||(int32_t)result!=-1)return 10;
    memcpy(g_mem+1024,&right,8);if(!core_call(&cpu,&imp,&result)||result)return 11;
    return 0;
}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-I', str(directory),
                            '-Wl,-undefined,dynamic_lookup', str(source), '-o', str(binary)],
                           check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

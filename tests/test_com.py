from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ComTests(unittest.TestCase):
    def test_native_directdraw_probe_creates_and_releases_primary_surface(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            source = directory / 'check.c'
            source.write_text(r'''
#include "runtime/com.c"
uint8_t *g_mem;
uint8_t g_cbits[1u<<15];
uint32_t g_watch_prev_ip;
CPU *g_cur_cpu;
void *guest_ptr(uint32_t p,uint64_t n){if(p+n>65536)abort();return g_mem+p;}
int mem_valid(uint32_t p,uint64_t n){return p+n<=65536;}
uint32_t win32_alloc(uint32_t n,int z){static uint32_t next=8192;uint32_t p=next;next+=n;if(next>65536)abort();return p;}
void gheap_free(int h,uint32_t p){}
int sound_platform_call(CPU *c,const char*d,const char*n,uint32_t*out){return 0;}
int main(void){
 g_mem=calloc(1,65536);CPU cpu={.esp=64};g_cur_cpu=&cpu;
 MR32(64)=0;MR32(68)=1024;MR32(72)=0;uint32_t r=99;
 if(!com_platform_call(&cpu,"DDRAW.dll","DirectDrawCreate",&r)||r||!MR32(1024))return 1;
 uint32_t draw=MR32(1024);
 cpu.esp=64;MR32(64)=0xdeadc0de;MR32(68)=draw;MR32(72)=2048;MR32(76)=4096;MR32(80)=0;
 MR32(2048)=108;MR32(2052)=1;MR32(2048+104)=0x200;
 com_call(&cpu,0xe1000000u+(3<<12)+6);
 if(cpu.eax||cpu.esp!=84||!MR32(4096))return 2;
 uint32_t surface=MR32(4096);
 cpu.esp=64;MR32(64)=0xdeadc0de;MR32(68)=surface;
 com_call(&cpu,0xe1000000u+(6<<12)+2);
 if(cpu.eax||cpu.esp!=72)return 3;
 return 0;
}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

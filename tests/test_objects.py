from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ObjectTests(unittest.TestCase):
    def test_open_named_mutex_observes_creation_and_final_close(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            source = directory / 'check.c'
            source.write_text(r'''
#include "runtime/win32_ext.c"
uint8_t *g_mem;
uint8_t g_cbits[1u<<15];
uint32_t g_watch_prev_ip,g_watch_addr,g_watch_val;
CPU *g_cur_cpu;
uint32_t host_ms(void){return 0;}
uint64_t host_us(void){return 0;}
void *guest_ptr(uint32_t p,uint64_t n){if(p+n>65536)abort();return g_mem+p;}
void win32_set_last_error(CPU *c,uint32_t v){MR32(c->fs_base+0x34)=v;}
int main(void){
 g_mem=calloc(1,65536);CPU cpu={.esp=64,.fs_base=2048};g_cur_cpu=&cpu;
 memset(g_cbits,255,sizeof g_cbits);MR32(2048+0x24)=1;
 strcpy((char*)g_mem+1024,"game-instance");MR32(64)=0;MR32(68)=0;MR32(72)=1024;
 uint32_t h=99,r=99;
 if(!win32_ext_call(&cpu,"OpenMutexA",&r)||r||MR32(2048+0x34)!=2)return 1;
 if(!win32_ext_call(&cpu,"CreateMutexA",&h)||!h)return 2;
 if(!win32_ext_call(&cpu,"OpenMutexA",&r)||r!=h)return 3;
 MR32(64)=h;win32_ext_call(&cpu,"CloseHandle",&r);
 MR32(64)=0;if(!win32_ext_call(&cpu,"OpenMutexA",&r)||r!=h)return 4;
 MR32(64)=h;win32_ext_call(&cpu,"CloseHandle",&r);win32_ext_call(&cpu,"CloseHandle",&r);
 MR32(64)=0;if(!win32_ext_call(&cpu,"OpenMutexA",&r)||r)return 5;
 return 0;
}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

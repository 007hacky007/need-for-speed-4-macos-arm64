from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ThrashTests(unittest.TestCase):
    def test_unsupported_extended_states_are_rejected_like_the_original_driver(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            source = directory / 'check.c'
            source.write_text(r'''
#include "runtime/thrash.c"
uint8_t *g_mem;
uint8_t g_cbits[1u<<15];
uint32_t g_watch_prev_ip;
CPU *g_cur_cpu;
void runtime_fail(CPU *c,const char *reason,uint32_t address){exit(20);}
int main(void){
 setenv("NFSIV_RESOLUTION","800x600",1);if(thrash_requested_mode()!=7)return 11;
 setenv("NFSIV_RESOLUTION","1280x960",1);unsigned mode=thrash_requested_mode();if(!mode)return 12;
 setenv("NFSIV_RESOLUTION","bad",1);if(thrash_requested_mode())return 13;
 setenv("NFSIV_RESOLUTION","800x600junk",1);if(thrash_requested_mode())return 14;
 unsetenv("NFSIV_RESOLUTION");if(thrash_requested_mode())return 15;
 if(set_state(NULL,0x2c2,1)!=0)return 1;
 if(set_state(NULL,0x2c3,0)!=0)return 2;
 if(set_state(NULL,4,1)!=1||!rs.depth)return 3;
 return 0;
}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

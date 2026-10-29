from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StackQueryTests(unittest.TestCase):
    def test_stack_allocation_base_is_not_the_page_containing_the_stack_pointer(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            source = directory / 'check.c'
            source.write_text(r'''
#include "runtime/heap.c"
uint8_t *g_mem;
uint8_t g_cbits[1u<<15];
uint32_t g_watch_prev_ip,g_image_base,g_image_size;
void mem_commit(uint32_t p,uint32_t n){}
void win32_set_last_error(CPU *c,uint32_t v){}
int main(void){
 g_mem=calloc(1,262144);g_cbits[0]=0xf0;g_cbits[1]=0x0f;
 guest_stack_register(0x10000,0x10000);guest_stack_register(0x20000,0x10000);
 if(virtual_query(0x1ff80,128,28)!=28)return 1;
 if(MR32(128)!=0x10000||MR32(132)!=0x10000||MR32(140)!=0x10000)return 2;
 if(virtual_query(0x2ff80,128,28)!=28||MR32(132)!=0x20000||MR32(140)!=0x10000)return 3;
 return 0;
}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

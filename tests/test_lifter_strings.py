from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.lift import RawLifter

ROOT = Path(__file__).resolve().parents[1]


class StringInstructionTests(unittest.TestCase):
    def run_copy(self, instruction, count, size):
        code, _ = RawLifter(bytes.fromhex(instruction + 'c3')).lift(0x401000)
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            source = directory / 'check.c'
            source.write_text('''
#define NFSIV_NO_IMAGE
#include "runtime/cpu.h"
#include <stdlib.h>
uint8_t *g_mem;uint8_t g_cbits[1u<<15];
uint32_t g_watch_addr,g_watch_val,g_watch_prev_ip;
''' + code + f'''
int main(void){{
    g_mem=calloc(1,65536);memset(g_cbits,255,sizeof g_cbits);
    for(unsigned i=0;i<{size};i++)g_mem[2048+i]=(unsigned char)(i+1);
    for(unsigned zf=0;zf<2;zf++){{
        memset(g_mem+4096,0,{size});
        CPU cpu={{.esp=1024,.esi=2048,.edi=4096,.ecx={count},.zf=zf}};
        MR32(1024)=0xdeadc0de;sub_00401000(&cpu);
        if(memcmp(g_mem+2048,g_mem+4096,{size})||cpu.ecx||cpu.esi!=2048+{size}||cpu.edi!=4096+{size})return 1;
        if(cpu.zf!=zf)return 2;
    }}
    CPU empty={{.esp=1024,.esi=0xffffffff,.edi=0xffffffff,.ecx=0}};
    MR32(1024)=0xdeadc0de;sub_00401000(&empty);
    return empty.esi!=0xffffffff||empty.edi!=0xffffffff?3:0;
}}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_f2_dword_copy_repeats_despite_capstone_missing_prefix(self):
        self.run_copy('f2a5', 3, 12)

    def test_f2_byte_copy_ignores_zero_flag(self):
        self.run_copy('f2a4', 7, 7)

    def test_f3_dword_copy_remains_correct(self):
        self.run_copy('f3a5', 3, 12)

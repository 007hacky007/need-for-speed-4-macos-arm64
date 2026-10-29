from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class PatchTests(unittest.TestCase):
    def test_silentpatch_preserves_errors_and_accepts_nonnegative_input_results(self):
        with tempfile.TemporaryDirectory() as t:
            folder = Path(t)
            source = folder / 'check.c'
            source.write_text(r'''
#include "runtime/patches.c"
uint8_t *g_mem;
static unsigned requested;
unsigned thrash_requested_mode(void){return requested;}
int main(void){
 g_mem=calloc(1,4096);CPU c={.ebp=64};
 setenv("NFSIV_SILENTPATCH","1",1);
 int values[]={0,1,128,-1,(int)0x8007001eu};
 for(unsigned i=0;i<5;i++){
  int value=values[i];MR32(c.ebp-12)=(uint32_t)value;c.zf=99;
  if(!native_patch_hook(&c,NFSIV_PATCH_MOUSE)||c.zf!=(value>=0))return 1;
  c.edi=(uint32_t)value;
  if(!native_patch_hook(&c,NFSIV_PATCH_POLL)||c.edi!=(value>=0?0u:(uint32_t)value))return 2;
 }
 setenv("NFSIV_SILENTPATCH","0",1);c.zf=9;c.edi=1;
 if(!native_patch_hook(&c,NFSIV_PATCH_MOUSE)||c.zf!=9)return 3;
 if(!native_patch_hook(&c,NFSIV_PATCH_POLL)||c.edi!=1)return 4;
 if(native_patch_hook(&c,123))return 5;
 c.eax=3;if(!native_patch_hook(&c,NFSIV_PATCH_RACE_MODE)||c.eax!=3)return 6;
 requested=7;setenv("NFSIV_RESOLUTION","800x600",1);if(!native_patch_hook(&c,NFSIV_PATCH_RACE_MODE)||c.eax!=7)return 7;
 free(g_mem);return 0;
}
''')
            binary = folder / 'check'
            build = subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                                    str(source), '-o', str(binary)], capture_output=True)
            self.assertEqual(build.returncode, 0, build.stderr.decode())
            result = subprocess.run([str(binary)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

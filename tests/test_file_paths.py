from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class FilePathTests(unittest.TestCase):
    def test_virtual_absolute_paths_resolve_inside_game_root(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            (directory / 'settings.ini').write_text('[game]\n')
            source = directory / 'check.c'
            source.write_text(r'''
#include "runtime/fileio.c"
uint8_t *g_mem;
uint8_t g_cbits[1u<<15];
uint32_t g_watch_prev_ip;
int mem_valid(uint32_t p,uint64_t n){return p+n<=65536;}
void mem_commit(uint32_t p,uint32_t n){}
int main(int argc,char **argv){
    char output[1024], expected[1024];
    snprintf(expected,sizeof expected,"%s/settings.ini",argv[1]);
    if(!resolve_in(argv[1],"C:\\NFSIV\\settings.ini",output,sizeof output))return 1;
    if(strcmp(output,expected))return 2;
    if(!resolve_in(argv[1],"..\\..\\settings.ini",output,sizeof output))return 3;
    if(strcmp(output,expected))return 4;
    g_mem=calloc(1,65536);memset(g_cbits,255,sizeof g_cbits);CPU cpu={.esp=4096};
    snprintf(output,sizeof output,"%s/nfs4.exe",argv[1]);fileio_set_root(output);
    strcpy((char*)g_mem+1024,"settings.ini");MR32(4096)=1024;MR32(4100)=0;uint32_t handle=0;
    if(!fileio_call(&cpu,"_lopen",&handle)||handle==0xffffffff||!handle||cpu.esp!=4096)return 5;
    MR32(4096)=handle;uint32_t result=99;
    if(!fileio_call(&cpu,"_lclose",&result)||result)return 6;
    return 0;
}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary), str(directory)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

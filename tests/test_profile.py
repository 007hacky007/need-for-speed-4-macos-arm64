from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProfileTests(unittest.TestCase):
    def test_case_insensitive_values_quotes_defaults_and_bounded_output(self):
        with tempfile.TemporaryDirectory() as t:
            directory = Path(t)
            ini = directory / 'settings.ini'
            ini.write_text('; comment\n[NFS4]\nLanguage = "english"\nNoMovies=0\n[Thrash]\nFile=dx7a.dll\n')
            source = directory / 'check.c'
            source.write_text(r'''
#include "runtime/profile.c"
uint8_t *g_mem;
uint8_t g_cbits[1u<<15];
uint32_t g_watch_prev_ip;
CPU *g_cur_cpu;
void *guest_ptr(uint32_t p,uint64_t n){if(p+n>65536)abort();return g_mem+p;}
void win32_set_last_error(CPU *c,uint32_t v){}
int fileio_resolve_save(const char *name,char *out,size_t capacity){snprintf(out,capacity,"%s",name);return 1;}
int main(int argc,char **argv){
 char value[64];
 if(profile_value(argv[1],"nfs4","LANGUAGE",value,sizeof value)!=7||strcmp(value,"english"))return 1;
 if(profile_value(argv[1],"NFS4","missing",value,sizeof value)!=-1)return 2;
 char small[4]={'x','x','x','z'};
 if(profile_value(argv[1],"Thrash","File",small,3)!=2||strcmp(small,"dx")||small[3]!='z')return 3;
 g_mem=calloc(1,65536);CPU cpu={.esp=64};uint32_t result=0;
 strcpy((char*)g_mem+1024,"Thrash");strcpy((char*)g_mem+5000,argv[1]);
 MR32(64)=1024;MR32(68)=2048;MR32(72)=64;MR32(76)=5000;
 if(!profile_call(&cpu,"GetPrivateProfileSectionA",&result))return 4;
 if(strcmp((char*)g_mem+2048,"File=dx7a.dll")||MR8(2048+14))return 5;
 MR32(72)=6;MR8(2054)=0xab;
 if(!profile_call(&cpu,"GetPrivateProfileSectionA",&result)||result!=4||MR8(2052)||MR8(2053)||MR8(2054)!=0xab)return 6;
 return 0;
}
''')
            binary = directory / 'check'
            subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                            str(source), '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary), str(ini)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())

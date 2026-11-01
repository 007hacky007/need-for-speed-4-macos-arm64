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


class AddonOverlayTests(unittest.TestCase):
    """A community profile runs from the bundle: the add-on's overlay folder is
    read before the game folder, saves stay in the write root, nothing is copied."""

    def test_addon_overlay_is_read_in_place_and_merged_into_listings(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            game, addon, saves = root / 'Game', root / 'Overlay', root / 'Saves'
            files = {
                game / 'Data/Cars/BASE/car.viv': b'base car',
                game / 'Data/Cars/SWAP/car.viv': b'original swap',
                game / 'Data/Cars/SWAP/fedata.eng': b'original text',
                game / 'Data/Movies/intro_en.vp6': b'game movie',
                addon / 'data/cars/swap/car.viv': b'addon swap',
                addon / 'data/cars/new/car.viv': b'addon new car',
                addon / 'data/feart/slides/t5_00.qfs': b'addon slide',
                addon / 'savedata/cars/new/car_en.fec': b'addon fec',
                root / 'outside.viv': b'outside',
            }
            for path, data in files.items():
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            (addon / 'data/cars/link.viv').symlink_to(root / 'outside.viv')
            snapshot = {p: p.read_bytes() for p in files}
            source = root / 'check.c'
            source.write_text(r'''
#include "runtime/fileio.c"
uint8_t *g_mem;
uint8_t g_cbits[1u<<15];
uint32_t g_watch_prev_ip;
static uint32_t last_error;
int mem_valid(uint32_t p,uint64_t n){return p+n<=1u<<20;}
void mem_commit(uint32_t p,uint32_t n){}
void win32_set_last_error(CPU *c,uint32_t e){last_error=e;}
void win32_signal_event(uint32_t h){}
static CPU cpu;
static uint32_t call(const char *name,uint32_t a0,uint32_t a1,uint32_t a2,uint32_t a3,uint32_t a4){
    uint32_t args[]={a0,a1,a2,a3,a4,0,0},out=0;cpu.esp=8192;
    for(int i=0;i<7;i++)MR32(cpu.esp+4*i)=args[i];
    if(!fileio_call(&cpu,name,&out)){fprintf(stderr,"%s not handled\n",name);exit(90);}
    return out;
}
static uint32_t text(const char *s){static uint32_t at=16384;uint32_t p=at;strcpy((char*)g_mem+p,s);at+=strlen(s)+1;return p;}
static int read_is(const char *guest,const char *expected){
    uint32_t h=call("CreateFileA",text(guest),0x80000000u,1,0,3);
    if(h==0xffffffffu)return 0;
    memset(g_mem+65536,0,256);
    call("ReadFile",h,65536,255,4096,0);
    call("CloseHandle",h,0,0,0,0);
    if(strcmp((char*)g_mem+65536,expected)){fprintf(stderr,"%s: \"%s\"\n",guest,(char*)g_mem+65536);return 0;}
    return 1;
}
int main(int argc,char **argv){
    g_mem=calloc(1,1u<<20);memset(g_cbits,255,sizeof g_cbits);
    char path[2048];
    snprintf(path,sizeof path,"%s/Game/nfs4.exe",argv[1]);fileio_set_root(path);
    snprintf(path,sizeof path,"%s/Saves",argv[1]);fileio_set_write_root(path);fileio_set_readonly_root(1);
    snprintf(path,sizeof path,"%s/Missing",argv[1]);if(fileio_set_addon_root(path)!=-1)return 1;
    snprintf(path,sizeof path,"%s/Overlay/",argv[1]);if(fileio_set_addon_root(path)!=4)return 2;
    if(!read_is("Data\\Cars\\BASE\\car.viv","base car"))return 3;          /* only the game has it */
    if(!read_is("C:\\NFSIV\\DATA\\CARS\\Swap\\CAR.VIV","addon swap"))return 4; /* the add-on wins, any case */
    if(!read_is("data\\cars\\swap\\fedata.eng","original text"))return 5;  /* the rest of that folder stays */
    if(!read_is("Data\\Cars\\NEW\\car.viv","addon new car"))return 6;      /* a folder only the add-on has */
    if(!read_is("SaveData\\Cars\\new\\car.fec","addon fec"))return 7;      /* language fallback through the add-on */
    if(!read_is("Data\\Movies\\intro_fr.vp6","game movie"))return 8;       /* and through the game folder */
    if(call("CreateFileA",text("Data\\Cars\\link.viv"),0x80000000u,1,0,3)!=0xffffffffu)return 9;   /* no symlinks */
    if(call("GetFileAttributesA",text("Data\\Cars\\New"),0,0,0,0)!=0x10u)return 10;
    /* a listing of Data\Cars: BASE and SWAP from the game, NEW from the add-on, each once */
    uint32_t find=text("Data\\Cars\\*.*"),data=0x40000;char names[512]="";
    uint32_t h=call("FindFirstFileA",find,data,0,0,0);if(h==0xffffffffu)return 11;
    int n=0;do{strcat(names,(char*)g_mem+data+44);strcat(names,";");n++;}while(call("FindNextFileA",h,data,0,0,0));
    call("FindClose",h,0,0,0,0);
    for(char *k=names;*k;k++)*k=(char)tolower((unsigned char)*k);
    if(n!=3||!strstr(names,"base;")||!strstr(names,"swap;")||!strstr(names,"new;")){fprintf(stderr,"listing: %s\n",names);return 12;}
    /* a write goes to the save folder (copied up from the add-on first), never into the add-on */
    h=call("CreateFileA",text("Data\\Cars\\new\\car.viv"),0xc0000000u,0,0,4);if(h==0xffffffffu)return 13;
    call("CloseHandle",h,0,0,0,0);
    snprintf(path,sizeof path,"%s/Saves/Data/Cars/new/car.viv",argv[1]);
    FILE *f=fopen(path,"rb");char copied[64]={0};if(!f)return 14;fread(copied,1,63,f);fclose(f);
    if(strcmp(copied,"addon new car"))return 15;
    h=call("FindFirstFileA",find,data,0,0,0);n=0;names[0]=0;
    do{strcat(names,(char*)g_mem+data+44);strcat(names,";");n++;}while(call("FindNextFileA",h,data,0,0,0));
    call("FindClose",h,0,0,0,0);if(n!=3){fprintf(stderr,"listing: %s\n",names);return 16;}   /* still each name once */
    if(!read_is("data\\cars\\new\\car.viv","addon new car"))return 17;      /* now the save folder's copy */
    return 0;
}
''')
            binary = root / 'check'
            built = subprocess.run(['clang', '-w', '-I', str(ROOT), '-Wl,-undefined,dynamic_lookup',
                                    str(source), '-o', str(binary)], capture_output=True)
            self.assertEqual(built.returncode, 0, built.stderr.decode())
            result = subprocess.run([str(binary), str(root)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertIn(b'add-on folder = ', result.stderr)
            self.assertEqual({p: p.read_bytes() for p in files}, snapshot)
            self.assertEqual(sorted(p.relative_to(addon).as_posix() for p in addon.rglob('*') if p.is_file()),
                             ['data/cars/link.viv', 'data/cars/new/car.viv', 'data/cars/swap/car.viv',
                              'data/feart/slides/t5_00.qfs', 'savedata/cars/new/car_en.fec'])

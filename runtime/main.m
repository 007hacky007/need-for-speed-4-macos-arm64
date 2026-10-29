#import <Cocoa/Cocoa.h>
#include "runtime.h"
#include "image.h"
#include "audio.h"
#include "render.h"
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

extern jmp_buf g_exit_jmp;
extern int g_exit_code, g_exit_armed;
void fileio_set_root(const char *);
void fileio_set_write_root(const char *);
void fileio_set_readonly_root(int);
void guest_lock(CPU *);
void guest_unlock(void);
static CPU cpu;
static int result;

static void deadline(int sig){
    (void)sig;
    fputs("NFSIV diagnostic time limit reached\n", stderr);
    fprintf(stderr,"guest instructions: %llu\n",(unsigned long long)g_itrace_n);
    const char *peek=getenv("NFSIV_PEEK");
    while(peek && *peek){
        char *next;unsigned long address=strtoul(peek,&next,0);if(next==peek)break;
        if(address<=0xfffffffc && mem_valid((uint32_t)address,4))fprintf(stderr,"guest [%08lx] = %08x\n",address,MR32((uint32_t)address));
        peek=*next==','?next+1:next;if(!*next)break;
    }
    guest_backtrace(g_cur_cpu,16);
    _exit(124);
}

static void *run_guest(void *arg){
    (void)arg;
    pthread_setname_np("NFSIV original game");
    mem_altstack_install();
    CPU *c=&cpu;
    c->fcw=0x37f; c->fs_base=0xc00000; c->esp=0x7ff00000;
    mem_commit(c->fs_base,0x20000);
    mem_commit(0x7f000000,0xf00000);
    guest_stack_register(0x7f000000,0xf00000);
    MR32(c->fs_base)=0xffffffff;
    MR32(c->fs_base+4)=c->esp; MR32(c->fs_base+8)=0x7f000000;
    MR32(c->fs_base+0x18)=c->fs_base; MR32(c->fs_base+0x20)=100; MR32(c->fs_base+0x24)=1;
    MR32(c->fs_base+0x2c)=c->fs_base+0x1000; MR32(c->fs_base+0x30)=0xc10000;
    MR32(0xc10008)=IMAGE_BASE;
    platform_init();
    guest_lock(c);
    if (setjmp(g_exit_jmp)==0){
        g_exit_armed=1;
        PUSH32(0xdeadc0de);
        dispatch_indirect(c,IMAGE_ENTRY);
        result=(int)c->eax;
        fprintf(stderr,"guest entry returned with %d\n",result);
    } else result=g_exit_code;
    guest_unlock();
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSApp stop:nil];
        NSEvent *e=[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
                                  modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0 data1:0 data2:0];
        [NSApp postEvent:e atStart:NO];
    });
    return NULL;
}

int main(int argc, char **argv){
    @autoreleasepool {
        if (argc<2||argc>3){ fputs("usage: out/nfsiv /path/to/linked.exe [/path/to/game]\n",stderr); return 1; }
        mem_init(); mem_fault_handler_install();
        if (mem_load_pe(argv[1])) return 1;
        const char *watch=getenv("NFSIV_WATCH_ADDR");
        if(watch&&*watch){
            char *end;unsigned long value=strtoul(watch,&end,0);
            if(*end||value>0xfffffffcu||!mem_valid((uint32_t)value,4)){fputs("invalid diagnostic watch address\n",stderr);return 1;}
            g_watch_addr=(uint32_t)value;g_watch_val=MR32(g_watch_addr);
        }
        if(argc==3){
            char path[4096];
            if(snprintf(path,sizeof path,"%s/nfs4.exe",argv[2])>=(int)sizeof path)return 1;
            fileio_set_root(path);
        }else fileio_set_root(argv[1]);
        const char *save=getenv("NFSIV_SAVE_DIR");
        if (!save || !*save) save="out/saves";
        if (mkdir(save,0755) && errno!=EEXIST){ perror(save); return 1; }
        fileio_set_write_root(save); fileio_set_readonly_root(1);
        if (!getenv("NFSIV_REGFILE")){
            char path[1024]; snprintf(path,sizeof path,"%s/registry",save); setenv("NFSIV_REGFILE",path,1);
        }
        setenv("NFSIV_THREAD_EXIT","windows",1);
        const char *sound=getenv("NFSIV_AUDIO");audio_set_muted(sound&&!strcmp(sound,"0"));
        dispatch_init();
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        void control_init(void);void control_pump(void);control_init();
        [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:YES block:^(NSTimer *timer){(void)timer;control_pump();void audio_capture_pump(void);audio_capture_pump();}];
        signal(SIGALRM,deadline);
        const char *limit=getenv("NFSIV_TIMEOUT");
        alarm(limit ? (unsigned)strtoul(limit,NULL,10) : 0);
        pthread_t thread;
        if (pthread_create(&thread,NULL,run_guest,NULL)){ fputs("cannot start game thread\n",stderr); return 1; }
        [NSApp run];
        pthread_join(thread,NULL);
        audio_shutdown();
        render_capture_wait();
        return result;
    }
}

#include "runtime.h"
#include "audio.h"
#include <stddef.h>
#include <string.h>
#include <strings.h>

uint32_t com_object(unsigned,unsigned);
void gheap_free(int,uint32_t);
typedef struct {
    uint32_t table,family,refs,loop,lock_p1,lock_n1,lock_p2,lock_n2;
    uint32_t bytes,data,voice,flags,rate,channels,bits;
    int32_t volume,pan;
    uint32_t frequency;
    uint32_t reserved[2];
    uint8_t format[18];
} SoundBuffer;
_Static_assert(offsetof(SoundBuffer,bytes)==32,"sound buffer guest layout");
static struct {uint32_t data,refs;} shared[256];
static uint32_t A(CPU *c,unsigned i){return MR32(c->esp+4*i);}

static void share(uint32_t data,int delta){
    if(!data)return;
    for(unsigned i=0;i<256;i++)if(shared[i].data==data){
        shared[i].refs=(uint32_t)((int)shared[i].refs+delta);
        if(!shared[i].refs){gheap_free(1,data);shared[i].data=0;}return;
    }
    if(delta>0)for(unsigned i=0;i<256;i++)if(!shared[i].data){shared[i].data=data;shared[i].refs=1;return;}
    runtime_fail(g_cur_cpu,"sound data ownership",data);
}
void sound_release(uint32_t self){
    SoundBuffer *b=guest_ptr(self,sizeof *b);audio_destroy((int)b->voice);share(b->data,-1);
}

int sound_platform_call(CPU *c,const char *dll,const char *name,uint32_t *out){
    /* DirectSound buffers control game volume; there is no WinMM hardware mixer on macOS. */
    if(!strcasecmp(dll,"WINMM.dll")&&!strncmp(name,"mixer",5)){
        *out=!strcmp(name,"mixerGetNumDevs")?0:2;return 1;
    }
    if(strcasecmp(dll,"DSOUND.dll"))return 0;
    if(!strcmp(name,"#1")||!strcmp(name,"DirectSoundCreate")){
        uint32_t *p=guest_ptr(A(c,1),4);*p=0;
        if(!audio_start())*out=0x88780078u;
        else{*p=com_object(4,0);*out=0;}return 1;
    }
    if(!strcmp(name,"#6")||!strcmp(name,"DirectSoundEnumerateA")){
        uint32_t text=win32_alloc(64,1);strcpy((char *)g_mem+text,"CoreAudio Output");
        uint32_t args[]={0,text,0,A(c,1)};call_guest(c,A(c,0),4,args);gheap_free(1,text);*out=0;return 1;
    }
    return 0;
}

static int format(SoundBuffer *b,uint32_t p){
    if(p){
        uint8_t *f=guest_ptr(p,18);
        b->channels=MR16(p+2);b->rate=MR32(p+4);b->bits=MR16(p+14);
        if(MR16(p)!=1||b->channels<1||b->channels>2||(b->bits!=8&&b->bits!=16)||b->rate<100||b->rate>200000)return 0;
        memcpy(b->format,f,18);
    }else{
        b->channels=2;b->rate=44100;b->bits=16;memset(b->format,0,18);
        uint16_t tag=1,ch=2,bits=16,align=4;uint32_t rate=44100,bps=176400;
        memcpy(b->format,&tag,2);memcpy(b->format+2,&ch,2);memcpy(b->format+4,&rate,4);
        memcpy(b->format+8,&bps,4);memcpy(b->format+12,&align,2);memcpy(b->format+14,&bits,2);
    }
    b->frequency=b->rate;return 1;
}

int sound_method(CPU *c,uint32_t self,unsigned slot,uint32_t *result,uint32_t *nargs){
    uint32_t r=0;SoundBuffer *b=guest_ptr(self,sizeof *b);
    if(b->family==4){
        if(slot==3){
            *nargs=4;uint32_t desc=A(c,1),output=A(c,2);guest_ptr(desc,20);uint32_t *out=guest_ptr(output,4);*out=0;
            uint32_t size=MR32(desc);
            if(size!=20&&size!=36)r=0x80070057;
            else{
                uint32_t address=com_object(5,0);SoundBuffer *buffer=guest_ptr(address,sizeof *buffer);
                buffer->flags=MR32(desc+4);buffer->bytes=MR32(desc+8);
                if(buffer->flags&1)buffer->bytes=65536;
                if(!buffer->bytes||buffer->bytes>16*1024*1024||!format(buffer,MR32(desc+16)))r=0x80070057;
                else{
                    buffer->data=win32_alloc(buffer->bytes,1);
                    if(!buffer->data)r=0x8007000e;
                    else{
                        if(buffer->bits==8)memset(g_mem+buffer->data,128,buffer->bytes);
                        buffer->voice=(uint32_t)audio_create(buffer->data,buffer->bytes,buffer->rate,buffer->channels,buffer->bits);
                        if(!buffer->voice){gheap_free(1,buffer->data);r=0x8878000a;}
                        else{share(buffer->data,1);*out=address;}
                    }
                }
                if(r)gheap_free(1,address);
            }
        }
        else if(slot==4){
            *nargs=2;uint32_t p=A(c,1),size=*(uint32_t *)guest_ptr(p,4);
            if(size<96||size>256)r=0x80070057;
            else{memset(guest_ptr(p,size),0,size);MR32(p)=size;MR32(p+4)=0xf1f;MR32(p+8)=100;MR32(p+12)=200000;MR32(p+16)=1;}
        }
        else if(slot==5){
            *nargs=3;SoundBuffer *src=guest_ptr(A(c,1),sizeof *src);uint32_t *out=guest_ptr(A(c,2),4);*out=0;
            if(src->family!=5||(src->flags&1))r=0x80070057;
            else{
                uint32_t address=com_object(5,0),table=MR32(address);SoundBuffer *copy=guest_ptr(address,sizeof *copy);
                memcpy(copy,src,sizeof *copy);copy->table=table;copy->refs=1;copy->loop=0;
                copy->lock_p1=copy->lock_n1=copy->lock_p2=copy->lock_n2=0;
                copy->voice=(uint32_t)audio_duplicate((int)src->voice);
                if(!copy->voice){gheap_free(1,address);r=0x8878000a;}else{share(copy->data,1);*out=address;}
            }
        }
        else if(slot==6){*nargs=3;}
        else if(slot==7){*nargs=1;}
        else if(slot==8){*nargs=2;*(uint32_t *)guest_ptr(A(c,1),4)=4;}
        else if(slot==9){*nargs=2;if(A(c,1)!=4)r=0x80070057;}
        else if(slot==10){*nargs=2;r=0x88780082;}
        else return 0;
    }else if(b->family==5){
        if(slot==3){
            *nargs=2;uint32_t p=A(c,1);if(*(uint32_t *)guest_ptr(p,20)!=20)r=0x80070057;
            else{memset(g_mem+p,0,20);MR32(p)=20;MR32(p+4)=b->flags;MR32(p+8)=b->bytes;}
        }
        else if(slot==4){
            *nargs=3;uint32_t play,write;audio_cursors((int)b->voice,&play,&write);
            if(A(c,1))*(uint32_t *)guest_ptr(A(c,1),4)=play;if(A(c,2))*(uint32_t *)guest_ptr(A(c,2),4)=write;
        }
        else if(slot==5){
            *nargs=4;uint32_t p=A(c,1),size=A(c,2),written=A(c,3);
            if(written)*(uint32_t *)guest_ptr(written,4)=18;
            if(p){if(size<18)r=0x80070057;else memcpy(guest_ptr(p,18),b->format,18);}
        }
        else if(slot==6||slot==7||slot==8){
            *nargs=2;*(uint32_t *)guest_ptr(A(c,1),4)=slot==6?(uint32_t)b->volume:slot==7?(uint32_t)b->pan:b->frequency;
        }
        else if(slot==9){*nargs=2;*(uint32_t *)guest_ptr(A(c,1),4)=audio_playing((int)b->voice)?1|(b->loop?4:0):0;}
        else if(slot==11){
            *nargs=8;uint32_t offset=A(c,1),size=A(c,2),flags=A(c,7);
            if(flags&2){offset=0;size=b->bytes;}
            else if(flags&1){audio_cursors((int)b->voice,NULL,&offset);}
            if(!size||size>b->bytes||offset>=b->bytes||b->lock_n1)r=0x80070057;
            else{
                uint32_t n1=size<b->bytes-offset?size:b->bytes-offset,n2=size-n1;
                if(n2&&(!A(c,5)||!A(c,6)))r=0x80070057;
                else{
                    b->lock_p1=b->data+offset;b->lock_n1=n1;b->lock_p2=n2?b->data:0;b->lock_n2=n2;
                    *(uint32_t *)guest_ptr(A(c,3),4)=b->lock_p1;*(uint32_t *)guest_ptr(A(c,4),4)=n1;
                    if(A(c,5))*(uint32_t *)guest_ptr(A(c,5),4)=b->lock_p2;
                    if(A(c,6))*(uint32_t *)guest_ptr(A(c,6),4)=n2;
                }
            }
        }
        else if(slot==12){*nargs=4;b->loop=A(c,3)&1;audio_play((int)b->voice,(int)b->loop);}
        else if(slot==13){*nargs=2;if(A(c,1)>=b->bytes)r=0x80070057;else audio_set_position((int)b->voice,A(c,1));}
        else if(slot==14){
            *nargs=2;if(!(b->flags&1))r=0x88780032;
            else if(!format(b,A(c,1)))r=0x80070057;
            else{audio_destroy((int)b->voice);b->voice=(uint32_t)audio_create(b->data,b->bytes,b->rate,b->channels,b->bits);if(!b->voice)r=0x8878000a;}
        }
        else if(slot==15){*nargs=2;int value=(int32_t)A(c,1);if(value>0||value<-10000)r=0x80070057;else{b->volume=value;audio_set_volume((int)b->voice,value);}}
        else if(slot==16){*nargs=2;int value=(int32_t)A(c,1);if(value>10000||value<-10000)r=0x80070057;else{b->pan=value;audio_set_pan((int)b->voice,value);}}
        else if(slot==17){*nargs=2;uint32_t rate=A(c,1);if(rate&&(rate<100||rate>200000))r=0x80070057;else{b->frequency=rate?rate:b->rate;audio_set_frequency((int)b->voice,rate);}}
        else if(slot==18){*nargs=1;audio_stop((int)b->voice);}
        else if(slot==19){
            *nargs=5;
            if(A(c,1)!=b->lock_p1||A(c,2)!=b->lock_n1||A(c,3)!=b->lock_p2||A(c,4)!=b->lock_n2)r=0x80070057;
            else b->lock_p1=b->lock_n1=b->lock_p2=b->lock_n2=0;
        }
        else if(slot==20){*nargs=1;}
        else return 0;
    }else return 0;
    *result=r;return 1;
}

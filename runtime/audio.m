#include "runtime.h"
#include "audio.h"
#include <AudioUnit/AudioUnit.h>
#include <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define VOICES 256
#define OUTPUT_RATE 44100u
typedef struct {
    uint32_t data,bytes,rate,channels,bits;
    int used,playing,loop,volume,pan;
    float left,right;
    double position,frequency;
} Voice;
static Voice voices[VOICES];
static pthread_mutex_t audio_lock=PTHREAD_MUTEX_INITIALIZER;
static AudioUnit unit;
static uint64_t mixed_frames;
static int muted;
static int16_t *capture;
static size_t capture_used,capture_frames;
static char *capture_path;

int audio_create(uint32_t data,uint32_t bytes,uint32_t rate,uint32_t channels,uint32_t bits){
    if(!data||!bytes||!mem_valid(data,bytes)||rate<100||rate>200000||channels<1||channels>2||(bits!=8&&bits!=16))return 0;
    pthread_mutex_lock(&audio_lock);
    int id=0;
    for(int i=1;i<VOICES;i++)if(!voices[i].used){
        voices[i]=(Voice){.data=data,.bytes=bytes,.rate=rate,.channels=channels,.bits=bits,.used=1,.frequency=rate,.left=1,.right=1};id=i;break;
    }
    pthread_mutex_unlock(&audio_lock);return id;
}
void audio_destroy(int id){
    if(id<=0||id>=VOICES)return;
    pthread_mutex_lock(&audio_lock);memset(&voices[id],0,sizeof voices[id]);pthread_mutex_unlock(&audio_lock);
}
int audio_duplicate(int source){
    if(source<=0||source>=VOICES)return 0;
    pthread_mutex_lock(&audio_lock);int id=0;
    if(voices[source].used)for(int i=1;i<VOICES;i++)if(!voices[i].used){
        voices[i]=voices[source];voices[i].playing=0;voices[i].position=0;id=i;break;
    }
    pthread_mutex_unlock(&audio_lock);return id;
}
void audio_play(int id,int loop){
    if(id<=0||id>=VOICES)return;
    pthread_mutex_lock(&audio_lock);if(voices[id].used){voices[id].playing=1;voices[id].loop=loop;}pthread_mutex_unlock(&audio_lock);
}
void audio_stop(int id){
    if(id<=0||id>=VOICES)return;
    pthread_mutex_lock(&audio_lock);voices[id].playing=0;pthread_mutex_unlock(&audio_lock);
}
int audio_playing(int id){
    if(id<=0||id>=VOICES)return 0;
    pthread_mutex_lock(&audio_lock);int playing=voices[id].used&&voices[id].playing;pthread_mutex_unlock(&audio_lock);return playing;
}
void audio_cursors(int id,uint32_t *play,uint32_t *write){
    uint32_t p=0,w=0;
    pthread_mutex_lock(&audio_lock);
    if(id>0&&id<VOICES&&voices[id].used){
        Voice *v=&voices[id];uint32_t block=v->channels*v->bits/8;
        p=(uint32_t)v->position*block;
        uint32_t lead=v->rate/20*block;if(lead>=v->bytes)lead=v->bytes/4/block*block;
        w=(p+lead)%v->bytes;
    }
    pthread_mutex_unlock(&audio_lock);if(play)*play=p;if(write)*write=w;
}
void audio_set_position(int id,uint32_t bytes){
    if(id<=0||id>=VOICES)return;
    pthread_mutex_lock(&audio_lock);
    Voice *v=&voices[id];if(v->used)v->position=(double)(bytes%v->bytes)/(v->channels*v->bits/8);
    pthread_mutex_unlock(&audio_lock);
}
static void gains(Voice *v){
    float gain=v->volume<=-10000?0:powf(10.f,v->volume/2000.f);
    v->left=v->pan>=10000?0:gain*(v->pan>0?powf(10.f,-v->pan/2000.f):1);
    v->right=v->pan<=-10000?0:gain*(v->pan<0?powf(10.f,v->pan/2000.f):1);
}
void audio_set_volume(int id,int value){
    if(id<=0||id>=VOICES)return;
    pthread_mutex_lock(&audio_lock);voices[id].volume=value;gains(&voices[id]);pthread_mutex_unlock(&audio_lock);
}
void audio_set_pan(int id,int value){
    if(id<=0||id>=VOICES)return;
    pthread_mutex_lock(&audio_lock);voices[id].pan=value;gains(&voices[id]);pthread_mutex_unlock(&audio_lock);
}
void audio_set_frequency(int id,uint32_t rate){
    if(id<=0||id>=VOICES)return;
    pthread_mutex_lock(&audio_lock);voices[id].frequency=rate?rate:voices[id].rate;pthread_mutex_unlock(&audio_lock);
}
void audio_set_muted(int value){pthread_mutex_lock(&audio_lock);muted=value;pthread_mutex_unlock(&audio_lock);}
double audio_time(void){pthread_mutex_lock(&audio_lock);double t=(double)mixed_frames/OUTPUT_RATE;pthread_mutex_unlock(&audio_lock);return t;}

static float sample(const Voice *v,uint32_t frame,unsigned channel){
    uint32_t offset=(frame*v->channels+(v->channels==1?0:channel))*(v->bits/8);
    if(v->bits==8)return ((int)g_mem[v->data+offset]-128)/128.f;
    int16_t value;memcpy(&value,g_mem+v->data+offset,2);return value/32768.f;
}
void audio_mix(int16_t *output,unsigned frames){
    memset(output,0,(size_t)frames*2*sizeof *output);
    pthread_mutex_lock(&audio_lock);
    for(unsigned f=0;f<frames;f++){
        float sum[2]={0,0};
        for(int id=1;id<VOICES;id++){
            Voice *v=&voices[id];if(!v->used||!v->playing)continue;
            uint32_t length=v->bytes/(v->channels*v->bits/8);if(!length){v->playing=0;continue;}
            if(v->position>=length){if(v->loop)v->position=fmod(v->position,length);else{v->position=0;v->playing=0;continue;}}
            for(unsigned channel=0;channel<2;channel++){
                sum[channel]+=sample(v,(uint32_t)v->position,channel)*(channel?v->right:v->left);
            }
            v->position+=v->frequency/OUTPUT_RATE;
        }
        for(unsigned channel=0;channel<2;channel++){
            float x=muted?0:sum[channel]*32768.f;
            if(x>32767)x=32767;if(x<-32768)x=-32768;
            output[f*2+channel]=(int16_t)x;
        }
    }
    if(capture && capture_used<capture_frames){
        size_t n=frames;if(n>capture_frames-capture_used)n=capture_frames-capture_used;
        memcpy(capture+capture_used*2,output,n*4);capture_used+=n;
    }
    mixed_frames+=frames;pthread_mutex_unlock(&audio_lock);
}

int audio_capture_start(const char *path){
 if(!path||!*path)return 0;
 size_t frames=10*OUTPUT_RATE;int16_t *data=calloc(frames*2,sizeof *data);char *name=strdup(path);
 if(!data||!name){free(data);free(name);return 0;}
 pthread_mutex_lock(&audio_lock);
 if(capture_path){pthread_mutex_unlock(&audio_lock);free(data);free(name);return 0;}
 capture=data;capture_path=name;capture_frames=frames;capture_used=0;
 pthread_mutex_unlock(&audio_lock);return 1;
}

/* File I/O stays on the application thread, outside the audio callback. */
void audio_capture_pump(void){
    pthread_mutex_lock(&audio_lock);
    int ready=capture && capture_used==capture_frames;
    int16_t *data=ready?capture:NULL;size_t bytes=ready?capture_frames*4:0;
    if(ready)capture=NULL;
    pthread_mutex_unlock(&audio_lock);
    if(!ready)return;
    struct __attribute__((packed)) {char riff[4];uint32_t size;char wave[4],fmt[4];uint32_t fmt_size;uint16_t pcm,channels;uint32_t rate,byte_rate;uint16_t align,bits;char data[4];uint32_t bytes;} header={
        .riff="RIFF",.size=(uint32_t)bytes+36,.wave="WAVE",.fmt="fmt ",.fmt_size=16,.pcm=1,.channels=2,.rate=OUTPUT_RATE,.byte_rate=OUTPUT_RATE*4,.align=4,.bits=16,.data="data",.bytes=(uint32_t)bytes};
    _Static_assert(sizeof header==44,"WAV header");
    FILE *f=fopen(capture_path,"wb");
    if(!f){perror("audio capture");exit(1);}
    int ok=fwrite(&header,1,sizeof header,f)==sizeof header && fwrite(data,1,bytes,f)==bytes;
    if(fclose(f))ok=0;
    free(data);free(capture_path);capture_path=NULL;
    if(!ok){fputs("audio capture write failed\n",stderr);exit(1);}
    fputs("native audio capture saved\n",stderr);
}

static OSStatus render(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,
                       UInt32 bus,UInt32 frames,AudioBufferList *data){
    (void)context;(void)flags;(void)time;(void)bus;
    if(data->mNumberBuffers!=1||data->mBuffers[0].mDataByteSize<frames*4)return kAudio_ParamError;
    audio_mix(data->mBuffers[0].mData,frames);return noErr;
}
int audio_start(void){
    if(unit)return 1;
    AudioComponentDescription desc={.componentType=kAudioUnitType_Output,.componentSubType=kAudioUnitSubType_DefaultOutput,.componentManufacturer=kAudioUnitManufacturer_Apple};
    AudioComponent component=AudioComponentFindNext(NULL,&desc);
    if(!component||AudioComponentInstanceNew(component,&unit)!=noErr){fputs("CoreAudio output component unavailable\n",stderr);return 0;}
    AudioStreamBasicDescription format={.mSampleRate=OUTPUT_RATE,.mFormatID=kAudioFormatLinearPCM,
        .mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked,.mBytesPerPacket=4,
        .mFramesPerPacket=1,.mBytesPerFrame=4,.mChannelsPerFrame=2,.mBitsPerChannel=16};
    AURenderCallbackStruct callback={.inputProc=render};
    OSStatus status=AudioUnitSetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&format,sizeof format);
    if(!status)status=AudioUnitSetProperty(unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof callback);
    if(!status)status=AudioUnitInitialize(unit);
    if(!status){
        const char *path=getenv("NFSIV_AUDIO_CAPTURE");
        if(path&&*path&&!audio_capture_start(path)){fputs("audio capture allocation failed\n",stderr);exit(1);}
        status=AudioOutputUnitStart(unit);
    }
    if(status){fprintf(stderr,"CoreAudio output failed: %d\n",(int)status);AudioComponentInstanceDispose(unit);unit=NULL;return 0;}
    fputs("native CoreAudio output: 44100 Hz stereo\n",stderr);return 1;
}
void audio_shutdown(void){if(unit){AudioOutputUnitStop(unit);AudioUnitUninitialize(unit);AudioComponentInstanceDispose(unit);unit=NULL;}}

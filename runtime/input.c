#include "runtime.h"
#include "input.h"
#include <pthread.h>
#include <string.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>

static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static uint8_t keys[256],vkeys[256],buttons[8];
static uint8_t key_vks[256];
static int mouse_x,mouse_y,delta_x,delta_y,delta_z;
static int swapped;
int input_swap_buttons(int value){pthread_mutex_lock(&lock);int old=swapped;swapped=!!value;pthread_mutex_unlock(&lock);return old;}
static struct { InputEvent queue[1024]; unsigned head,count; uint32_t notification; } queues[2];
static uint32_t sequence;
static struct {uint32_t message,wp,lp;} messages[2048];
static unsigned message_head,message_count;
static uint8_t paste[1024];
static unsigned paste_count,paste_position,paste_previous;
static uint64_t paste_next;
void win32_signal_event(uint32_t);
void win32_post_message(uint32_t,uint32_t,uint32_t);
static void message(uint32_t code,uint32_t wp,uint32_t lp){
    if(message_count==2048){message_head=(message_head+1)%2048;message_count--;}
    unsigned i=(message_head+message_count++)%2048;
    messages[i].message=code;messages[i].wp=wp;messages[i].lp=lp;
}

static void event(unsigned kind,uint32_t offset,uint32_t value){
    struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);
    unsigned q=kind-1;
    if(queues[q].count==1024){queues[q].head=(queues[q].head+1)%1024;queues[q].count--;}
    unsigned index=(queues[q].head+queues[q].count++)%1024;
    queues[q].queue[index]=(InputEvent){offset,value,(uint32_t)((uint64_t)ts.tv_sec*1000+ts.tv_nsec/1000000),++sequence};
}
void input_key(unsigned scan,unsigned vk,int down){
    if(scan>=256||vk>=256)return;
    if(getenv("NFSIV_INPUT_TRACE"))fprintf(stderr,"host key scan=%u vk=%u down=%d\n",scan,vk,down);
    pthread_mutex_lock(&lock);
    if(keys[scan]!=(down?128:0))event(1,scan,down?128:0);
    keys[scan]=down?128:0;vkeys[vk]=down?128:0;key_vks[scan]=(uint8_t)vk;
    uint32_t flags=1u|((scan&127)<<16)|(scan>=128?0x1000000u:0u)|(down?0u:0xc0000000u);
    message(down?0x100:0x101,vk,flags);
    uint32_t notification=queues[0].notification;
    pthread_mutex_unlock(&lock);
    if(notification)win32_signal_event(notification);
}
void input_text(unsigned character){
    if(character<256){pthread_mutex_lock(&lock);message(0x102,character,1);pthread_mutex_unlock(&lock);}
}
void input_paste(const uint8_t *text,unsigned count){
    pthread_mutex_lock(&lock);
    paste_count=count<sizeof paste?count:sizeof paste;
    memcpy(paste,text,paste_count);paste_position=paste_previous=0;paste_next=0;
    pthread_mutex_unlock(&lock);
}
void input_focus(int active){
    pthread_mutex_lock(&lock);
    if(!active){
        paste_count=paste_position=0;
        for(unsigned scan=0;scan<256;scan++)if(keys[scan]){
            event(1,scan,0);
            message(0x101,key_vks[scan],1u|((scan&127)<<16)|(scan>=128?0x1000000u:0u)|0xc0000000u);
        }
        for(unsigned button=0;button<8;button++)if(buttons[button]){
            event(2,12+button,0);
            if(button<3)message((uint32_t[]){0x202,0x205,0x208}[button],0,(uint16_t)mouse_x|((uint32_t)(uint16_t)mouse_y<<16));
        }
        memset(keys,0,sizeof keys);memset(vkeys,0,sizeof vkeys);memset(buttons,0,sizeof buttons);
        delta_x=delta_y=delta_z=0;
    }
    /* Metal surfaces and CoreAudio keep running when the Mac window loses
       focus. Windows display deactivation makes the game reset both. */
    message(active?7:8,0,0);
    uint32_t keyboard_event=queues[0].notification,mouse_event=queues[1].notification;
    pthread_mutex_unlock(&lock);
    if(keyboard_event)win32_signal_event(keyboard_event);if(mouse_event)win32_signal_event(mouse_event);
}
/* DirectInput reports motion separately from the clamped cursor position, so
   motion keeps flowing when the position is already at an edge. */
static void mouse_update(int x,int y,int dx,int dy,int button,int down,int wheel){
    mouse_x=x;mouse_y=y;delta_x+=dx;delta_y+=dy;delta_z+=wheel;
    if(dx)event(2,0,(uint32_t)dx);if(dy)event(2,4,(uint32_t)dy);if(wheel)event(2,8,(uint32_t)wheel);
    if(button>=0&&button<8){buttons[button]=down?128:0;event(2,12+(unsigned)button,buttons[button]);}
    uint32_t wp=(buttons[swapped?1:0]?1:0)|(buttons[swapped?0:1]?2:0)|(buttons[2]?16:0)|(vkeys[0x10]?4:0)|(vkeys[0x11]?8:0);
    uint32_t lp=(uint16_t)x|((uint32_t)(uint16_t)y<<16);
    if(dx||dy)message(0x200,wp,lp);
    if(button>=0&&button<3){int mapped=button<2?button^swapped:button;message((uint32_t[]){0x201,0x204,0x207}[mapped]+(down?0:1),wp,lp);}
    if(wheel)message(0x20a,wp|((uint32_t)(uint16_t)wheel<<16),lp);
}
void input_mouse(int x,int y,int button,int down,int wheel){
    if(getenv("NFSIV_INPUT_TRACE"))fprintf(stderr,"host mouse x=%d y=%d button=%d down=%d\n",x,y,button,down);
    pthread_mutex_lock(&lock);
    mouse_update(x,y,x-mouse_x,y-mouse_y,button,down,wheel);
    uint32_t notification=queues[1].notification;
    pthread_mutex_unlock(&lock);
    if(notification)win32_signal_event(notification);
}
void input_mouse_motion(int dx,int dy,int width,int height){
    if(!dx&&!dy)return;
    if(getenv("NFSIV_INPUT_TRACE"))fprintf(stderr,"host mouse motion dx=%d dy=%d\n",dx,dy);
    pthread_mutex_lock(&lock);
    long x=(long)mouse_x+dx,y=(long)mouse_y+dy;
    x=x<0?0:x>=width?width-1:x;y=y<0?0:y>=height?height-1:y;
    mouse_update((int)x,(int)y,dx,dy,-1,0,0);
    uint32_t notification=queues[1].notification;
    pthread_mutex_unlock(&lock);
    if(notification)win32_signal_event(notification);
}
void input_keyboard_state(uint8_t *out){pthread_mutex_lock(&lock);memcpy(out,keys,256);pthread_mutex_unlock(&lock);}
void input_mouse_state(void *out,unsigned size){
    pthread_mutex_lock(&lock);
    int32_t *v=out;memset(out,0,size);
    if(getenv("NFSIV_INPUT_TRACE")&&(delta_x||delta_y||buttons[0]||buttons[1]))fprintf(stderr,"mouse state dx=%d dy=%d buttons=%u,%u\n",delta_x,delta_y,buttons[0],buttons[1]);
    if(size>=12){v[0]=delta_x;v[1]=delta_y;v[2]=delta_z;memcpy((uint8_t *)out+12,buttons,size-12<8?size-12:8);}
    delta_x=delta_y=delta_z=0;
    pthread_mutex_unlock(&lock);
}
unsigned input_events(int kind,InputEvent *out,unsigned count,int peek){
    unsigned q=(unsigned)kind-1;if(q>=2)return 0;
    pthread_mutex_lock(&lock);
    unsigned n=count<queues[q].count?count:queues[q].count;
    for(unsigned i=0;out&&i<n;i++)out[i]=queues[q].queue[(queues[q].head+i)%1024];
    if(!peek){queues[q].head=(queues[q].head+n)%1024;queues[q].count-=n;}
    pthread_mutex_unlock(&lock);return n;
}
void input_set_event(int kind,uint32_t handle){
    if(kind<1||kind>2)return;
    pthread_mutex_lock(&lock);queues[kind-1].notification=handle;pthread_mutex_unlock(&lock);
}
int input_key_state(unsigned vk){
    if(vk>=256)return 0;
    pthread_mutex_lock(&lock);int value=vkeys[vk]?0x8000:0;pthread_mutex_unlock(&lock);return value;
}
void input_cursor(int *x,int *y){pthread_mutex_lock(&lock);if(x)*x=mouse_x;if(y)*y=mouse_y;pthread_mutex_unlock(&lock);}
void input_pump(void){
    pthread_mutex_lock(&lock);
    struct timespec ts;clock_gettime(CLOCK_MONOTONIC,&ts);
    uint64_t now=(uint64_t)ts.tv_sec*1000+ts.tv_nsec/1000000;
    /* The original game's character vector holds only 64 entries and pops
       them in reverse order. Deliver one letter per UI update interval. */
    if(paste_position<paste_count&&now>=paste_next){
        unsigned ch=paste[paste_position++];
        if(ch==paste_previous)message(0x102,2,1);
        message(0x102,ch,1);paste_previous=ch;paste_next=now+35;
    }
    while(message_count){
        unsigned i=message_head;message_head=(message_head+1)%2048;message_count--;
        win32_post_message(messages[i].message,messages[i].wp,messages[i].lp);
    }
    pthread_mutex_unlock(&lock);
}

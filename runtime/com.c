/* Guest COM layouts for DirectInput 5, using native keyboard and mouse state. */
#include "runtime.h"
#include "input.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void gheap_free(int,uint32_t);
static uint32_t tables[8];
static uint32_t A(CPU *c,unsigned i){return MR32(c->esp+4*i);}

uint32_t com_object(unsigned family,unsigned kind){
    if(!tables[family]){
        tables[family]=win32_alloc(32*4,1);
        for(unsigned i=0;i<32;i++)MR32(tables[family]+4*i)=0xe1000000u+(family<<12)+i;
    }
    uint32_t p=win32_alloc(128,1);
    MR32(p)=tables[family];MR32(p+4)=family;MR32(p+8)=1;MR32(p+28)=kind;
    return p;
}

int com_platform_call(CPU *c,const char *dll,const char *name,uint32_t *out){
    int sound_platform_call(CPU *,const char *,const char *,uint32_t *);
    if(sound_platform_call(c,dll,name,out))return 1;
    if(!strcmp(name,"DirectDrawCreate")){
        uint32_t *p=guest_ptr(A(c,1),4);*p=0;
        if(A(c,2))*out=0x80040110;
        else{*p=com_object(3,0);*out=0;}
        return 1;
    }
    if(strcmp(name,"DirectInputCreateA"))return 0;
    uint32_t p=A(c,2);*(uint32_t *)guest_ptr(p,4)=com_object(1,0);*out=0;return 1;
}

static void guid(uint32_t p,uint32_t first){
    MR32(p)=first;MR16(p+4)=0xd5a0;MR16(p+6)=0x11cf;
    static const uint8_t tail[]={0xbf,0xc7,0x44,0x45,0x53,0x54,0,0};
    memcpy(g_mem+p+8,tail,8);
}

static uint32_t enumerate_devices(CPU *c,unsigned type,uint32_t fn,uint32_t context){
    uint32_t p=win32_alloc(580,1);
    for(unsigned kind=1;kind<=2;kind++){
        unsigned devtype=kind==1?3:2;
        if(type && type!=devtype)continue;
        memset(g_mem+p,0,580);MR32(p)=580;
        guid(p+4,kind==1?0x6f1d2b61:0x6f1d2b60);guid(p+20,kind==1?0x6f1d2b61:0x6f1d2b60);
        MR32(p+36)=devtype;
        strcpy((char *)g_mem+p+40,kind==1?"Keyboard":"Mouse");
        strcpy((char *)g_mem+p+300,kind==1?"Native Keyboard":"Native Mouse");
        uint32_t args[]={p,context};
        if(!call_guest(c,fn,2,args))break;
    }
    gheap_free(1,p);return 0;
}

static int object_info(uint32_t p,unsigned kind,unsigned object,unsigned how){
    uint32_t size=*(uint32_t *)guest_ptr(p,4),offset,index,type,first;
    if(size!=292 && size!=316)return 0x80070057;
    if(how==1){
        offset=object;
        if(kind==1){if(offset>=256)return 0x80070002;index=offset;type=0x0c;}
        else if(offset<12 && !(offset&3)){index=offset/4;type=1;}
        else if(offset>=12&&offset<16){index=offset-12;type=4;}
        else return 0x80070002;
    }else if(how==2){
        index=(object>>8)&0xffff;type=object&255;
        if(kind==1 && (type&12) && index<256){offset=index;type=0x0c;}
        else if(kind==2 && (type&3) && index<3){offset=index*4;type=1;}
        else if(kind==2 && (type&12) && index<4){offset=index+12;type=4;}
        else return 0x80070002;
    }else return 0x80070057;
    memset(guest_ptr(p,size),0,size);MR32(p)=size;
    first=kind==1?0x55728220:type==1?0xa36d02e0+index:0xa36d02f0;
    guid(p+4,first);MR16(p+8)=kind==1?0xd33c:0xc9f3;
    MR32(p+20)=offset;MR32(p+24)=type|(index<<8);
    if(kind==1)snprintf((char *)g_mem+p+32,260,"Key %u",index);
    else if(type==1)snprintf((char *)g_mem+p+32,260,"%c Axis",'X'+index);
    else snprintf((char *)g_mem+p+32,260,"Button %u",index+1);
    if(size==316){MR16(p+304)=kind==1?7:type==1?1:9;MR16(p+306)=kind==1?0:type==1?0x30+index:index+1;}
    return 0;
}

void com_call(CPU *c,uint32_t thunk){
    unsigned family=(thunk>>12)&255,slot=thunk&0xfff;
    POP32(c->eip);
    uint32_t self=A(c,0),r=0,nargs=1;
    guest_ptr(self,64);
    if(MR32(self+4)!=family)runtime_fail(c,"COM interface mismatch",thunk);
    static uint32_t seen[8];
    if(family<8 && slot<32 && !(seen[family]&(1u<<slot))){
        seen[family]|=1u<<slot;fprintf(stderr,"COM family=%u slot=%u self=%08x from=%08x\n",family,slot,self,c->eip);
    }
    unsigned kind=MR32(self+28);
    if(slot==0){
        nargs=3;uint32_t iid=A(c,1),out=A(c,2);uint32_t first=*(uint32_t *)guest_ptr(iid,16);
        if(first==0 || (family==1&&(first==0x89521360||first==0x5944e662||first==0x9a4cb684))
           || (family==2&&(first==0x5944e680||first==0x5944e682||first==0x57d7c6bc))
           || (family==3&&(first==0x6c14db80||first==0xb3a6f3e0))
           || (family==6&&(first==0x6c14db81||first==0x57805885||first==0xda044e00))
           || (family==4&&first==0x279afa83) || (family==5&&(first==0x279afa85||first==0x6825a449))){
            *(uint32_t *)guest_ptr(out,4)=self;MR32(self+8)++;
        }else{*(uint32_t *)guest_ptr(out,4)=0;r=0x80004002;fprintf(stderr,"unavailable COM IID %08x\n",first);}
    }
    else if(slot==1)r=++MR32(self+8);
    else if(slot==2){r=--MR32(self+8);if(!r){if(family==2)input_set_event((int)kind,0);if(family==5){void sound_release(uint32_t);sound_release(self);}gheap_free(1,self);}}
    else if(family==1){
        if(slot==3){
            nargs=4;uint32_t first=*(uint32_t *)guest_ptr(A(c,1),16),out=A(c,2);
            unsigned device=first==0x6f1d2b61?1:first==0x6f1d2b60?2:0;
            if(device)*(uint32_t *)guest_ptr(out,4)=com_object(2,device);
            else{*(uint32_t *)guest_ptr(out,4)=0;r=0x80070002;}
        }
        else if(slot==4){nargs=5;r=enumerate_devices(c,A(c,1),A(c,2),A(c,3));}
        else if(slot==5){nargs=2;r=0;}
        else if(slot==7){nargs=3;r=0;}
        else runtime_fail(c,"DirectInput method",thunk);
    }
    else if(family==2){
        if(slot==3){
            nargs=2;uint32_t p=A(c,1),size=*(uint32_t *)guest_ptr(p,4);
            if(size<24||size>44)r=0x80070057;
            else{memset(guest_ptr(p,size),0,size);MR32(p)=size;MR32(p+4)=1;MR32(p+8)=kind==1?3:2;MR32(p+12)=kind==1?0:3;MR32(p+16)=kind==1?256:4;}
        }
        else if(slot==5||slot==6){
            nargs=3;uint32_t prop=A(c,1),p=A(c,2);
            if(prop!=1&&prop!=2)r=0x80004001;
            else if(!mem_valid(p,20)||MR32(p)!=20||MR32(p+4)!=16)r=0x80070057;
            else if(slot==5)MR32(p+16)=prop==1?MR32(self+16):1;
            else if(prop==1)MR32(self+16)=MR32(p+16)>1024?1024:MR32(p+16);
            else if(MR32(p+16)!=1)r=0x80004001;
        }
        else if(slot==7){MR32(self+12)=1;}
        else if(slot==8){MR32(self+12)=0;}
        else if(slot==9){
            nargs=3;unsigned size=A(c,1);void *out=guest_ptr(A(c,2),size);
            if(!MR32(self+12))r=0x8007000c;
            else if(kind==1&&size==256)input_keyboard_state(out);
            else if(kind==2&&(size==16||size==20))input_mouse_state(out,size);
            else r=0x80070057;
        }
        else if(slot==10){
            nargs=5;uint32_t stride=A(c,1),data=A(c,2),countp=A(c,3),flags=A(c,4);
            uint32_t count=*(uint32_t *)guest_ptr(countp,4);
            if(!MR32(self+12))r=0x8007000c;
            else if(!MR32(self+16))r=0x80040207;
            else if(stride!=16&&stride!=20)r=0x80070057;
            else{
                unsigned cap=count>1024?1024:count;InputEvent events[1024];
                unsigned n=input_events((int)kind,data?events:NULL,cap,flags&1);
                if(n&&getenv("NFSIV_INPUT_TRACE"))fprintf(stderr,"input device %u: %u buffered events, first %u=%08x\n",kind,n,data?events[0].offset:0,data?events[0].value:0);
                if(data){uint8_t *out=guest_ptr(data,(uint64_t)stride*n);for(unsigned i=0;i<n;i++){memset(out+i*stride,0,stride);memcpy(out+i*stride,&events[i],16);}}
                MR32(countp)=n;
            }
        }
        else if(slot==11){nargs=2;uint32_t format=A(c,1);guest_ptr(format,24);MR32(self+20)=format;}
        else if(slot==12){nargs=2;MR32(self+24)=A(c,1);input_set_event((int)kind,A(c,1));}
        else if(slot==13){nargs=3;}
        else if(slot==14){nargs=4;r=(uint32_t)object_info(A(c,1),kind,A(c,2),A(c,3));}
        else if(slot==15){nargs=2;uint32_t p=A(c,1),size=*(uint32_t *)guest_ptr(p,4);if(size<560||size>580)r=0x80070057;else{memset(guest_ptr(p,size),0,size);MR32(p)=size;guid(p+4,kind==1?0x6f1d2b61:0x6f1d2b60);guid(p+20,kind==1?0x6f1d2b61:0x6f1d2b60);MR32(p+36)=kind==1?3:2;strcpy((char *)g_mem+p+40,kind==1?"Keyboard":"Mouse");strcpy((char *)g_mem+p+300,kind==1?"Native Keyboard":"Native Mouse");}}
        else if(slot==25)r=0;
        else runtime_fail(c,"DirectInput device method",thunk);
    }
    else if(family==3){
        if(slot==20){nargs=3;MR32(self+32)=A(c,1);MR32(self+36)=A(c,2);}
        else if(slot==6){
            nargs=4;uint32_t p=A(c,1),*output=guest_ptr(A(c,2),4);*output=0;
            guest_ptr(p,108);
            if(MR32(p)!=108||!(MR32(p+4)&1))r=0x80070057;
            else if(A(c,3))r=0x80040110;
            else if(!(MR32(p+104)&0x200))r=0x80004001;
            else{
                uint32_t surface=com_object(6,0);
                MR32(surface+12)=(MR32(p+4)&4)?MR32(p+12):640;
                MR32(surface+16)=(MR32(p+4)&2)?MR32(p+8):480;
                *output=surface;
            }
        }else runtime_fail(c,"DirectDraw method",thunk);
    }
    else if(family==4||family==5){
        int sound_method(CPU *,uint32_t,unsigned,uint32_t *,uint32_t *);
        if(!sound_method(c,self,slot,&r,&nargs))runtime_fail(c,"DirectSound method",thunk);
    }
    else runtime_fail(c,"unknown COM family",thunk);
    c->eax=r;c->esp+=nargs*4;
}

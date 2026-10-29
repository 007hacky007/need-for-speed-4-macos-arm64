/* A Windows environment shared by guest modules, separate from the Mac environment. */
#include "runtime.h"
#include <stdlib.h>
#include <string.h>
#include <strings.h>
static struct {char *name,*value;} variables[64];
void gheap_free(int,uint32_t);
static uint32_t A(CPU *c,unsigned i){return MR32(c->esp+4*i);}
static char *string(uint32_t address,int wide){
    if(!address)return NULL;
    size_t n=0;
    for(;n<32767;n++){
        uint32_t p=address+(uint32_t)n*(wide?2:1);guest_ptr(p,wide?2:1);
        unsigned ch=wide?MR16(p):MR8(p);if(!ch)break;
        if(ch>255)return NULL;
    }
    if(n==32767)return NULL;
    char *out=malloc(n+1);if(!out)return NULL;
    for(size_t i=0;i<n;i++)out[i]=(char)(wide?MR16(address+2*(uint32_t)i):MR8(address+(uint32_t)i));
    out[n]=0;return out;
}
int environment_call(CPU *c,const char *name,uint32_t *out){
    uint32_t r=0;
    if(!strcmp(name,"GetEnvironmentStrings")||!strcmp(name,"GetEnvironmentStringsA")||!strcmp(name,"GetEnvironmentStringsW")){
        int wide=!strcmp(name,"GetEnvironmentStringsW");size_t count=1;
        for(unsigned i=0;i<64;i++)if(variables[i].name)count+=strlen(variables[i].name)+strlen(variables[i].value)+2;
        if(count==1)count=2;
        r=win32_alloc((uint32_t)count*(wide?2:1),1);uint32_t cursor=r;
        if(!r){win32_set_last_error(c,8);*out=0;return 1;}
        for(unsigned i=0;i<64;i++)if(variables[i].name){
            for(unsigned part=0;part<3;part++){
                const char *p=part==0?variables[i].name:part==1?"=":variables[i].value;
                for(;*p;p++){if(wide){MR16(cursor)=(unsigned char)*p;cursor+=2;}else MR8(cursor++)=(unsigned char)*p;}
            }
            cursor+=wide?2:1;
        }
    }
    else if(!strcmp(name,"FreeEnvironmentStringsA")||!strcmp(name,"FreeEnvironmentStringsW")){
        if(A(c,0))gheap_free(1,A(c,0));r=1;
    }
    else if(!strcmp(name,"SetEnvironmentVariableA")||!strcmp(name,"SetEnvironmentVariableW")
            ||!strcmp(name,"GetEnvironmentVariableA")||!strcmp(name,"GetEnvironmentVariableW")){
        int set=name[0]=='S',wide=name[strlen(name)-1]=='W';
        char *key=string(A(c,0),wide);
        if(!key||!*key||strchr(key,'=')){free(key);win32_set_last_error(c,87);*out=0;return 1;}
        unsigned index=64,empty=64;
        for(unsigned i=0;i<64;i++){
            if(!variables[i].name){if(empty==64)empty=i;}
            else if(!strcasecmp(variables[i].name,key)){index=i;break;}
        }
        if(set){
            if(!A(c,1)){
                if(index<64){free(variables[index].name);free(variables[index].value);variables[index].name=variables[index].value=NULL;}r=1;
            }else{
                char *value=string(A(c,1),wide);if(index==64)index=empty;
                if(!value||index==64){free(value);win32_set_last_error(c,8);}
                else{free(variables[index].name);free(variables[index].value);variables[index].name=key;key=NULL;variables[index].value=value;r=1;}
            }
        }else if(index==64)win32_set_last_error(c,203);
        else{
            size_t length=strlen(variables[index].value);uint32_t capacity=A(c,2),address=A(c,1);
            r=(uint32_t)length+1;
            if(capacity>length){
                guest_ptr(address,(length+1)*(wide?2:1));
                for(size_t i=0;i<=length;i++){if(wide)MR16(address+2*(uint32_t)i)=(unsigned char)variables[index].value[i];else MR8(address+(uint32_t)i)=(unsigned char)variables[index].value[i];}
                r=(uint32_t)length;
            }
        }
        free(key);
    }else return 0;
    *out=r;return 1;
}

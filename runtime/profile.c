/* Windows INI reads use the same game/save overlay as other guest files. */
#include "runtime.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>

int fileio_resolve_save(const char *,char *,size_t);

static char *trim(char *text){
    while(isspace((unsigned char)*text))text++;
    size_t n=strlen(text);while(n&&isspace((unsigned char)text[n-1]))text[--n]=0;
    return text;
}

static int profile_value(const char *path,const char *section,const char *key,char *out,size_t capacity){
    FILE *file=fopen(path,"r");if(!file)return -1;
    char *line=NULL;size_t bytes=0;int selected=0,result=-1;
    while(getline(&line,&bytes,file)>=0){
        char *p=trim(line);if(!*p||*p==';'||*p=='#')continue;
        if(*p=='['){char *end=strchr(p+1,']');selected=0;if(end){*end=0;selected=!strcasecmp(trim(p+1),section);}continue;}
        if(!selected)continue;
        char *equal=strchr(p,'=');if(!equal)continue;*equal++=0;
        if(strcasecmp(trim(p),key))continue;
        char *value=trim(equal);size_t n=strlen(value);
        if(n>=2&&((value[0]=='"'&&value[n-1]=='"')||(value[0]=='\''&&value[n-1]=='\''))){value++;n-=2;}
        size_t copy=capacity?(n<capacity?n:capacity-1):0;
        if(capacity){memcpy(out,value,copy);out[copy]=0;}
        result=(int)copy;break;
    }
    free(line);fclose(file);return result;
}

static const char *string(uint32_t p){
    if(!p)return NULL;
    for(unsigned i=0;i<32768;i++)if(!*(char*)guest_ptr(p+i,1))return (char*)g_mem+p;
    runtime_fail(g_cur_cpu,"unterminated INI argument",p);return NULL;
}

static uint32_t profile_list(const char *path,const char *section,int mode,char *out,uint32_t capacity){
    if(!capacity)return 0;
    memset(out,0,capacity<2?capacity:2);if(capacity<2)return 0;
    FILE *file=fopen(path,"r");if(!file)return 0;
    char *line=NULL;size_t bytes=0;int selected=0;uint32_t used=0;
    while(getline(&line,&bytes,file)>=0){
        char *p=trim(line),*entry=NULL;
        if(!*p||*p==';'||*p=='#')continue;
        if(*p=='['){
            char *end=strchr(p+1,']');selected=0;if(!end)continue;*end=0;p=trim(p+1);
            selected=section&&!strcasecmp(p,section);if(mode!=2)continue;
        }else{
            if(!selected||mode==2)continue;
            char *equal=strchr(p,'=');if(!equal)continue;*equal++=0;p=trim(p);
            if(mode==3){if(asprintf(&entry,"%s=%s",p,trim(equal))<0)break;p=entry;}
        }
        size_t n=strlen(p)+1;
        if(n>capacity-1-used){
            uint32_t copy=used<capacity-2?capacity-2-used:0;
            memcpy(out+used,p,copy);out[capacity-2]=out[capacity-1]=0;
            used=capacity-2;free(entry);break;
        }
        memcpy(out+used,p,n);used+=(uint32_t)n;out[used]=0;free(entry);
    }
    free(line);fclose(file);return used;
}

int profile_call(CPU *c,const char *name,uint32_t *out){
    int integer=!strcmp(name,"GetPrivateProfileIntA");
    int list=!strcmp(name,"GetPrivateProfileSectionA");
    if(!integer&&!list&&strcmp(name,"GetPrivateProfileStringA"))return 0;
    uint32_t *a=guest_ptr(c->esp,integer||list?16:24);
    if(list){
        const char *section=string(a[0]),*filename=string(a[3]);char path[1024];
        fileio_resolve_save(filename?filename:"nfs4.ini",path,sizeof path);
        *out=profile_list(path,section,3,a[2]?guest_ptr(a[1],a[2]):NULL,a[2]);return 1;
    }
    const char *section=string(a[0]),*key=string(a[1]);
    const char *filename=string(a[integer?3:5]);char path[1024];
    fileio_resolve_save(filename?filename:"nfs4.ini",path,sizeof path);
    if(!integer&&(!section||!key)){
        *out=profile_list(path,section,section?1:2,a[4]?guest_ptr(a[3],a[4]):NULL,a[4]);return 1;
    }
    if(!section||!key){*out=a[2];return 1;}
    if(integer){
        char value[64];int found=profile_value(path,section,key,value,sizeof value);
        *out=found<0?a[2]:(uint32_t)strtol(value,NULL,0);
    }else{
        uint32_t capacity=a[4];char *buffer=capacity?guest_ptr(a[3],capacity):NULL;
        int found=profile_value(path,section,key,buffer,capacity);
        if(found<0){
            const char *fallback=string(a[2]);if(!fallback)fallback="";
            size_t n=strlen(fallback);while(n&&fallback[n-1]==' ')n--;
            size_t copy=capacity?(n<capacity?n:capacity-1):0;
            if(capacity){memcpy(buffer,fallback,copy);buffer[copy]=0;}found=(int)copy;
        }
        *out=(uint32_t)found;
    }
    return 1;
}

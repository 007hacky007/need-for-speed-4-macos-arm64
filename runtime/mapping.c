/* File views use real shared mmap pages within reserved guest VA regions. */
#include "runtime.h"
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

#define MAP_BASE 0x00910000u
#define MAP_COUNT 128
#define VIEW_COUNT 256
typedef struct {int used,fd;uint32_t handles,views,protect;uint64_t size;char name[256];} Mapping;
typedef struct {uint32_t base,size,reserved;unsigned mapping,access;} View;
static Mapping mappings[MAP_COUNT];
static View views[VIEW_COUNT];
int fileio_dup_fd(uint32_t);
uint32_t guest_va_alloc(CPU *,uint32_t,uint32_t);
uint32_t guest_va_free(CPU *,uint32_t);
static uint32_t arg(CPU *c,unsigned i){return *(uint32_t *)guest_ptr(c->esp+i*4,4);}
static Mapping *lookup(uint32_t handle){return handle>=MAP_BASE && handle<MAP_BASE+MAP_COUNT && mappings[handle-MAP_BASE].used && mappings[handle-MAP_BASE].handles?&mappings[handle-MAP_BASE]:NULL;}
static void release(Mapping *m){if(!m->handles&&!m->views){close(m->fd);memset(m,0,sizeof *m);}}
static uint32_t error(CPU *c,uint32_t code){win32_set_last_error(c,code);return 0;}
static const char *name_at(uint32_t p){
 if(!p)return "";
 for(unsigned i=0;i<256;i++)if(!*(uint8_t *)guest_ptr(p+i,1))return (char *)g_mem+p;
 return NULL;
}
int mapping_call(CPU *c,const char *name,uint32_t *result){
 uint32_t r=0;
 if(!strcmp(name,"CreateFileMappingA")){
  const char *label=name_at(arg(c,5));uint32_t protect=arg(c,2),kind=protect&255;
  if(!label){*result=error(c,206);return 1;}
  for(unsigned i=0;*label && i<MAP_COUNT;i++)if(mappings[i].used&&!strcmp(mappings[i].name,label)){
   mappings[i].handles++;*result=MAP_BASE+i;win32_set_last_error(c,183);return 1;
  }
  if((kind!=2&&kind!=4&&kind!=8)||(protect&~0x080000ffu)){*result=error(c,87);return 1;}
  uint64_t size=((uint64_t)arg(c,3)<<32)|arg(c,4);int fd;
  if(arg(c,0)==0xffffffff){
   if(!size){*result=error(c,87);return 1;}
   FILE *temp=tmpfile();if(!temp){*result=error(c,8);return 1;}fd=dup(fileno(temp));fclose(temp);
  }else fd=fileio_dup_fd(arg(c,0));
  if(fd<0){*result=error(c,6);return 1;}
  struct stat st;if(fstat(fd,&st)){close(fd);*result=error(c,6);return 1;}
  if(!size)size=(uint64_t)st.st_size;
  if(!size||size>0x4fff0000u){close(fd);*result=error(c,size?8:1006);return 1;}
  if(kind==4 && (fcntl(fd,F_GETFL)&O_ACCMODE)==O_RDONLY){close(fd);*result=error(c,5);return 1;}
  if(size>(uint64_t)st.st_size && ftruncate(fd,(off_t)size)){close(fd);*result=error(c,5);return 1;}
  unsigned i;for(i=0;i<MAP_COUNT&&mappings[i].used;i++);
  if(i==MAP_COUNT){close(fd);*result=error(c,4);return 1;}
  mappings[i]=(Mapping){.used=1,.fd=fd,.handles=1,.protect=kind,.size=size};strcpy(mappings[i].name,label);r=MAP_BASE+i;win32_set_last_error(c,0);
 }else if(!strcmp(name,"OpenFileMappingA")){
  const char *label=name_at(arg(c,2));
  for(unsigned i=0;label&&i<MAP_COUNT;i++)if(mappings[i].used&&!strcmp(mappings[i].name,label)){mappings[i].handles++;r=MAP_BASE+i;break;}
  if(!r)error(c,2);
 }else if(!strcmp(name,"MapViewOfFile")){
  Mapping *m=lookup(arg(c,0));uint32_t access=arg(c,1);uint64_t offset=((uint64_t)arg(c,2)<<32)|arg(c,3),size=arg(c,4);
  if(!m){*result=error(c,6);return 1;}
  if(offset>=m->size || (offset&0xffff) || (size&&size>m->size-offset) || !(access&7) || (access&~0xf001fu)){*result=error(c,87);return 1;}
  if((access&2)&&m->protect!=4){*result=error(c,5);return 1;}
  if(!size)size=m->size-offset;
  unsigned i;for(i=0;i<VIEW_COUNT&&views[i].base;i++);
  if(i==VIEW_COUNT){*result=error(c,8);return 1;}
  uint32_t base=guest_va_alloc(c,(uint32_t)size,(access&3)?4:2);if(!base){*result=0;return 1;}
  int copy=(access&1)&&!(access&2),prot=PROT_READ|((access&2)||copy?PROT_WRITE:0);
  void *address=mmap(g_mem+base,(size_t)size,prot,MAP_FIXED|(copy?MAP_PRIVATE:MAP_SHARED),m->fd,(off_t)offset);
  if(address==MAP_FAILED){guest_va_free(c,base);*result=error(c,8);return 1;}
  views[i]=(View){.base=base,.size=(uint32_t)size,.reserved=((uint32_t)size+0xffffu)&~0xffffu,.mapping=(unsigned)(m-mappings),.access=access};m->views++;r=base;
 }else if(!strcmp(name,"UnmapViewOfFile")){
  unsigned i;for(i=0;i<VIEW_COUNT&&(!views[i].base||views[i].base!=arg(c,0));i++);
  if(i==VIEW_COUNT){*result=error(c,487);return 1;}
  View *v=&views[i];Mapping *m=&mappings[v->mapping];
  if(mmap(g_mem+v->base,v->reserved,PROT_NONE,MAP_PRIVATE|MAP_ANON|MAP_FIXED,-1,0)==MAP_FAILED)runtime_fail(c,"cannot restore guest VA reservation",v->base);
  r=guest_va_free(c,v->base);m->views--;release(m);memset(v,0,sizeof *v);
 }else if(!strcmp(name,"FlushViewOfFile")){
  uint32_t address=arg(c,0),size=arg(c,1);unsigned i;
  for(i=0;i<VIEW_COUNT;i++)if(views[i].base&&address>=views[i].base&&address-views[i].base<views[i].size)break;
  if(i==VIEW_COUNT || (size&&size>views[i].size-(address-views[i].base))){*result=error(c,487);return 1;}
  if(!size)size=views[i].size-(address-views[i].base);
  uint32_t start=address&~0x3fffu;r=msync(g_mem+start,(size_t)(address-start)+size,MS_SYNC)==0;if(!r)error(c,5);
 }else if(!strcmp(name,"CloseHandle")){
  Mapping *m=lookup(arg(c,0));if(!m)return 0;m->handles--;release(m);r=1;
 }else return 0;
 *result=r;return 1;
}

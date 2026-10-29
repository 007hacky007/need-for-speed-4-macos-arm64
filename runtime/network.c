/* Winsock initialization for the original game's single-player startup path. */
#include "runtime.h"
#include <string.h>
#include <strings.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>
static unsigned references;
static struct { int used, fd,virtual_local,virtual_peer; } sockets[128];
void guest_wait_begin(void);
void guest_wait_end(void);

static uint32_t A(CPU *c,unsigned i){ return MR32(c->esp+4*i); }
static uint32_t wsa_errno(int e){
    switch(e){
    case EAGAIN: case EINPROGRESS:return 10035;
    case EINTR:return 10004;case EACCES:case EPERM:return 10013;
    case EINVAL:return 10022;case ENOTSOCK:case EBADF:return 10038;
    case EMSGSIZE:return 10040;case EAFNOSUPPORT:return 10047;
    case EADDRINUSE:return 10048;case EADDRNOTAVAIL:return 10049;
    case ENETDOWN:return 10050;case ENETUNREACH:return 10051;
    case ECONNRESET:return 10054;case ENOTCONN:return 10057;
    case ETIMEDOUT:return 10060;case ECONNREFUSED:return 10061;
    case ENOPROTOOPT:return 10042;default:return 10022;
    }
}
static int socket_fd(uint32_t handle){
    uint32_t slot=handle-0xc0000000u;
    return slot<128 && sockets[slot].used ? sockets[slot].fd : -1;
}
static uint32_t socket_handle(int fd){
    if(fd<0)return 0xffffffff;
    for(unsigned i=0;i<128;i++)if(!sockets[i].used){
        sockets[i].used=1;sockets[i].fd=fd;sockets[i].virtual_local=sockets[i].virtual_peer=0;return 0xc0000000u+i;
    }
    close(fd);errno=EMFILE;return 0xffffffff;
}
static int address_in(uint32_t p,uint32_t n,struct sockaddr_in *address){
    if(n<16 || !mem_valid(p,16) || MR16(p)!=2){errno=EINVAL;return 0;}
    memset(address,0,sizeof *address);address->sin_len=16;address->sin_family=AF_INET;
    memcpy(&address->sin_port,g_mem+p+2,2);memcpy(&address->sin_addr,g_mem+p+4,4);
    uint32_t ip=ntohl(address->sin_addr.s_addr);
    /* A virtual NIC lets the original UDP provider initialize without using
     * a host address. Its transport stays within the local machine. */
    if(ip==0xc0000201u||ip==0)address->sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    else if(ip==0xffffffffu)address->sin_addr.s_addr=htonl(0x7fffffffu);
    else if((ip>>24)!=127){errno=ENETUNREACH;return 0;}
    return 1;
}
static int address_out(uint32_t p,uint32_t length,const struct sockaddr_in *address){
    if(!p || !length)return 1;
    if(!mem_valid(length,4) || MR32(length)<16 || !mem_valid(p,16)){errno=EINVAL;return 0;}
    memset(g_mem+p,0,16);MR16(p)=2;
    memcpy(g_mem+p+2,&address->sin_port,2);memcpy(g_mem+p+4,&address->sin_addr,4);MR32(length)=16;return 1;
}
static int set_in(uint32_t p,fd_set *set,int *maxfd){
    FD_ZERO(set);
    if(!p)return 1;
    if(!mem_valid(p,4) || MR32(p)>64 || !mem_valid(p+4,4ull*MR32(p)))return 0;
    for(uint32_t i=0;i<MR32(p);i++){
        int fd=socket_fd(MR32(p+4+4*i));
        if(fd<0 || fd>=FD_SETSIZE)return 0;
        FD_SET(fd,set);if(fd>*maxfd)*maxfd=fd;
    }
    return 1;
}
static void set_out(uint32_t p,const fd_set *set){
    if(!p)return;
    uint32_t count=MR32(p),out=0;
    for(uint32_t i=0;i<count;i++){
        uint32_t handle=MR32(p+4+4*i);int fd=socket_fd(handle);
        if(fd>=0 && FD_ISSET(fd,set))MR32(p+4+4*out++)=handle;
    }
    MR32(p)=out;
}

int network_call(CPU *c,const char *dll,const char *name,uint32_t *out){
    if (strcasecmp(dll,"WSOCK32.dll")) return 0;
    uint32_t r=0;
    if (!strcmp(name,"WSAStartup")){
        uint32_t version=MR32(c->esp), address=MR32(c->esp+4);
        unsigned major=version&255,minor=(version>>8)&255;
        if (major<1 || major>2) r=10092;
        else if (!address || !mem_valid(address,400)) r=10014;
        else {
            memset(guest_ptr(address,400),0,400);
            MR16(address)=(uint16_t)(major | ((major==1 ? (minor>1?1:minor) : (minor>2?2:minor))<<8));
            MR16(address+2)=0x202;
            strcpy((char *)g_mem+address+4,"NFSIV native sockets");
            strcpy((char *)g_mem+address+261,"Ready");
            MR16(address+390)=64; MR16(address+392)=65507;
            references++;
        }
    }
    else if (!strcmp(name,"WSACleanup")){
        if (references){
            if (!--references)for(unsigned i=0;i<128;i++)if(sockets[i].used){close(sockets[i].fd);sockets[i].used=0;}
        }
        else { r=0xffffffff; win32_set_last_error(c,10093); }
    }
    else if (!strcmp(name,"WSAGetLastError")) r=MR32(c->fs_base+0x34);
    else if(!strcmp(name,"socket")){
        if(!references){win32_set_last_error(c,10093);*out=0xffffffff;return 1;}
        if(A(c,0)!=2){win32_set_last_error(c,10047);*out=0xffffffff;return 1;}
        r=socket_handle(socket((int)A(c,0),(int)A(c,1),(int)A(c,2)));
        if(r==0xffffffff)win32_set_last_error(c,wsa_errno(errno));
    }
    else if(!strcmp(name,"closesocket")){
        int fd=socket_fd(A(c,0));
        if(fd<0){r=0xffffffff;win32_set_last_error(c,10038);}
        else{r=(uint32_t)close(fd);sockets[A(c,0)-0xc0000000u].used=0;}
    }
    else if(!strcmp(name,"htons") || !strcmp(name,"ntohs"))r=htons((uint16_t)A(c,0));
    else if(!strcmp(name,"htonl") || !strcmp(name,"ntohl"))r=htonl(A(c,0));
    else if(!strcmp(name,"gethostname")){
        static const char host[]="nfsiv-local";
        if(A(c,1)<sizeof host || !mem_valid(A(c,0),sizeof host)){r=0xffffffff;win32_set_last_error(c,10014);}
        else memcpy(g_mem+A(c,0),host,sizeof host);
    }
    else if(!strcmp(name,"gethostbyname")){
        const char *host=guest_ptr(A(c,0),1);struct in_addr address;
        if(!strcmp(host,"nfsiv-local"))address.s_addr=htonl(0xc0000201u);
        else if(!strcmp(host,"localhost"))address.s_addr=htonl(INADDR_LOOPBACK);
        else if(inet_pton(AF_INET,host,&address)!=1){win32_set_last_error(c,11001);*out=0;return 1;}
        uint32_t p=c->fs_base+0xe00;memset(guest_ptr(p,128),0,128);
        MR32(p)=p+32;strcpy((char *)g_mem+p+32,"nfsiv-local");MR32(p+4)=p+64;
        MR16(p+8)=2;MR16(p+10)=4;MR32(p+12)=p+68;MR32(p+68)=p+80;
        memcpy(g_mem+p+80,&address,4);r=p;
    }
    else if(!strcmp(name,"inet_addr"))r=inet_addr(guest_ptr(A(c,0),1));
    else if(!strcmp(name,"inet_ntoa")){
        struct in_addr address={.s_addr=A(c,0)};r=c->fs_base+0xf00;
        if(!inet_ntop(AF_INET,&address,guest_ptr(r,32),32))r=0;
    }
    else if(!strcmp(name,"__WSAFDIsSet")){
        uint32_t set=A(c,1);if(!mem_valid(set,4) || MR32(set)>64 || !mem_valid(set+4,4ull*MR32(set)))return 0;
        for(unsigned i=0;i<MR32(set);i++)if(MR32(set+4+4*i)==A(c,0)){r=1;break;}
    }
    else if(!strcmp(name,"select")){
        fd_set readset,writeset,errorset;int maxfd=-1;
        if(!set_in(A(c,1),&readset,&maxfd)||!set_in(A(c,2),&writeset,&maxfd)||!set_in(A(c,3),&errorset,&maxfd)){
            win32_set_last_error(c,10038);*out=0xffffffff;return 1;
        }
        struct timeval timeout,*pt=NULL;
        if(A(c,4)){uint32_t p=A(c,4);guest_ptr(p,8);timeout.tv_sec=(int32_t)MR32(p);timeout.tv_usec=(int32_t)MR32(p+4);pt=&timeout;}
        guest_wait_begin();int result=select(maxfd+1,A(c,1)?&readset:NULL,A(c,2)?&writeset:NULL,A(c,3)?&errorset:NULL,pt);int err=errno;guest_wait_end();
        r=(uint32_t)result;
        if(result<0)win32_set_last_error(c,wsa_errno(err));
        else{set_out(A(c,1),&readset);set_out(A(c,2),&writeset);set_out(A(c,3),&errorset);}
    }
    else {
        int fd=socket_fd(A(c,0)),result=-1;
        if(fd<0){win32_set_last_error(c,10038);*out=0xffffffff;return 1;}
        if(!strcmp(name,"bind") || !strcmp(name,"connect")){
            struct sockaddr_in address;
            if(address_in(A(c,1),A(c,2),&address)){
                int virtual=MR32(A(c,1)+4)==htonl(0xc0000201u)||MR32(A(c,1)+4)==0;
                guest_wait_begin();result=!strcmp(name,"bind")?bind(fd,(struct sockaddr *)&address,16):connect(fd,(struct sockaddr *)&address,16);
                int err=errno;guest_wait_end();errno=err;
                if(!result){if(!strcmp(name,"bind"))sockets[A(c,0)-0xc0000000u].virtual_local=virtual;else sockets[A(c,0)-0xc0000000u].virtual_peer=virtual;}
            }
        }
        else if(!strcmp(name,"getsockname") || !strcmp(name,"getpeername")){
            struct sockaddr_in address;socklen_t length=sizeof address;
            result=!strcmp(name,"getsockname")?getsockname(fd,(struct sockaddr *)&address,&length):getpeername(fd,(struct sockaddr *)&address,&length);
            if(!result && (!strcmp(name,"getsockname")?sockets[A(c,0)-0xc0000000u].virtual_local:sockets[A(c,0)-0xc0000000u].virtual_peer))address.sin_addr.s_addr=htonl(0xc0000201u);
            if(!result && !address_out(A(c,1),A(c,2),&address))result=-1;
        }
        else if(!strcmp(name,"setsockopt") || !strcmp(name,"getsockopt")){
            uint32_t p=A(c,3),length=A(c,4);int level=(int)A(c,1),option=(int)A(c,2);
            if(!strcmp(name,"setsockopt"))result=setsockopt(fd,level,option,guest_ptr(p,length),length);
            else{guest_ptr(length,4);socklen_t size=MR32(length);result=getsockopt(fd,level,option,guest_ptr(p,size),&size);MR32(length)=size;}
        }
        else if(!strcmp(name,"ioctlsocket")){
            uint32_t command=A(c,1),p=A(c,2);guest_ptr(p,4);
            if(command==0x8004667e){int flags=fcntl(fd,F_GETFL);result=flags<0?-1:fcntl(fd,F_SETFL,MR32(p)?flags|O_NONBLOCK:flags&~O_NONBLOCK);}
            else if(command==0x4004667f)result=ioctl(fd,FIONREAD,g_mem+p);
            else errno=EINVAL;
        }
        else if(!strcmp(name,"sendto") || !strcmp(name,"recvfrom")){
            void *data=guest_ptr(A(c,1),A(c,2));struct sockaddr_in address;socklen_t length=16;
            if(!strcmp(name,"sendto")){
                if(address_in(A(c,4),A(c,5),&address)){
                    guest_wait_begin();result=(int)sendto(fd,data,A(c,2),(int)A(c,3),(struct sockaddr *)&address,16);int err=errno;guest_wait_end();errno=err;
                }
            }else{
                guest_wait_begin();result=(int)recvfrom(fd,data,A(c,2),(int)A(c,3),(struct sockaddr *)&address,&length);int err=errno;guest_wait_end();errno=err;
                if(result>=0 && sockets[A(c,0)-0xc0000000u].virtual_local && ntohl(address.sin_addr.s_addr)==INADDR_LOOPBACK)address.sin_addr.s_addr=htonl(0xc0000201u);
                if(result>=0 && !address_out(A(c,4),A(c,5),&address))result=-1;
            }
        }
        else if(!strcmp(name,"send") || !strcmp(name,"recv")){
            void *data=guest_ptr(A(c,1),A(c,2));guest_wait_begin();
            result=(int)(!strcmp(name,"send")?send(fd,data,A(c,2),(int)A(c,3)):recv(fd,data,A(c,2),(int)A(c,3)));
            int err=errno;guest_wait_end();errno=err;
        }
        else if(!strcmp(name,"listen"))result=listen(fd,(int)A(c,1));
        else if(!strcmp(name,"shutdown"))result=shutdown(fd,(int)A(c,1));
        else return 0;
        if(result<0)win32_set_last_error(c,wsa_errno(errno));
        r=(uint32_t)result;
    }
    *out=r;return 1;
}

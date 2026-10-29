/* Locale and character APIs adapted from the donor Win32 runtime. */
#include "runtime.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>
static uint32_t ARG(CPU *c, int i){ return MR32(c->esp+4u*(uint32_t)i); }
int locale_call(CPU *c, const char *n, uint32_t *out){
    uint32_t r = 0;
    if (!strcmp(n,"CompareStringA")||!strcmp(n,"CompareStringW")){
        int wide=!strcmp(n,"CompareStringW");
        uint32_t left=ARG(c,2),right=ARG(c,4),flags=ARG(c,1);
        int ln=(int32_t)ARG(c,3),rn=(int32_t)ARG(c,5);
        if(ln<0){ln=0;while(wide?*(uint16_t *)guest_ptr(left+2u*(uint32_t)ln,2):*(uint8_t *)guest_ptr(left+(uint32_t)ln,1))ln++;}
        if(rn<0){rn=0;while(wide?*(uint16_t *)guest_ptr(right+2u*(uint32_t)rn,2):*(uint8_t *)guest_ptr(right+(uint32_t)rn,1))rn++;}
        guest_ptr(left,(uint64_t)(unsigned)ln*(wide?2:1));guest_ptr(right,(uint64_t)(unsigned)rn*(wide?2:1));
        r=2;
        // shortcut: ordinal Western text collation; add Windows locale ordering if localized sorting requires it.
        for(int i=0;i<ln&&i<rn;i++){
            unsigned a=wide?MR16(left+2u*(uint32_t)i):MR8(left+(uint32_t)i);
            unsigned b=wide?MR16(right+2u*(uint32_t)i):MR8(right+(uint32_t)i);
            if(flags&1){if(a>='a'&&a<='z')a-=32;if(b>='a'&&b<='z')b-=32;}
            if(a!=b){r=a<b?1:3;break;}
        }
        if(r==2 && ln!=rn)r=ln<rn?1:3;
    }
    else if (!strcmp(n,"MultiByteToWideChar")){ uint32_t src=ARG(c,2); int sl=(int)ARG(c,3);
        uint32_t dst=ARG(c,4); int dl=(int)ARG(c,5);
        if(sl<0) sl=(int)strlen((char*)(g_mem+src))+1;
        if(dl==0){ r=(uint32_t)sl; } else { int k=0; for(;k<sl&&k<dl;k++) MR16(dst+2u*k)=MR8(src+k); r=(uint32_t)k; } }
    else if (!strcmp(n,"WideCharToMultiByte")){ uint32_t src=ARG(c,2); int sl=(int)ARG(c,3);
        uint32_t dst=ARG(c,4); int dl=(int)ARG(c,5);
        if(sl<0){ sl=0; while(MR16(src+2u*sl)) sl++; sl++; }
        if(dl==0){ r=(uint32_t)sl; } else { int k=0; for(;k<sl&&k<dl;k++) MR8(dst+k)=(uint8_t)MR16(src+2u*k); r=(uint32_t)k; } }
    else if (!strcmp(n,"GetStringTypeW")||!strcmp(n,"GetStringTypeA")){
        /* A: (LCID,dwInfoType,src,cch,out)  W: (dwInfoType,src,cch,out) */
        int aform = (n[13]=='A');
        uint32_t info = ARG(c, aform?1:0);
        uint32_t src  = ARG(c, aform?2:1);
        int      cch  = (int)ARG(c, aform?3:2);
        uint32_t out  = ARG(c, aform?4:3);
        int wide = !aform;
        if (cch < 0){ cch = 0; if(wide){ while(MR16(src+2u*cch)) cch++; } else { while(MR8(src+cch)) cch++; } cch++; }
        if (info == 1 && out){                       /* CT_CTYPE1 */
            for (int k=0;k<cch;k++){
                uint32_t ch = wide ? MR16(src+2u*k) : MR8(src+k);
                uint16_t f = 0x0200;                 /* C1_DEFINED */
                if (ch<128){
                    if (ch>='A'&&ch<='Z') f |= 0x0001|0x0100;
                    if (ch>='a'&&ch<='z') f |= 0x0002|0x0100;
                    if (ch>='0'&&ch<='9') f |= 0x0004|0x0080;
                    if ((ch>='a'&&ch<='f')||(ch>='A'&&ch<='F')) f |= 0x0080;
                    if (ch==' ') f |= 0x0008|0x0040;
                    if (ch=='\t'||ch=='\n'||ch=='\r'||ch==0x0b||ch==0x0c) f |= 0x0008;
                    if (ch<0x20||ch==0x7f) f |= 0x0020;
                    if (ch>0x20&&ch<0x7f&&!(f&(0x0100|0x0004))) f |= 0x0010;
                } else f |= 0x0100;
                MR16(out+2u*k) = f;
            }
        }
        r = 1; }
    else if (!strcmp(n,"LCMapStringW")||!strcmp(n,"LCMapStringA")){
        int wide = (n[11]=='W');
        uint32_t flags = ARG(c,1), src = ARG(c,2); int cch = (int)ARG(c,3);
        uint32_t dst = ARG(c,4); int cchd = (int)ARG(c,5);
        if (cch < 0){ cch = 0; if(wide){ while(MR16(src+2u*cch)) cch++; } else { while(MR8(src+cch)) cch++; } cch++; }
        if (cchd == 0){ r = (uint32_t)cch; }
        else {
            int k=0;
            for (;k<cch && k<cchd;k++){
                uint32_t ch = wide ? MR16(src+2u*k) : MR8(src+k);
                if ((flags & 0x00000100u) && ch<128 && ch>='A' && ch<='Z') ch += 32;   /* LOWERCASE */
                if ((flags & 0x00000200u) && ch<128 && ch>='a' && ch<='z') ch -= 32;   /* UPPERCASE */
                if (wide) MR16(dst+2u*k)=(uint16_t)ch; else MR8(dst+k)=(uint8_t)ch;
            }
            r = (uint32_t)k;
        } }
    else if (!strcmp(n,"GetLocaleInfoA")||!strcmp(n,"GetLocaleInfoW")){
        int wide = (n[13]=='W');
        uint32_t lct = ARG(c,1) & 0xffffu, p = ARG(c,2); int cch = (int)ARG(c,3);
        const char *v = 0; char num[16];
        switch (lct){
        case 0x0001: v="0409"; break;                 /* ILANGUAGE            */
        case 0x0002: v="English"; break;              /* SLANGUAGE            */
        case 0x1001: v="English"; break;              /* SENGLANGUAGE         */
        case 0x1002: v="United States"; break;        /* SENGCOUNTRY          */
        case 0x0003: v="ENU"; break;                  /* SABBREVLANGNAME      */
        case 0x0005: v="US"; break;                   /* SABBREVCTRYNAME      */
        case 0x000E: v="."; break;                    /* SDECIMAL             */
        case 0x000F: v=","; break;                    /* STHOUSAND            */
        case 0x0014: v="2"; break;                    /* IDIGITS              */
        case 0x000B: snprintf(num,sizeof num,"%d",437);  v=num; break; /* IDEFAULTCODEPAGE */
        case 0x1004: snprintf(num,sizeof num,"%d",1252); v=num; break; /* IDEFAULTANSICODEPAGE */
        case 0x0019: v="$"; break;                    /* SCURRENCY            */
        case 0x001D: v="/"; break;                    /* SDATE                */
        case 0x001E: v=":"; break;                    /* STIME                */
        default:     v="";  break;
        }
        uint32_t len = (uint32_t)strlen(v) + 1;
        if (cch == 0) r = wide ? len : len;
        else if (p){ uint32_t k=0; for(;k<len-1 && k<(uint32_t)cch-1;k++){ if(wide) MR16(p+2u*k)=v[k]; else MR8(p+k)=v[k]; }
                     if(wide) MR16(p+2u*k)=0; else MR8(p+k)=0; r=k+1; }
        else r = 0; }
    else if (!strcmp(n,"MessageBoxA")){
        uint32_t txt=ARG(c,1), cap=ARG(c,2);
        fprintf(stderr,"\n*** GUEST MESSAGEBOX ***\n  title: %s\n  text : %s\n***\n",
                cap?(char*)(g_mem+cap):"(none)", txt?(char*)(g_mem+txt):"(none)");
        r = 1; }
    else return 0;
    *out = r; return 1;
}

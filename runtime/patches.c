/* Native equivalents of the NFS IV input fixes in SilentPatch Build 1.
 * Reference: CookiePLMonster/SilentPatchNFS90s, MIT license in third_party.
 * Windows DLL injection and Windows CPU affinity are unnecessary here.
 */
#include "patches.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
int native_patch_hook(CPU *c,uint32_t ip){
 if(ip==NFSIV_PATCH_RACE_MODE){
  unsigned thrash_requested_mode(void);unsigned mode=thrash_requested_mode();
  if(mode){fprintf(stderr,"Launcher race resolution: %s (mode %u)\n",getenv("NFSIV_RESOLUTION"),mode);c->eax=mode;}
  return 1;
 }
 if(ip!=NFSIV_PATCH_MOUSE&&ip!=NFSIV_PATCH_POLL)return 0;
 const char *setting=getenv("NFSIV_SILENTPATCH");if(setting&&!strcmp(setting,"0"))return 1;
 if(ip==NFSIV_PATCH_MOUSE){
  /* Preserve negative HRESULT errors and accept S_FALSE/DI_BUFFEROVERFLOW. */
  c->zf=(int32_t)MR32(c->ebp-12)>=0;
 }else if((int32_t)c->edi>=0)c->edi=0;
 return 1;
}

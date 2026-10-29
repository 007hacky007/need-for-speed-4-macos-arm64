/* Native Vulkan device check. No game files are read or executed. */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void){
    const char *extensions[]={VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName="NFSIV",.apiVersion=VK_API_VERSION_1_1};
    VkInstanceCreateInfo info={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .flags=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,.pApplicationInfo=&app,
        .enabledExtensionCount=1,.ppEnabledExtensionNames=extensions};
    uint32_t extension_count=0;vkEnumerateInstanceExtensionProperties(NULL,&extension_count,NULL);
    VkExtensionProperties *available=calloc(extension_count,sizeof *available);int portability=0;
    if(!available)return 1;
    if(vkEnumerateInstanceExtensionProperties(NULL,&extension_count,available)!=VK_SUCCESS){free(available);return 1;}
    for(uint32_t i=0;i<extension_count;i++)if(!strcmp(available[i].extensionName,extensions[0]))portability=1;
    free(available);
    if(!portability){info.flags=0;info.enabledExtensionCount=0;}
    VkInstance instance;
    VkResult result=vkCreateInstance(&info,NULL,&instance);
    if(result!=VK_SUCCESS){fprintf(stderr,"Vulkan instance failed: %d\n",result);return 1;}
    uint32_t count=16;VkPhysicalDevice devices[16];
    result=vkEnumeratePhysicalDevices(instance,&count,devices);
    if((result!=VK_SUCCESS&&result!=VK_INCOMPLETE)||!count){
        fprintf(stderr,"No Vulkan device: %d\n",result);vkDestroyInstance(instance,NULL);return 1;
    }
    for(uint32_t i=0;i<count;i++){
        VkPhysicalDeviceProperties properties;vkGetPhysicalDeviceProperties(devices[i],&properties);
        printf("Vulkan GPU: %s, API %u.%u.%u\n",properties.deviceName,
            VK_VERSION_MAJOR(properties.apiVersion),VK_VERSION_MINOR(properties.apiVersion),VK_VERSION_PATCH(properties.apiVersion));
    }
    vkDestroyInstance(instance,NULL);return 0;
}

/* Native Thrash backend. Vulkan draws and presents through MoltenVK. */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan.h>
#include "runtime.h"
#define BACKEND vulkan_
#include "backend_names.h"
#include "render.h"
#include "vulkan_shader.h"
#include <stdatomic.h>

void host_open_window(unsigned,unsigned);
void *host_metal_layer(void);
void host_frame_presented(void);
void guest_unlock(void);
void guest_lock(CPU *);

typedef struct {VkImage image;VkDeviceMemory memory;VkImageView view;unsigned w,h,levels,id;} Image;
typedef struct {VkBuffer buffer;VkDeviceMemory memory;void *data;size_t size;} Buffer;
typedef struct {
 unsigned primitive,cull,depth,write,func,blend,src,dst,depth_only;
 unsigned stencil,stencil_func,stencil_fail,stencil_zfail,stencil_pass,depth_correction;
} PipelineKey;
static VkInstance instance;
static VkPhysicalDevice physical;
static VkDevice device;
static VkQueue queue;
static uint32_t family;
static VkCommandPool command_pool;
static VkCommandBuffer command;
static VkFence fence;
static VkDescriptorSetLayout set_layout;
static VkDescriptorPool descriptor_pool;
static VkPipelineLayout pipeline_layout;
static VkRenderPass render_pass;
static VkFramebuffer framebuffer;
static VkShaderModule vertex_shader,fragment_shader;
static VkSurfaceKHR surface;
static VkSwapchainKHR swapchain;
static VkExtent2D swap_extent;
static VkImage swap_images[16];
static uint32_t swap_count;
static VkSemaphore acquired,finished;
static Image color,front_color,depth,white,textures[2048];
static Buffer vertices,states,staging;
static size_t vertex_cursor,state_cursor,state_alignment;
static unsigned descriptor_count,width,height,frames;
static int recording,in_pass;
static struct {PipelineKey key;VkPipeline value;} pipelines[1024];
static unsigned pipeline_count;
static VkSampler samplers[2][4][3][3];
static _Atomic int capture_requested,capture_busy,trace_frame;
static unsigned trace_draw;
static dispatch_queue_t capture_queue;
static void fail(const char *what,VkResult result){fprintf(stderr,"Vulkan: %s (%d)\n",what,result);exit(3);}
#define OK(call) do{VkResult checked_vk_result=(call);if(checked_vk_result!=VK_SUCCESS)fail(#call,checked_vk_result);}while(0)
static uint32_t memory_type(uint32_t mask,VkMemoryPropertyFlags flags){
 VkPhysicalDeviceMemoryProperties p;vkGetPhysicalDeviceMemoryProperties(physical,&p);
 for(uint32_t i=0;i<p.memoryTypeCount;i++)if((mask&(1u<<i))&&(p.memoryTypes[i].propertyFlags&flags)==flags)return i;
 fail("memory type unavailable",VK_ERROR_FEATURE_NOT_PRESENT);return 0;
}
static Buffer buffer_new(size_t bytes,VkBufferUsageFlags usage){
 Buffer b={.size=bytes};VkBufferCreateInfo info={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=bytes,.usage=usage};OK(vkCreateBuffer(device,&info,NULL,&b.buffer));
 VkMemoryRequirements req;vkGetBufferMemoryRequirements(device,b.buffer,&req);
 VkMemoryAllocateInfo allocation={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=req.size,.memoryTypeIndex=memory_type(req.memoryTypeBits,VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)};
 OK(vkAllocateMemory(device,&allocation,NULL,&b.memory));OK(vkBindBufferMemory(device,b.buffer,b.memory,0));OK(vkMapMemory(device,b.memory,0,VK_WHOLE_SIZE,0,&b.data));return b;
}
static void buffer_free(Buffer *b){if(!b->buffer)return;vkUnmapMemory(device,b->memory);vkDestroyBuffer(device,b->buffer,NULL);vkFreeMemory(device,b->memory,NULL);memset(b,0,sizeof *b);}
static void image_free(Image *i){if(!i->image)return;vkDestroyImageView(device,i->view,NULL);vkDestroyImage(device,i->image,NULL);vkFreeMemory(device,i->memory,NULL);memset(i,0,sizeof *i);}
static void begin_command(void){
 if(recording)return;
 VkCommandBufferBeginInfo info={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT};OK(vkBeginCommandBuffer(command,&info));recording=1;
}
static void end_pass(void){if(in_pass){vkCmdEndRenderPass(command);in_pass=0;}}
static void barrier(void){
 end_pass();begin_command();VkMemoryBarrier b={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT,.dstAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT};
 vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,1,&b,0,NULL,0,NULL);
}
static void transition(VkImage image,VkImageAspectFlags aspect,unsigned levels,VkImageLayout old,VkImageLayout layout){
 end_pass();begin_command();VkImageMemoryBarrier b={.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
  .srcAccessMask=old==VK_IMAGE_LAYOUT_UNDEFINED?0:VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT,.dstAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT,
  .oldLayout=old,.newLayout=layout,.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.image=image,.subresourceRange={aspect,0,levels,0,1}};
 vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,0,NULL,0,NULL,1,&b);
}
static Image image_new(unsigned w,unsigned h,unsigned levels,VkFormat format,VkImageUsageFlags usage,VkImageAspectFlags aspect){
 Image i={.w=w,.h=h,.levels=levels};
 VkImageCreateInfo info={.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,.imageType=VK_IMAGE_TYPE_2D,.format=format,.extent={w,h,1},.mipLevels=levels,.arrayLayers=1,.samples=VK_SAMPLE_COUNT_1_BIT,.tiling=VK_IMAGE_TILING_OPTIMAL,.usage=usage,.initialLayout=VK_IMAGE_LAYOUT_UNDEFINED};
 OK(vkCreateImage(device,&info,NULL,&i.image));VkMemoryRequirements req;vkGetImageMemoryRequirements(device,i.image,&req);
 VkMemoryAllocateInfo allocation={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=req.size,.memoryTypeIndex=memory_type(req.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
 OK(vkAllocateMemory(device,&allocation,NULL,&i.memory));OK(vkBindImageMemory(device,i.image,i.memory,0));
 VkImageViewCreateInfo view={.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,.image=i.image,.viewType=VK_IMAGE_VIEW_TYPE_2D,.format=format,.subresourceRange={aspect,0,levels,0,1}};
 OK(vkCreateImageView(device,&view,NULL,&i.view));transition(i.image,aspect,levels,VK_IMAGE_LAYOUT_UNDEFINED,aspect==VK_IMAGE_ASPECT_COLOR_BIT?VK_IMAGE_LAYOUT_GENERAL:VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL);return i;
}
static void wait_fence(void){
 CPU *cpu=g_cur_cpu;guest_unlock();VkResult r=vkWaitForFences(device,1,&fence,VK_TRUE,UINT64_MAX);guest_lock(cpu);if(r!=VK_SUCCESS)fail("GPU submission",r);
}
void render_flush(void){
 if(!recording)return;end_pass();OK(vkEndCommandBuffer(command));OK(vkResetFences(device,1,&fence));
 VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&command};OK(vkQueueSubmit(queue,1,&submit,fence));wait_fence();
 OK(vkResetCommandPool(device,command_pool,0));OK(vkResetDescriptorPool(device,descriptor_pool,0));recording=0;vertex_cursor=state_cursor=0;descriptor_count=0;
}
static VkShaderModule shader(const uint32_t *code,size_t size){VkShaderModule value;VkShaderModuleCreateInfo info={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=size,.pCode=code};OK(vkCreateShaderModule(device,&info,NULL,&value));return value;}
int render_init(void){
 if(device)return 1;
 const char *ext[]={VK_KHR_SURFACE_EXTENSION_NAME,VK_EXT_METAL_SURFACE_EXTENSION_NAME};
 VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="NFSIV",.apiVersion=VK_API_VERSION_1_1};
 VkInstanceCreateInfo info={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app,.enabledExtensionCount=2,.ppEnabledExtensionNames=ext};OK(vkCreateInstance(&info,NULL,&instance));
 uint32_t n=16;VkPhysicalDevice devices[16];OK(vkEnumeratePhysicalDevices(instance,&n,devices));if(!n)fail("No Vulkan GPU",VK_ERROR_INITIALIZATION_FAILED);physical=devices[0];
 uint32_t families=0;vkGetPhysicalDeviceQueueFamilyProperties(physical,&families,NULL);VkQueueFamilyProperties *props=calloc(families,sizeof *props);if(!props)fail("queue allocation",VK_ERROR_OUT_OF_HOST_MEMORY);vkGetPhysicalDeviceQueueFamilyProperties(physical,&families,props);
 family=UINT32_MAX;for(uint32_t i=0;i<families;i++)if(props[i].queueFlags&VK_QUEUE_GRAPHICS_BIT){family=i;break;}free(props);if(family==UINT32_MAX)fail("No graphics queue",VK_ERROR_INITIALIZATION_FAILED);
 float priority=1;VkDeviceQueueCreateInfo q={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};
 const char *extensions[]={VK_KHR_SWAPCHAIN_EXTENSION_NAME,"VK_KHR_portability_subset"};
 VkDeviceCreateInfo d={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&q,.enabledExtensionCount=2,.ppEnabledExtensionNames=extensions};OK(vkCreateDevice(physical,&d,NULL,&device));vkGetDeviceQueue(device,family,0,&queue);
 VkPhysicalDeviceProperties properties;vkGetPhysicalDeviceProperties(physical,&properties);state_alignment=properties.limits.minStorageBufferOffsetAlignment;if(state_alignment<sizeof(RenderState))state_alignment=sizeof(RenderState);state_alignment=(state_alignment+255)&~255ull;
 fprintf(stderr,"native Vulkan device: %s\n",properties.deviceName);
 VkCommandPoolCreateInfo pool={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=family,.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT};OK(vkCreateCommandPool(device,&pool,NULL,&command_pool));
 VkCommandBufferAllocateInfo allocation={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=command_pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};OK(vkAllocateCommandBuffers(device,&allocation,&command));
 VkFenceCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};OK(vkCreateFence(device,&fi,NULL,&fence));
 VkSemaphoreCreateInfo si={.sType=VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};OK(vkCreateSemaphore(device,&si,NULL,&acquired));OK(vkCreateSemaphore(device,&si,NULL,&finished));
 VkDescriptorSetLayoutBinding bindings[]={
  {.binding=0,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_FRAGMENT_BIT},
  {.binding=1,.descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_FRAGMENT_BIT},
  {.binding=2,.descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_FRAGMENT_BIT}};
 VkDescriptorSetLayoutCreateInfo layout={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,.bindingCount=3,.pBindings=bindings};OK(vkCreateDescriptorSetLayout(device,&layout,NULL,&set_layout));
 VkDescriptorPoolSize sizes[]={{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,4096},{VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,8192}};
 VkDescriptorPoolCreateInfo dp={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=4096,.poolSizeCount=2,.pPoolSizes=sizes};OK(vkCreateDescriptorPool(device,&dp,NULL,&descriptor_pool));
 VkPushConstantRange push={VK_SHADER_STAGE_VERTEX_BIT,0,8};VkPipelineLayoutCreateInfo pl={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=1,.pSetLayouts=&set_layout,.pushConstantRangeCount=1,.pPushConstantRanges=&push};OK(vkCreatePipelineLayout(device,&pl,NULL,&pipeline_layout));
 VkAttachmentDescription attachments[]={
  {.format=VK_FORMAT_B8G8R8A8_UNORM,.samples=VK_SAMPLE_COUNT_1_BIT,.loadOp=VK_ATTACHMENT_LOAD_OP_LOAD,.storeOp=VK_ATTACHMENT_STORE_OP_STORE,.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE,.stencilStoreOp=VK_ATTACHMENT_STORE_OP_DONT_CARE,.initialLayout=VK_IMAGE_LAYOUT_GENERAL,.finalLayout=VK_IMAGE_LAYOUT_GENERAL},
  {.format=VK_FORMAT_D32_SFLOAT_S8_UINT,.samples=VK_SAMPLE_COUNT_1_BIT,.loadOp=VK_ATTACHMENT_LOAD_OP_LOAD,.storeOp=VK_ATTACHMENT_STORE_OP_STORE,.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_LOAD,.stencilStoreOp=VK_ATTACHMENT_STORE_OP_STORE,.initialLayout=VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,.finalLayout=VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL}};
 VkAttachmentReference cref={0,VK_IMAGE_LAYOUT_GENERAL},dref={1,VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL};VkSubpassDescription sub={.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS,.colorAttachmentCount=1,.pColorAttachments=&cref,.pDepthStencilAttachment=&dref};
 VkSubpassDependency dependencies[]={
  {VK_SUBPASS_EXTERNAL,0,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT,VK_ACCESS_MEMORY_WRITE_BIT,VK_ACCESS_COLOR_ATTACHMENT_READ_BIT|VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT|VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT|VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,0},
  {0,VK_SUBPASS_EXTERNAL,VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT|VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT,0}};
 VkRenderPassCreateInfo rp={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,.attachmentCount=2,.pAttachments=attachments,.subpassCount=1,.pSubpasses=&sub,.dependencyCount=2,.pDependencies=dependencies};OK(vkCreateRenderPass(device,&rp,NULL,&render_pass));
 vertices=buffer_new(32*1024*1024,VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);states=buffer_new(4096*state_alignment,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
 vertex_shader=shader(vulkan_vert,sizeof vulkan_vert);fragment_shader=shader(vulkan_frag,sizeof vulkan_frag);
 white=image_new(1,1,1,VK_FORMAT_B8G8R8A8_UNORM,VK_IMAGE_USAGE_SAMPLED_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT,VK_IMAGE_ASPECT_COLOR_BIT);
 VkClearColorValue value={.float32={1,1,1,1}};VkImageSubresourceRange range={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};vkCmdClearColorImage(command,white.image,VK_IMAGE_LAYOUT_GENERAL,&value,1,&range);barrier();render_flush();return 1;
}
static void swap_create(void){
 if(!surface){VkMetalSurfaceCreateInfoEXT info={.sType=VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,.pLayer=(__bridge CAMetalLayer *)host_metal_layer()};OK(vkCreateMetalSurfaceEXT(instance,&info,NULL,&surface));VkBool32 supported;OK(vkGetPhysicalDeviceSurfaceSupportKHR(physical,family,surface,&supported));if(!supported)fail("GPU cannot present to window",VK_ERROR_INITIALIZATION_FAILED);}
 /* Retire the old swapchain first. MoltenVK 1.2 can resize its layer to
    finish pending presentation callbacks during destruction. */
 if(swapchain){vkDestroySwapchainKHR(device,swapchain,NULL);swapchain=VK_NULL_HANDLE;}
 VkSurfaceCapabilitiesKHR caps;OK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical,surface,&caps));
 swap_extent=caps.currentExtent;
 if(swap_extent.width==UINT32_MAX)swap_extent=(VkExtent2D){width,height};
 swap_extent.width=MAX(caps.minImageExtent.width,MIN(swap_extent.width,caps.maxImageExtent.width));
 swap_extent.height=MAX(caps.minImageExtent.height,MIN(swap_extent.height,caps.maxImageExtent.height));
 if(!(caps.supportedUsageFlags&VK_IMAGE_USAGE_TRANSFER_DST_BIT))fail("Swapchain transfer unsupported",VK_ERROR_FORMAT_NOT_SUPPORTED);
 uint32_t n=0;OK(vkGetPhysicalDeviceSurfaceFormatsKHR(physical,surface,&n,NULL));VkSurfaceFormatKHR *formats=calloc(n,sizeof *formats);if(!formats)fail("surface formats allocation",VK_ERROR_OUT_OF_HOST_MEMORY);OK(vkGetPhysicalDeviceSurfaceFormatsKHR(physical,surface,&n,formats));VkColorSpaceKHR colorspace=VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;int found=0;for(uint32_t i=0;i<n;i++)if(formats[i].format==VK_FORMAT_B8G8R8A8_UNORM){colorspace=formats[i].colorSpace;found=1;break;}free(formats);if(!found)fail("BGRA swapchain unavailable",VK_ERROR_FORMAT_NOT_SUPPORTED);
 uint32_t count=caps.minImageCount+1;if(caps.maxImageCount&&count>caps.maxImageCount)count=caps.maxImageCount;
 VkSwapchainCreateInfoKHR info={.sType=VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,.surface=surface,.minImageCount=count,.imageFormat=VK_FORMAT_B8G8R8A8_UNORM,.imageColorSpace=colorspace,.imageExtent=swap_extent,.imageArrayLayers=1,.imageUsage=VK_IMAGE_USAGE_TRANSFER_DST_BIT,.imageSharingMode=VK_SHARING_MODE_EXCLUSIVE,.preTransform=caps.currentTransform,.compositeAlpha=(caps.supportedCompositeAlpha&VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR)?VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR:VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,.presentMode=VK_PRESENT_MODE_FIFO_KHR,.clipped=VK_TRUE,.oldSwapchain=swapchain};
 VkSwapchainKHR next;OK(vkCreateSwapchainKHR(device,&info,NULL,&next));if(swapchain)vkDestroySwapchainKHR(device,swapchain,NULL);swapchain=next;
 swap_count=16;OK(vkGetSwapchainImagesKHR(device,swapchain,&swap_count,swap_images));
}
int render_mode(unsigned w,unsigned h){
 if(!w||!h||w>4096||h>4096)return 0;render_init();render_flush();OK(vkQueueWaitIdle(queue));
 if(framebuffer)vkDestroyFramebuffer(device,framebuffer,NULL);image_free(&color);image_free(&front_color);image_free(&depth);
 width=w;height=h;host_open_window(w,h);swap_create();
 VkImageUsageFlags usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT;
 color=image_new(w,h,1,VK_FORMAT_B8G8R8A8_UNORM,usage,VK_IMAGE_ASPECT_COLOR_BIT);front_color=image_new(w,h,1,VK_FORMAT_B8G8R8A8_UNORM,usage,VK_IMAGE_ASPECT_COLOR_BIT);
 depth=image_new(w,h,1,VK_FORMAT_D32_SFLOAT_S8_UINT,VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,VK_IMAGE_ASPECT_DEPTH_BIT|VK_IMAGE_ASPECT_STENCIL_BIT);
 VkImageView views[]={color.view,depth.view};VkFramebufferCreateInfo fb={.sType=VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,.renderPass=render_pass,.attachmentCount=2,.pAttachments=views,.width=w,.height=h,.layers=1};OK(vkCreateFramebuffer(device,&fb,NULL,&framebuffer));
 VkClearColorValue black={.float32={0,0,0,1}};VkImageSubresourceRange range={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1};vkCmdClearColorImage(command,front_color.image,VK_IMAGE_LAYOUT_GENERAL,&black,1,&range);
 int clip[]={0,0,(int)w,(int)h};render_clear(0xff000000,1,0,clip);return 1;
}
static void begin_pass(void){
 if(in_pass)return;begin_command();VkRenderPassBeginInfo info={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,.renderPass=render_pass,.framebuffer=framebuffer,.renderArea={{0,0},{width,height}}};vkCmdBeginRenderPass(command,&info,VK_SUBPASS_CONTENTS_INLINE);in_pass=1;
}
void render_clear(uint32_t c,float z,int depth_only,const int *clip){
 if(!color.image)return;int x=MAX(0,clip[0]),y=MAX(0,clip[1]),r=MIN((int)width,clip[2]),b=MIN((int)height,clip[3]);if(r<=x||b<=y)return;begin_pass();
 VkClearAttachment a[2]={{.aspectMask=VK_IMAGE_ASPECT_COLOR_BIT,.colorAttachment=0,.clearValue={.color={.float32={((c>>16)&255)/255.f,((c>>8)&255)/255.f,(c&255)/255.f,(c>>24)/255.f}}}},
 {.aspectMask=VK_IMAGE_ASPECT_DEPTH_BIT|VK_IMAGE_ASPECT_STENCIL_BIT,.clearValue={.depthStencil={z,0}}}};
 VkClearRect rect={{{x,y},{r-x,b-y}},0,1};vkCmdClearAttachments(command,depth_only?1:2,a+(depth_only?1:0),1,&rect);
}
static VkBlendFactor blend(unsigned f){static const VkBlendFactor values[]={VK_BLEND_FACTOR_ONE,VK_BLEND_FACTOR_ZERO,VK_BLEND_FACTOR_SRC_ALPHA,VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,VK_BLEND_FACTOR_DST_ALPHA,VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA,VK_BLEND_FACTOR_SRC_COLOR,VK_BLEND_FACTOR_DST_COLOR,VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR,VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR};if(f>=10)fail("blend factor",VK_ERROR_FEATURE_NOT_PRESENT);return values[f];}
static VkPipeline pipeline(const RenderState *s,unsigned primitive){
 PipelineKey key={primitive,s->cull,s->depth,s->depth_write,s->depth?s->depth_func:7,s->blend,s->src_blend,s->dst_blend,s->depth_only,s->stencil,s->stencil_func,s->stencil_fail,s->stencil_zfail,s->stencil_pass,render_decal_bias(s)!=0};
 for(unsigned i=0;i<pipeline_count;i++)if(!memcmp(&key,&pipelines[i].key,sizeof key))return pipelines[i].value;
 if(pipeline_count==1024||key.func>7||s->stencil_func>7||s->stencil_fail>7||s->stencil_zfail>7||s->stencil_pass>7)fail("invalid/exhausted pipeline state",VK_ERROR_FEATURE_NOT_PRESENT);
 VkPipelineShaderStageCreateInfo shaders[]={
 {.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_VERTEX_BIT,.module=vertex_shader,.pName="main"},
 {.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_FRAGMENT_BIT,.module=fragment_shader,.pName="main"}};
 VkVertexInputBindingDescription binding={0,sizeof(RenderVertex),VK_VERTEX_INPUT_RATE_VERTEX};VkVertexInputAttributeDescription attributes[]={{0,0,VK_FORMAT_R32G32B32A32_SFLOAT,0},{1,0,VK_FORMAT_R32G32_UINT,16},{2,0,VK_FORMAT_R32G32B32A32_SFLOAT,24}};
 VkPipelineVertexInputStateCreateInfo vi={.sType=VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,.vertexBindingDescriptionCount=1,.pVertexBindingDescriptions=&binding,.vertexAttributeDescriptionCount=3,.pVertexAttributeDescriptions=attributes};
 VkPipelineInputAssemblyStateCreateInfo ia={.sType=VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,.topology=primitive==0?VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST:primitive==1?VK_PRIMITIVE_TOPOLOGY_LINE_LIST:VK_PRIMITIVE_TOPOLOGY_POINT_LIST};
 VkPipelineViewportStateCreateInfo vp={.sType=VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,.viewportCount=1,.scissorCount=1};
 VkPipelineRasterizationStateCreateInfo rs={.sType=VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,.polygonMode=VK_POLYGON_MODE_FILL,.cullMode=s->cull==0?VK_CULL_MODE_NONE:s->cull==1?VK_CULL_MODE_BACK_BIT:VK_CULL_MODE_FRONT_BIT,.frontFace=VK_FRONT_FACE_CLOCKWISE,.depthBiasEnable=key.depth_correction,.lineWidth=1};
 VkPipelineMultisampleStateCreateInfo ms={.sType=VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT};
 VkStencilOpState st={.failOp=(VkStencilOp)s->stencil_fail,.passOp=(VkStencilOp)s->stencil_pass,.depthFailOp=(VkStencilOp)s->stencil_zfail,.compareOp=(VkCompareOp)s->stencil_func,.compareMask=255,.writeMask=255,.reference=0};
 VkPipelineDepthStencilStateCreateInfo ds={.sType=VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,.depthTestEnable=!!s->depth,.depthWriteEnable=!!s->depth_write,.depthCompareOp=(VkCompareOp)key.func,.stencilTestEnable=!!s->stencil,.front=st,.back=st};
 VkPipelineColorBlendAttachmentState ba={.blendEnable=!!s->blend,.srcColorBlendFactor=blend(s->src_blend),.dstColorBlendFactor=blend(s->dst_blend),.colorBlendOp=VK_BLEND_OP_ADD,.srcAlphaBlendFactor=blend(s->src_blend),.dstAlphaBlendFactor=blend(s->dst_blend),.alphaBlendOp=VK_BLEND_OP_ADD,.colorWriteMask=s->depth_only?0:15};
 VkPipelineColorBlendStateCreateInfo bs={.sType=VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,.attachmentCount=1,.pAttachments=&ba};
 VkDynamicState dynamic[]={VK_DYNAMIC_STATE_VIEWPORT,VK_DYNAMIC_STATE_SCISSOR,VK_DYNAMIC_STATE_DEPTH_BIAS};VkPipelineDynamicStateCreateInfo dy={.sType=VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,.dynamicStateCount=3,.pDynamicStates=dynamic};
 VkGraphicsPipelineCreateInfo info={.sType=VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,.stageCount=2,.pStages=shaders,.pVertexInputState=&vi,.pInputAssemblyState=&ia,.pViewportState=&vp,.pRasterizationState=&rs,.pMultisampleState=&ms,.pDepthStencilState=&ds,.pColorBlendState=&bs,.pDynamicState=&dy,.layout=pipeline_layout,.renderPass=render_pass};
 VkPipeline result;OK(vkCreateGraphicsPipelines(device,VK_NULL_HANDLE,1,&info,NULL,&result));pipelines[pipeline_count].key=key;pipelines[pipeline_count++].value=result;return result;
}
static Image *texture_find(unsigned id){for(unsigned i=0;i<2048;i++)if(textures[i].id==id&&textures[i].image)return &textures[i];return &white;}
static VkSampler sampler(const RenderState *s,unsigned i){
 unsigned f=!!s->filter[i],m=s->mip[i],u=s->address_u[i],v=s->address_v[i];if(m>3||u>2||v>2)fail("sampler state",VK_ERROR_FEATURE_NOT_PRESENT);
 if(!samplers[f][m][u][v]){VkSamplerAddressMode address[]={VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,VK_SAMPLER_ADDRESS_MODE_REPEAT,VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT};
  VkSamplerCreateInfo info={.sType=VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,.magFilter=f?VK_FILTER_LINEAR:VK_FILTER_NEAREST,.minFilter=f?VK_FILTER_LINEAR:VK_FILTER_NEAREST,.mipmapMode=m<2?VK_SAMPLER_MIPMAP_MODE_NEAREST:VK_SAMPLER_MIPMAP_MODE_LINEAR,.addressModeU=address[u],.addressModeV=address[v],.addressModeW=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,.maxLod=m?VK_LOD_CLAMP_NONE:0};OK(vkCreateSampler(device,&info,NULL,&samplers[f][m][u][v]));}
 return samplers[f][m][u][v];
}
void render_draw(const RenderVertex *v,unsigned count,unsigned primitive,const RenderState *s){
 if(!count)return;
 if(atomic_load(&trace_frame)==2){
  fprintf(stderr,"DRAW %u n=%u p=%u depth=%u write=%u cmp=%u blend=%u src=%u dst=%u tex=%x,%x combine=%u,%u alpha=%u,%u clip=%d,%d,%d,%d z0=%.9g z1=%.9g z2=%.9g xy0=%.2f,%.2f\n",trace_draw++,count,primitive,s->depth,s->depth_write,s->depth_func,s->blend,s->src_blend,s->dst_blend,s->texture[0],s->texture[1],s->combine[0],s->combine[1],s->alpha_ref,s->alpha_func,s->clip[0],s->clip[1],s->clip[2],s->clip[3],v[0].z,v[count>1?1:0].z,v[count>2?2:0].z,v[0].x,v[0].y);
 }
 size_t bytes=(size_t)count*sizeof *v;if(bytes>vertices.size)fail("vertex batch too large",VK_ERROR_OUT_OF_HOST_MEMORY);
 int x=MAX(0,s->clip[0]),y=MAX(0,s->clip[1]),r=MIN((int)width,s->clip[2]),b=MIN((int)height,s->clip[3]);if(r<=x||b<=y)return;
 if(vertex_cursor+bytes>vertices.size||state_cursor+state_alignment>states.size||descriptor_count==4096)render_flush();
 memcpy((char *)vertices.data+vertex_cursor,v,bytes);memcpy((char *)states.data+state_cursor,s,sizeof *s);
 VkDescriptorSet set;VkDescriptorSetAllocateInfo allocation={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=descriptor_pool,.descriptorSetCount=1,.pSetLayouts=&set_layout};OK(vkAllocateDescriptorSets(device,&allocation,&set));descriptor_count++;
 VkDescriptorBufferInfo buffer={states.buffer,state_cursor,sizeof *s};VkDescriptorImageInfo images[2];for(unsigned i=0;i<2;i++)images[i]=(VkDescriptorImageInfo){sampler(s,i),texture_find(s->texture[i])->view,VK_IMAGE_LAYOUT_GENERAL};
 VkWriteDescriptorSet writes[]={
 {.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=set,.dstBinding=0,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&buffer},
 {.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=set,.dstBinding=1,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,.pImageInfo=&images[0]},
 {.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=set,.dstBinding=2,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,.pImageInfo=&images[1]}};vkUpdateDescriptorSets(device,3,writes,0,NULL);
 begin_pass();vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline(s,primitive));VkViewport viewport={0,0,width,height,0,1};VkRect2D scissor={{x,y},{r-x,b-y}};vkCmdSetViewport(command,0,1,&viewport);vkCmdSetScissor(command,0,1,&scissor);
 float size[]={width,height};vkCmdPushConstants(command,pipeline_layout,VK_SHADER_STAGE_VERTEX_BIT,0,8,size);VkDeviceSize offset=vertex_cursor;vkCmdBindVertexBuffers(command,0,1,&vertices.buffer,&offset);vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline_layout,0,1,&set,0,NULL);vkCmdSetDepthBias(command,render_decal_bias(s),0,0);vkCmdDraw(command,count,1,0,0);vertex_cursor+=bytes;state_cursor+=state_alignment;
}
static void staging_size(size_t bytes){if(staging.size>=bytes)return;render_flush();buffer_free(&staging);staging=buffer_new(bytes,VK_BUFFER_USAGE_TRANSFER_SRC_BIT|VK_BUFFER_USAGE_TRANSFER_DST_BIT);}
int render_texture(unsigned id,unsigned w,unsigned h,unsigned level,unsigned levels,const uint32_t *pixels){
 if(!w||!h||!id||!levels||level>=levels)return 0;render_init();render_flush();Image *image=texture_find(id);
 if(image==&white){unsigned i;for(i=0;i<2048;i++)if(!textures[i].image)break;if(i==2048)return 0;image=&textures[i];*image=image_new(w<<level,h<<level,levels,VK_FORMAT_B8G8R8A8_UNORM,VK_IMAGE_USAGE_SAMPLED_BIT|VK_IMAGE_USAGE_TRANSFER_DST_BIT,VK_IMAGE_ASPECT_COLOR_BIT);image->id=id;}
 if(level>=image->levels||w!=MAX(1,image->w>>level)||h!=MAX(1,image->h>>level))return 0;
 staging_size((size_t)w*h*4);memcpy(staging.data,pixels,(size_t)w*h*4);barrier();VkBufferImageCopy copy={.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,level,0,1},.imageExtent={w,h,1}};vkCmdCopyBufferToImage(command,staging.buffer,image->image,VK_IMAGE_LAYOUT_GENERAL,1,&copy);barrier();render_flush();return 1;
}
void render_texture_free(unsigned id){if(!device)return;render_flush();Image *i=texture_find(id);if(i!=&white)image_free(i);}
int render_read(unsigned x,unsigned y,unsigned w,unsigned h,uint32_t *out,int front){
 if(!color.image||x>width||y>height||w>width-x||h>height-y)return 0;render_flush();staging_size((size_t)w*h*4);barrier();VkBufferImageCopy copy={.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.imageOffset={x,y,0},.imageExtent={w,h,1}};vkCmdCopyImageToBuffer(command,(front?front_color:color).image,VK_IMAGE_LAYOUT_GENERAL,staging.buffer,1,&copy);
 VkMemoryBarrier host={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT,.dstAccessMask=VK_ACCESS_HOST_READ_BIT};
 vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&host,0,NULL,0,NULL);render_flush();memcpy(out,staging.data,(size_t)w*h*4);return 1;
}
int render_write(unsigned x,unsigned y,unsigned w,unsigned h,const uint32_t *in,int front){
 if(!color.image||x>width||y>height||w>width-x||h>height-y)return 0;render_flush();staging_size((size_t)w*h*4);memcpy(staging.data,in,(size_t)w*h*4);barrier();VkBufferImageCopy copy={.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.imageOffset={x,y,0},.imageExtent={w,h,1}};vkCmdCopyBufferToImage(command,staging.buffer,(front?front_color:color).image,VK_IMAGE_LAYOUT_GENERAL,1,&copy);barrier();render_flush();return 1;
}
void render_present(int front){
 if(!color.image)return;render_flush();uint32_t index;VkResult result=vkAcquireNextImageKHR(device,swapchain,UINT64_MAX,acquired,VK_NULL_HANDLE,&index);
 if(result==VK_ERROR_OUT_OF_DATE_KHR){OK(vkQueueWaitIdle(queue));swap_create();return;}if(result!=VK_SUCCESS&&result!=VK_SUBOPTIMAL_KHR)fail("acquire frame",result);
 barrier();VkImageCopy copy={.srcSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.dstSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.extent={width,height,1}};
 if(!front){vkCmdCopyImage(command,color.image,VK_IMAGE_LAYOUT_GENERAL,front_color.image,VK_IMAGE_LAYOUT_GENERAL,1,&copy);barrier();}
 transition(swap_images[index],VK_IMAGE_ASPECT_COLOR_BIT,1,VK_IMAGE_LAYOUT_UNDEFINED,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
 VkImageBlit blit={.srcSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.srcOffsets={{0,0,0},{width,height,1}},.dstSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.dstOffsets={{0,0,0},{swap_extent.width,swap_extent.height,1}}};
 vkCmdBlitImage(command,front_color.image,VK_IMAGE_LAYOUT_GENERAL,swap_images[index],VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,1,&blit,VK_FILTER_LINEAR);
 transition(swap_images[index],VK_IMAGE_ASPECT_COLOR_BIT,1,VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
 OK(vkEndCommandBuffer(command));OK(vkResetFences(device,1,&fence));VkPipelineStageFlags stage=VK_PIPELINE_STAGE_TRANSFER_BIT;
 VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.waitSemaphoreCount=1,.pWaitSemaphores=&acquired,.pWaitDstStageMask=&stage,.commandBufferCount=1,.pCommandBuffers=&command,.signalSemaphoreCount=1,.pSignalSemaphores=&finished};OK(vkQueueSubmit(queue,1,&submit,fence));
 VkPresentInfoKHR present={.sType=VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,.waitSemaphoreCount=1,.pWaitSemaphores=&finished,.swapchainCount=1,.pSwapchains=&swapchain,.pImageIndices=&index};result=vkQueuePresentKHR(queue,&present);
 wait_fence();CPU *cpu=g_cur_cpu;guest_unlock();VkResult idle=vkQueueWaitIdle(queue);guest_lock(cpu);if(idle!=VK_SUCCESS)fail("presentation wait",idle);
 OK(vkResetCommandPool(device,command_pool,0));OK(vkResetDescriptorPool(device,descriptor_pool,0));recording=0;vertex_cursor=state_cursor=0;descriptor_count=0;
 if(result==VK_ERROR_OUT_OF_DATE_KHR||result==VK_SUBOPTIMAL_KHR)swap_create();else if(result!=VK_SUCCESS)fail("present",result);
 if(atomic_load(&trace_frame)==2){atomic_store(&trace_frame,0);fputs("DRAW end\n",stderr);}
 else if(atomic_load(&trace_frame)==1){trace_draw=0;atomic_store(&trace_frame,2);fputs("DRAW begin\n",stderr);}
 host_frame_presented();frames++;if(frames==1||frames%120==0)fprintf(stderr,"Vulkan presented frame %u\n",frames);
 const char *capture=getenv("NFSIV_CAPTURE");unsigned interval=capture?(unsigned)strtoul(capture,NULL,10):0;
 if(atomic_exchange(&capture_requested,0)||(interval&&(frames==1||frames==30||frames==120||frames==300||frames%(interval>1?interval:600)==0)))render_capture_frame(frames);
}
void render_request_capture(void){atomic_store(&capture_requested,1);if(getenv("NFSIV_DRAW_TRACE"))atomic_store(&trace_frame,1);}
void render_capture_frame(unsigned frame){
 if(!front_color.image||atomic_exchange(&capture_busy,1))return;
 NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:width*4 bitsPerPixel:32];
 if(!rep||!render_read(0,0,width,height,(uint32_t *)rep.bitmapData,1)){atomic_store(&capture_busy,0);return;}
 if(!capture_queue)capture_queue=dispatch_queue_create("org.nfsiv.vulkan.capture",DISPATCH_QUEUE_SERIAL);
 dispatch_async(capture_queue, ^{@autoreleasepool{
  size_t bytes=(size_t)rep.pixelsWide*rep.pixelsHigh*4;for(size_t i=0;i<bytes;i+=4){uint8_t *p=rep.bitmapData+i;uint8_t b=p[0];p[0]=p[2];p[2]=b;p[3]=255;}
  NSString *path=[NSString stringWithFormat:@"out/frame-%06u.png",frame];if(![[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES])fputs("cannot save Vulkan frame capture\n",stderr);atomic_store(&capture_busy,0);
 }});
}
void render_capture_wait(void){if(capture_queue)dispatch_sync(capture_queue, ^{});}

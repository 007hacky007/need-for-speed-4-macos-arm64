#ifndef NFSIV_INPUT_H
#define NFSIV_INPUT_H
#include <stdint.h>
int input_swap_buttons(int);
typedef struct { uint32_t offset, value, time, sequence; } InputEvent;
void input_key(unsigned scan,unsigned vk,int down);
void input_text(unsigned character);
void input_paste(const uint8_t *text,unsigned count);
void input_focus(int active);
void input_mouse(int x,int y,int button,int down,int wheel);
void input_mouse_motion(int dx,int dy,int width,int height);
void input_keyboard_state(uint8_t *out);
void input_mouse_state(void *out,unsigned size);
unsigned input_events(int kind,InputEvent *out,unsigned count,int peek);
void input_set_event(int kind,uint32_t handle);
int input_key_state(unsigned vk);
void input_cursor(int *x,int *y);
void input_pump(void);
int com_platform_call(struct CPU *,const char *,const char *,uint32_t *);
void com_call(struct CPU *,uint32_t);
#endif

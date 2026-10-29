#ifndef NFSIV_AUDIO_H
#define NFSIV_AUDIO_H
#include <stdint.h>
int audio_start(void);
int audio_capture_start(const char *);
void audio_shutdown(void);
int audio_create(uint32_t data,uint32_t bytes,uint32_t rate,uint32_t channels,uint32_t bits);
void audio_destroy(int id);
int audio_duplicate(int id);
void audio_play(int id,int loop);
void audio_stop(int id);
int audio_playing(int id);
void audio_cursors(int id,uint32_t *play,uint32_t *write);
void audio_set_position(int id,uint32_t bytes);
void audio_set_volume(int id,int millibels);
void audio_set_pan(int id,int millibels);
void audio_set_frequency(int id,uint32_t rate);
void audio_set_muted(int muted);
double audio_time(void);
void audio_mix(int16_t *output,unsigned frames);
#endif

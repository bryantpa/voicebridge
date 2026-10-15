#ifndef VB_ECHO_H
#define VB_ECHO_H
#include <stdint.h>
#include <stdbool.h>
#include <CoreAudio/CoreAudio.h>
typedef struct VBEcho VBEcho;
typedef struct VBSpeakerTap VBSpeakerTap;
typedef struct {
    uint64_t reference_frames,reference_drops,reference_callbacks,missing_samples,processed_samples,echo_frames,skipped_frames;
    double reference_db,reference_age_ms,pre_echo_db,post_echo_db,reference_lead_ms;
    int32_t reference_error;
} VBEchoStats;
VBEcho *vb_echo_create(void);
void vb_echo_destroy(VBEcho *);
// Single producer (tap), single consumer (microphone), normalized mono 48 kHz.
void vb_echo_reference(VBEcho *,const float *,uint32_t,uint64_t);
void vb_echo_reference_error(VBEcho *,int32_t);
void vb_echo_process(VBEcho *,const float *,float *,uint32_t,uint64_t);
VBEchoStats vb_echo_stats(VBEcho *);
VBSpeakerTap *vb_tap_start(VBEcho *,uint32_t,char *,uint32_t);
void vb_tap_stop(VBSpeakerTap *);
int vb_echo_selftest(void);
#endif

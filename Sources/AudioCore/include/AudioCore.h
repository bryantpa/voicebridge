#ifndef AUDIO_CORE_H
#define AUDIO_CORE_H
#include <stdint.h>
#include "Noise.h"
#include "Echo.h"
#include <stdbool.h>
#include <AudioToolbox/AudioToolbox.h>
typedef struct VBEngine VBEngine;
typedef struct {
    uint64_t input_frames, output_frames, input_callbacks, output_callbacks, reference_callbacks;
    uint64_t underruns, overflows, clipped_samples, invalid_samples, last_input_host_time, last_output_host_time;
    double rms_db, peak_db, queue_ms, rate_ratio, callback_age_ms, rnnoise_speech_probability, processing_ms;
    uint32_t input_block_frames;
    int32_t render_error, ducking_status;
    uint32_t actual_input, actual_speaker, actual_destination;
    bool bypass, agc, sending, rnnoise_enabled, echo_enabled;
    VBEchoStats echo;
} VBStats;
VBEngine *vb_create(void);
int32_t vb_start(VBEngine *, uint32_t mic, uint32_t speaker, uint32_t destination, bool sending, bool use_rnnoise, bool use_echo, char *error, uint32_t error_size);
void vb_stop(VBEngine *);
void vb_destroy(VBEngine *);
int32_t vb_bypass(VBEngine *, bool);
int32_t vb_agc(VBEngine *, bool);
VBStats vb_stats(VBEngine *);
// Opt-in processed audio only. Main thread drains this independent queue to disk.
void vb_recording(VBEngine *, bool);
uint32_t vb_read_recording(VBEngine *, float *, uint32_t);
uint64_t vb_recording_drops(VBEngine *);
// Diagnostic-only fixture injection, configured BEFORE vb_start. The capture
// callback discards live mic samples and processes this known signal instead.
// Read envelope bins only AFTER vb_stop. No waveform recording is performed.
bool vb_probe_prepare(VBEngine *, const float *, uint32_t, uint64_t origin);
bool vb_output_reserve(VBEngine *, uint32_t frames);
double vb_probe_reference_rms(VBEngine *, uint32_t bin);
uint32_t vb_probe_reference_count(VBEngine *, uint32_t bin);
// Isolated transport test: no devices or microphone access.
int vb_transport_selftest(void);
#endif

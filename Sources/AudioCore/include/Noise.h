#ifndef VB_NOISE_H
#define VB_NOISE_H
#include <stdint.h>
typedef struct VBNoise VBNoise;
VBNoise *vb_noise_create(void);
void vb_noise_destroy(VBNoise *);
// Mono normalized float, 48 kHz; arbitrary block sizes; safe in-place.
// Adds 480 samples of adapter latency, plus RNNoise's own algorithmic delay.
void vb_noise_process(VBNoise *, const float *, float *, uint32_t);
float vb_noise_probability(VBNoise *);
int vb_noise_selftest(void);
#endif

#include "AudioCore.h"
#include <stdio.h>
int main(void) {
    int result = vb_transport_selftest();
    if(result) {fprintf(stderr,"Transport test failed: %d\n",result);return result;}
    result=vb_noise_selftest();if(result){fprintf(stderr,"RNNoise adapter test failed: %d\n",result);return result+30;}
    result=vb_echo_selftest();if(result){fprintf(stderr,"Echo test failed: %d\n",result);return result+40;}
    VBEngine *e=vb_create();if(!e)return 20;
    vb_stop(e);vb_stop(e);
    if(vb_bypass(e,true)!=-50 || vb_agc(e,true)!=-50)return 21;
    VBStats s=vb_stats(e);if(s.input_frames || s.output_frames)return 22;
    vb_destroy(e);vb_destroy(NULL);
    puts("PASS: queue ordering, wrap, overflow, resampling, underrun recovery, safe engine teardown, large-input/small-output block mismatch, RNNoise chunk invariance and in-place processing, synthetic echo reduction and missing-reference fallback");return 0;
}

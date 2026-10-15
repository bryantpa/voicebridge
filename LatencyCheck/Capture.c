#include "Capture.h"
#include <AudioToolbox/AudioToolbox.h>
#include <mach/mach_time.h>
#include <stdlib.h>
#include <math.h>
#include <stdatomic.h>
#define BINS 8000
#define MAX_FRAMES 8192
struct LC {
    AudioUnit unit;
    uint64_t origin;
    double tickSeconds;
    uint32_t channels;
    float samples[2][MAX_FRAMES];
    double power[BINS];
    uint32_t count[BINS];
    uint64_t generated;
    _Atomic int32_t error;
};
static OSStatus capture(void *context,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 n,AudioBufferList *unused){
    LC *c=context;
    if(n>MAX_FRAMES||!(time->mFlags&kAudioTimeStampHostTimeValid)){atomic_store(&c->error,-7001);return noErr;}
    struct {UInt32 n;AudioBuffer b[2];} buffers={c->channels,{{1,n*4,c->samples[0]},{1,n*4,c->samples[1]}}};
    OSStatus s=AudioUnitRender(c->unit,flags,time,1,n,(AudioBufferList*)&buffers);
    if(s){atomic_store(&c->error,s);return s;}
    double first=((double)time->mHostTime-(double)c->origin)*c->tickSeconds;
    for(uint32_t i=0;i<n;i++){
        double seconds=first+i/48000.0;
        if(seconds<0||seconds>=BINS*0.002)continue;
        uint32_t bin=(uint32_t)(seconds/0.002);
        // Compare short energy envelopes; no recoverable waveform is retained.
        // Averaging channel power avoids cancellation of opposite-polarity channels.
        double energy=0;
        for(uint32_t channel=0;channel<c->channels;channel++){
            double v=c->samples[channel][i];if(!isfinite(v))v=0;energy+=v*v/c->channels;
        }
        c->power[bin]+=energy;c->count[bin]++;
    }
    return noErr;
}
LC *lc_create(void){LC*c=calloc(1,sizeof(LC));if(c){mach_timebase_info_data_t t;mach_timebase_info(&t);c->tickSeconds=(double)t.numer/t.denom/1e9;}return c;}
uint64_t lc_now(void){return mach_absolute_time();}
#define SET(key,scope,bus,value) do{s=AudioUnitSetProperty(c->unit,key,scope,bus,&value,sizeof(value));if(s)goto fail;}while(0)
int32_t lc_start(LC*c,uint32_t device,uint32_t channels,uint64_t origin){
    if(!c||channels<1||channels>2)return -50;c->channels=channels;c->origin=origin;
    AudioComponentDescription desc={.componentType=kAudioUnitType_Output,.componentSubType=kAudioUnitSubType_HALOutput,.componentManufacturer=kAudioUnitManufacturer_Apple};
    AudioComponent component=AudioComponentFindNext(NULL,&desc);if(!component)return -1;
    OSStatus s=AudioComponentInstanceNew(component,&c->unit);if(s)return s;
    UInt32 one=1,zero=0,max=MAX_FRAMES;
    SET(kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,one);
    SET(kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,zero);
    SET(kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,device);
    AudioStreamBasicDescription f={.mSampleRate=48000,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved,.mBytesPerPacket=4,.mFramesPerPacket=1,.mBytesPerFrame=4,.mChannelsPerFrame=channels,.mBitsPerChannel=32};
    SET(kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,f);
    SET(kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,max);
    AURenderCallbackStruct callback={capture,c};
    SET(kAudioOutputUnitProperty_SetInputCallback,kAudioUnitScope_Global,1,callback);
    s=AudioUnitInitialize(c->unit);if(s)goto fail;
    s=AudioOutputUnitStart(c->unit);if(s)goto fail;return 0;
fail:lc_stop(c);return s;
}
void lc_stop(LC*c){if(c&&c->unit){AudioOutputUnitStop(c->unit);AudioUnitUninitialize(c->unit);AudioComponentInstanceDispose(c->unit);c->unit=NULL;}}
static OSStatus probe(void*context,AudioUnitRenderActionFlags*flags,const AudioTimeStamp*time,UInt32 bus,UInt32 n,AudioBufferList*buffers){
    LC*c=context;
    if(!(time->mFlags&kAudioTimeStampHostTimeValid)){atomic_store(&c->error,-7001);return noErr;}
    double first=((double)time->mHostTime-(double)c->origin)*c->tickSeconds;
    for(uint32_t i=0;i<n;i++){
        uint64_t sample=c->generated++;
        // Quiet, amplitude-modulated tone with a deterministic non-repeating
        // envelope. No microphone input or saved user recording is transmitted.
        uint32_t segment=(uint32_t)(sample/1920),hash=segment*747796405u+2891336453u;
        hash=((hash>>((hash>>28)+4))^hash)*277803737u;hash=(hash>>22)^hash;
        double amplitude=0.001+0.014*(hash/(double)UINT32_MAX);
        double value=amplitude*sin(sample*(2*3.141592653589793*997/48000));
        double seconds=first+i/48000.0;
        if(seconds<0||seconds>=10.0)value=0;
        for(uint32_t channel=0;channel<buffers->mNumberBuffers;channel++){
            AudioBuffer*b=&buffers->mBuffers[channel];
            if(b->mData&&b->mDataByteSize>=(i+1)*4)((float*)b->mData)[i]=(float)value;
        }
        if(seconds>=0&&seconds<BINS*0.002){uint32_t bin=(uint32_t)(seconds/0.002);c->power[bin]+=value*value;c->count[bin]++;}
    }
    return noErr;
}
int32_t lc_start_output(LC*c,uint32_t device,uint64_t origin){
    if(!c)return -50;c->channels=2;c->origin=origin;
    AudioComponentDescription desc={.componentType=kAudioUnitType_Output,.componentSubType=kAudioUnitSubType_HALOutput,.componentManufacturer=kAudioUnitManufacturer_Apple};
    AudioComponent component=AudioComponentFindNext(NULL,&desc);if(!component)return -1;
    OSStatus s=AudioComponentInstanceNew(component,&c->unit);if(s)return s;
    SET(kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,device);
    AudioStreamBasicDescription f={.mSampleRate=48000,.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved,.mBytesPerPacket=4,.mFramesPerPacket=1,.mBytesPerFrame=4,.mChannelsPerFrame=2,.mBitsPerChannel=32};
    SET(kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,f);
    AURenderCallbackStruct callback={probe,c};
    SET(kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,callback);
    s=AudioUnitInitialize(c->unit);if(s)goto fail;
    s=AudioOutputUnitStart(c->unit);if(s)goto fail;return 0;
fail:lc_stop(c);return s;
}
void lc_destroy(LC*c){if(c){lc_stop(c);free(c);}}
double lc_bin_rms(LC*c,uint32_t i){return c&&i<BINS&&c->count[i]?sqrt(c->power[i]/c->count[i]):0;}
uint32_t lc_bin_count(LC*c,uint32_t i){return c&&i<BINS?c->count[i]:0;}
int32_t lc_error(LC*c){return c?atomic_load(&c->error):-1;}

#include "Driver.c"
#include <assert.h>
#include <stdio.h>
static VMTransport transport;
static float source[VM_CAPACITY*2], output[VM_CAPACITY*2];
static _Atomic(uint64_t) newest;
static _Atomic(bool) finished;
static void *writer(void *unused) {
    (void)unused;
    for(int64_t f=0;f<VM_CAPACITY*8;f++) {
        float v[2]={(float)(f+1),-(float)(f+1)};
        vm_write(&transport,f,1,v);atomic_store(&newest,(uint64_t)f);
    }
    atomic_store(&finished,true);return NULL;
}
static void *reader(void *unused) {
    (void)unused;
    do {
        int64_t f=(int64_t)atomic_load(&newest);float v[2];
        vm_read(&transport,f+VM_DELAY,1,v);
        assert((v[0]==0 && v[1]==0) || (v[0]==(float)(f+1) && v[1]==-(float)(f+1)));
    } while(!atomic_load(&finished));
    return NULL;
}
int main(void) {
    vm_reset(&transport);
    vm_read(&transport,0,1024,output);
    for(unsigned i=0;i<2048;i++) assert(output[i]==0);
    for(unsigned i=0;i<VM_CAPACITY*2;i++) source[i]=(float)i/100000;
    // Exact alignment, stereo integrity, wrap, independent repeated readers.
    vm_write(&transport,VM_CAPACITY-1000,2048,source);
    vm_read(&transport,VM_CAPACITY-1000+VM_DELAY,2048,output);
    assert(!memcmp(output,source,2048*2*sizeof(float)));
    vm_read(&transport,VM_CAPACITY-1000+VM_DELAY,2048,output);
    assert(!memcmp(output,source,2048*2*sizeof(float)));
    vm_read(&transport,2*VM_CAPACITY-1000+VM_DELAY,2048,output);
    for(unsigned i=0;i<4096;i++) assert(output[i]==0);
    vm_reset(&transport);
    vm_read(&transport,VM_CAPACITY-1000+VM_DELAY,2048,output);
    for(unsigned i=0;i<4096;i++) assert(output[i]==0);
    source[0]=NAN;source[1]=INFINITY;
    vm_write(&transport,0,1,source);vm_read(&transport,VM_DELAY,1,output);
    assert(output[0]==0 && output[1]==0);
    source[0]=0.25;source[1]=-0.25;
    // Exercise the actual plugin callback path, not just the helper.
    AudioServerPlugInIOCycleInfo cycle={0};
    cycle.mOutputTime.mSampleTime=1000;
    cycle.mInputTime.mSampleTime=1000+VM_DELAY;
    assert(!VoiceBridgeMic_StartIO(gAudioServerPlugInDriverRef,kObjectID_Device,1));
    assert(!VoiceBridgeMic_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device,kObjectID_Stream_Output,1,kAudioServerPlugInIOOperationWriteMix,128,&cycle,source,NULL));
    assert(!VoiceBridgeMic_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device,kObjectID_Stream_Input,2,kAudioServerPlugInIOOperationReadInput,128,&cycle,output,NULL));
    assert(!memcmp(output,source,256*sizeof(float)));
    assert(!VoiceBridgeMic_StartIO(gAudioServerPlugInDriverRef,kObjectID_Device,2));
    assert(!VoiceBridgeMic_StopIO(gAudioServerPlugInDriverRef,kObjectID_Device,1));
    assert(gDevice_IOIsRunning==1);
    assert(!VoiceBridgeMic_StopIO(gAudioServerPlugInDriverRef,kObjectID_Device,2));
    assert(!VoiceBridgeMic_StartIO(gAudioServerPlugInDriverRef,kObjectID_Device,3));
    assert(!VoiceBridgeMic_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device,kObjectID_Stream_Input,3,kAudioServerPlugInIOOperationReadInput,128,&cycle,output,NULL));
    for(unsigned i=0;i<256;i++) assert(output[i]==0);
    assert(VoiceBridgeMic_DoIOOperation(gAudioServerPlugInDriverRef,kObjectID_Device,kObjectID_Stream_Input,3,kAudioServerPlugInIOOperationReadInput,VM_CAPACITY+1,&cycle,output,NULL)!=0);
    AudioObjectPropertyAddress a={kAudioObjectPropertyOwnedObjects,kAudioObjectPropertyScopeGlobal,0};
    UInt32 size=0,used=0;AudioObjectID ids[2];
    assert(!VoiceBridgeMic_GetDevicePropertyDataSize(gAudioServerPlugInDriverRef,kObjectID_Device,0,&a,0,NULL,&size));
    assert(size==sizeof ids);
    assert(!VoiceBridgeMic_GetDevicePropertyData(gAudioServerPlugInDriverRef,kObjectID_Device,0,&a,0,NULL,size,&used,ids));
    assert(used==size && ids[0]==kObjectID_Stream_Input && ids[1]==kObjectID_Stream_Output);
    a.mSelector='vbst';CFStringRef stats=NULL;
    assert(!VoiceBridgeMic_GetDevicePropertyData(gAudioServerPlugInDriverRef,kObjectID_Device,0,&a,0,NULL,sizeof stats,&used,&stats));
    assert(stats && CFStringFind(stats,CFSTR("missingFrames"),0).location!=kCFNotFound);CFRelease(stats);
    a.mSelector=kAudioDevicePropertyAvailableNominalSampleRates;AudioValueRange rates[2];
    assert(!VoiceBridgeMic_GetDevicePropertyDataSize(gAudioServerPlugInDriverRef,kObjectID_Device,0,&a,0,NULL,&size));
    assert(size==sizeof(AudioValueRange));
    assert(!VoiceBridgeMic_GetDevicePropertyData(gAudioServerPlugInDriverRef,kObjectID_Device,0,&a,0,NULL,sizeof rates,&used,rates));
    assert(used==size && rates[0].mMinimum==48000 && rates[0].mMaximum==48000);
    a.mSelector=kAudioStreamPropertyAvailableVirtualFormats;AudioStreamRangedDescription formats[2];
    assert(!VoiceBridgeMic_GetStreamPropertyDataSize(gAudioServerPlugInDriverRef,kObjectID_Stream_Input,0,&a,0,NULL,&size));
    assert(size==sizeof(AudioStreamRangedDescription));
    assert(!VoiceBridgeMic_GetStreamPropertyData(gAudioServerPlugInDriverRef,kObjectID_Stream_Input,0,&a,0,NULL,sizeof formats,&used,formats));
    assert(used==size && formats[0].mFormat.mSampleRate==48000);
    mach_timebase_info_data_t tb;mach_timebase_info(&tb);
    gDevice_HostTicksPerFrame=1e9*tb.denom/tb.numer/48000;
    gDevice_AnchorHostTime=mach_absolute_time()-(uint64_t)(gDevice_HostTicksPerFrame*512*10);
    Float64 sampleTime;UInt64 hostTime,seed;
    assert(!VoiceBridgeMic_GetZeroTimeStamp(gAudioServerPlugInDriverRef,kObjectID_Device,3,&sampleTime,&hostTime,&seed));
    assert(sampleTime>=512*10 && seed==gClockSeed);
    assert(!VoiceBridgeMic_StopIO(gAudioServerPlugInDriverRef,kObjectID_Device,3));
    vm_reset(&transport);pthread_t w,r1,r2;
    assert(!pthread_create(&w,NULL,writer,NULL));
    assert(!pthread_create(&r1,NULL,reader,NULL));assert(!pthread_create(&r2,NULL,reader,NULL));
    pthread_join(w,NULL);pthread_join(r1,NULL);pthread_join(r2,NULL);
    puts("PASS: timestamp transport, missing/stale silence, stereo/wrap, multiple readers, restart, invalid size, driver callbacks and device enumeration.");
}

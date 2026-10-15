#include "AudioCore.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <mach/mach_time.h>
#define RATE 48000.0
#define CAP 32768u
#define MAX_FRAMES 8192u
#define TARGET 480u
// Each queue has exactly one producer and one consumer. Only its consumer moves r.
typedef struct { float data[CAP]; _Atomic uint64_t r,w,drops; } Queue;
static uint32_t push(Queue *q,const float *p,uint32_t n) {
    uint64_t w=atomic_load_explicit(&q->w,memory_order_relaxed),r=atomic_load_explicit(&q->r,memory_order_acquire);
    uint32_t count=(uint32_t)fmin(n,CAP-(w-r));
    for(uint32_t i=0;i<count;i++) q->data[(w+i)&(CAP-1)]=p[i];
    atomic_store_explicit(&q->w,w+count,memory_order_release);
    atomic_fetch_add(&q->drops,n-count); return count;
}
static uint32_t drain(Queue *q,float *p,uint32_t n) {
    uint64_t r=atomic_load_explicit(&q->r,memory_order_relaxed),w=atomic_load_explicit(&q->w,memory_order_acquire);
    uint32_t count=(uint32_t)fmin(n,w-r);
    for(uint32_t i=0;i<count;i++) p[i]=q->data[(r+i)&(CAP-1)];
    atomic_store_explicit(&q->r,r+count,memory_order_release);return count;
}
struct VBEngine {
    AudioUnit voice, destination;
    Queue queue, recording;
    float capture[MAX_FRAMES], clean[MAX_FRAMES];
    VBNoise *noise;
    VBEcho *echo;
    VBSpeakerTap *tap;
    _Atomic double speech_probability,processing_ms;
    _Atomic uint64_t input_frames,output_frames,input_callbacks,output_callbacks,reference_callbacks;
    _Atomic uint64_t underruns,clipped,invalid,last_input,last_output;
    _Atomic double rms,peak,ratio;
    _Atomic int32_t render_error;
    _Atomic uint32_t input_block_frames;
    _Atomic uint64_t callback_arrival;
    double host_tick_ms;
    _Atomic bool record;
    bool sending, primed,agc,use_rnnoise;
    _Atomic bool bypass;
    double phase;
    int32_t ducking_status;
    uint32_t actual_input,actual_speaker,actual_destination;
    uint32_t reserve_frames;
    float *probe_signal;
    uint32_t probe_count,probe_position;
    uint64_t probe_origin;
    double probe_power[8000];
    uint32_t probe_bins[8000];
};
static AudioStreamBasicDescription format(uint32_t channels) {
    AudioStreamBasicDescription f={0};f.mSampleRate=RATE;f.mFormatID=kAudioFormatLinearPCM;
    f.mFormatFlags=kAudioFormatFlagsNativeFloatPacked|kAudioFormatFlagIsNonInterleaved;
    f.mBytesPerPacket=4;f.mFramesPerPacket=1;f.mBytesPerFrame=4;f.mChannelsPerFrame=channels;f.mBitsPerChannel=32;return f;
}
static void silence(AudioBufferList *b) { if(b) for(uint32_t i=0;i<b->mNumberBuffers;i++) if(b->mBuffers[i].mData) memset(b->mBuffers[i].mData,0,b->mBuffers[i].mDataByteSize); }
static OSStatus reference(void *ctx,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *t,UInt32 bus,UInt32 n,AudioBufferList *b) {
    VBEngine *e=ctx;atomic_fetch_add(&e->reference_callbacks,1);silence(b);*flags|=kAudioUnitRenderAction_OutputIsSilence;return noErr;
}
static OSStatus capture(void *ctx,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *t,UInt32 bus,UInt32 n,AudioBufferList *unused) {
    VBEngine *e=ctx;
    if(n>MAX_FRAMES){atomic_store(&e->render_error,kAudioUnitErr_TooManyFramesToProcess);return kAudioUnitErr_TooManyFramesToProcess;}
    AudioBufferList b={.mNumberBuffers=1,.mBuffers={{.mNumberChannels=1,.mDataByteSize=n*4,.mData=e->capture}}};
    OSStatus s=AudioUnitRender(e->voice,flags,t,1,n,&b);
    if(s){atomic_store(&e->render_error,s);return s;}
    if(e->probe_signal){
        double first=((double)t->mHostTime-(double)e->probe_origin)*e->host_tick_ms;
        for(uint32_t i=0;i<n;i++){
            float value=e->probe_position<e->probe_count?e->probe_signal[e->probe_position++]:0;
            e->capture[i]=value;
            double ms=first+i/48.0;
            if(ms>=0&&ms<16000){uint32_t bin=(uint32_t)(ms/2);e->probe_power[bin]+=(double)value*value;e->probe_bins[bin]++;}
        }
    }
    uint64_t processing_start=mach_absolute_time();
    if(e->echo){
        vb_echo_process(e->echo,e->capture,e->clean,n,t->mHostTime);
        if(!atomic_load(&e->bypass))memcpy(e->capture,e->clean,n*sizeof(float));
    }
    if(e->noise){
        vb_noise_process(e->noise,e->capture,e->clean,n);
        atomic_store(&e->speech_probability,vb_noise_probability(e->noise));
        if(!atomic_load(&e->bypass))memcpy(e->capture,e->clean,n*sizeof(float));
    }
    atomic_store(&e->processing_ms,(mach_absolute_time()-processing_start)*e->host_tick_ms);
    double sum=0,peak=0;uint64_t clips=0,bad=0;
    for(uint32_t i=0;i<n;i++){float x=e->capture[i];if(!isfinite(x)){x=0;e->capture[i]=0;bad++;}double a=fabs(x);sum+=x*x;if(a>peak)peak=a;if(a>=1)clips++;}
    atomic_store(&e->input_block_frames,n);atomic_store(&e->callback_arrival,mach_absolute_time());
    atomic_store(&e->rms,n?sqrt(sum/n):0);atomic_store(&e->peak,peak);
    atomic_fetch_add(&e->clipped,clips);atomic_fetch_add(&e->invalid,bad);
    atomic_fetch_add(&e->input_callbacks,1);atomic_fetch_add(&e->input_frames,n);atomic_store(&e->last_input,t->mHostTime);
    if(e->sending)push(&e->queue,e->capture,n);
    if(atomic_load_explicit(&e->record,memory_order_relaxed))push(&e->recording,e->capture,n);
    return noErr;
}
static OSStatus output(void *ctx,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *t,UInt32 bus,UInt32 n,AudioBufferList *b) {
    VBEngine *e=ctx;silence(b);atomic_fetch_add(&e->output_callbacks,1);atomic_store(&e->last_output,t->mHostTime);
    uint64_t r=atomic_load_explicit(&e->queue.r,memory_order_relaxed),w=atomic_load_explicit(&e->queue.w,memory_order_acquire);
    uint64_t available=w-r;
    // Input is bursty (currently ~4096 samples), output may request only 512.
    // Prime above a whole capture block; steer around the midpoint of its sawtooth.
    uint32_t block=atomic_load(&e->input_block_frames);
    double target=e->reserve_frames+block*0.5;
    if(!e->primed){if(available<e->reserve_frames+block+n)return noErr;e->primed=true;e->phase=0;}
    // Slow, bounded fractional resampling absorbs independent mic/virtual-device clock drift.
    double correction=fmax(-0.003,fmin(0.003,((double)available-target-n)*0.0000005));
    double ratio=1+correction;atomic_store(&e->ratio,ratio);
    uint32_t needed=(uint32_t)ceil(e->phase+n*ratio)+1;
    if(available<needed){atomic_fetch_add(&e->underruns,1);e->primed=false;return noErr;}
    for(uint32_t i=0;i<n;i++){
        uint64_t offset=(uint64_t)e->phase;double fraction=e->phase-offset;
        float a=e->queue.data[(r+offset)&(CAP-1)],z=e->queue.data[(r+offset+1)&(CAP-1)];
        float value=(float)(a+(z-a)*fraction);
        for(uint32_t c=0;c<b->mNumberBuffers;c++)if(b->mBuffers[c].mData && b->mBuffers[c].mDataByteSize>=(i+1)*4)((float*)b->mBuffers[c].mData)[i]=value;
        e->phase+=ratio;
    }
    uint64_t consumed=(uint64_t)e->phase;e->phase-=consumed;
    atomic_store_explicit(&e->queue.r,r+consumed,memory_order_release);atomic_fetch_add(&e->output_frames,n);return noErr;
}
VBEngine *vb_create(void){VBEngine *e=calloc(1,sizeof(VBEngine));if(e){e->reserve_frames=TARGET;atomic_store(&e->ratio,1);mach_timebase_info_data_t tb;mach_timebase_info(&tb);e->host_tick_ms=(double)tb.numer/tb.denom/1000000.0;}return e;}
bool vb_output_reserve(VBEngine*e,uint32_t frames){if(!e||e->voice||frames<480||frames>2880)return false;e->reserve_frames=frames;return true;}
void vb_stop(VBEngine *e){if(!e)return;atomic_store(&e->record,false);if(e->destination){AudioOutputUnitStop(e->destination);AudioUnitUninitialize(e->destination);AudioComponentInstanceDispose(e->destination);e->destination=NULL;}if(e->voice){AudioOutputUnitStop(e->voice);AudioUnitUninitialize(e->voice);AudioComponentInstanceDispose(e->voice);e->voice=NULL;}if(e->tap){vb_tap_stop(e->tap);e->tap=NULL;}}
void vb_destroy(VBEngine *e){if(e){vb_stop(e);vb_noise_destroy(e->noise);vb_echo_destroy(e->echo);free(e->probe_signal);free(e);}}
bool vb_probe_prepare(VBEngine*e,const float*signal,uint32_t count,uint64_t origin){
    if(!e||e->voice||e->probe_signal||!signal||!count||count>480000)return false;
    e->probe_signal=malloc(count*sizeof(float));if(!e->probe_signal)return false;
    memcpy(e->probe_signal,signal,count*sizeof(float));e->probe_count=count;e->probe_origin=origin;return true;
}
double vb_probe_reference_rms(VBEngine*e,uint32_t bin){return e&&bin<8000&&e->probe_bins[bin]?sqrt(e->probe_power[bin]/e->probe_bins[bin]):0;}
uint32_t vb_probe_reference_count(VBEngine*e,uint32_t bin){return e&&bin<8000?e->probe_bins[bin]:0;}
static OSStatus make(OSType subtype,AudioUnit *unit){AudioComponentDescription d={.componentType=kAudioUnitType_Output,.componentSubType=subtype,.componentManufacturer=kAudioUnitManufacturer_Apple};AudioComponent c=AudioComponentFindNext(NULL,&d);return c?AudioComponentInstanceNew(c,unit):kAudioUnitErr_InvalidProperty;}
static uint32_t current(AudioUnit u,uint32_t bus){uint32_t device=0,size=4;AudioUnitGetProperty(u,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,bus,&device,&size);return device;}
#define TRY(call,label) do{s=(call);if(s){snprintf(error,error_size,"%s (OSStatus %d)",label,(int)s);vb_stop(e);return s;}}while(0)
#define PROP(unit,key,scope,bus,value) AudioUnitSetProperty(unit,key,scope,bus,&value,sizeof(value))
int32_t vb_start(VBEngine *e,uint32_t mic,uint32_t speaker,uint32_t dest,bool sending,bool use_rnnoise,bool use_echo,char *error,uint32_t error_size){
    if(!e||e->voice)return -50;
    if(use_echo&&!use_rnnoise){snprintf(error,error_size,"Echo experiment requires RNNoise mode");return -50;}
    if(use_echo){
        e->echo=vb_echo_create();if(!e->echo){snprintf(error,error_size,"Could not initialize echo canceller");return -1;}
        e->tap=vb_tap_start(e->echo,speaker,error,error_size);if(!e->tap)return -1;
    }
    e->sending=sending;e->agc=false;e->use_rnnoise=use_rnnoise;
    if(use_rnnoise){e->noise=vb_noise_create();if(!e->noise){snprintf(error,error_size,"Could not initialize RNNoise");return -1;}}OSStatus s;UInt32 one=1,zero=0,max=MAX_FRAMES,voice_bypass=use_rnnoise?1:0;
    // RNNoise + our speaker tap do not use Apple's voice processor. Its bypassed
    // path still delivered ~4096-frame/85 ms blocks on this Mac. Use direct HAL
    // input instead; leave the hardware's shared buffer settings unchanged.
    TRY(make(use_rnnoise?kAudioUnitSubType_HALOutput:kAudioUnitSubType_VoiceProcessingIO,&e->voice),"Create microphone input");
    TRY(PROP(e->voice,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,one),"Enable microphone");
    if(use_rnnoise){
        TRY(PROP(e->voice,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,zero),"Disable unused speaker output");
        TRY(PROP(e->voice,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,mic),"Select direct microphone");
    }else{
        TRY(PROP(e->voice,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,one),"Enable echo-reference output");
        TRY(PROP(e->voice,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,1,mic),"Select microphone");
        TRY(PROP(e->voice,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,speaker),"Select physical speaker reference");
    }
    AudioStreamBasicDescription mono=format(1);
    TRY(PROP(e->voice,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,1,mono),"Set microphone client format");
    TRY(PROP(e->voice,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,max),"Set maximum audio block");
    AURenderCallbackStruct cap={capture,e},ref={reference,e};
    TRY(PROP(e->voice,kAudioOutputUnitProperty_SetInputCallback,kAudioUnitScope_Global,1,cap),"Install capture callback");
    if(!use_rnnoise){
        TRY(PROP(e->voice,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,mono),"Set reference client format");
        TRY(PROP(e->voice,kAUVoiceIOProperty_BypassVoiceProcessing,kAudioUnitScope_Global,0,voice_bypass),"Configure Apple processing");
        TRY(PROP(e->voice,kAUVoiceIOProperty_VoiceProcessingEnableAGC,kAudioUnitScope_Global,0,zero),"Disable automatic gain changes");
        AUVoiceIOOtherAudioDuckingConfiguration duck={.mEnableAdvancedDucking=false,.mDuckingLevel=kAUVoiceIOOtherAudioDuckingLevelMin};
        e->ducking_status=PROP(e->voice,kAUVoiceIOProperty_OtherAudioDuckingConfiguration,kAudioUnitScope_Global,0,duck);
        TRY(PROP(e->voice,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,ref),"Install silent output callback");
    }
    TRY(AudioUnitInitialize(e->voice),"Initialize microphone input");
    e->actual_input=current(e->voice,use_rnnoise?0:1);e->actual_speaker=use_rnnoise?speaker:current(e->voice,0);
    if(sending){
        TRY(make(kAudioUnitSubType_HALOutput,&e->destination),"Create UNIFY output");
        TRY(PROP(e->destination,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,dest),"Select UNIFY output");
        AudioStreamBasicDescription stereo=format(2);AURenderCallbackStruct out={output,e};
        TRY(PROP(e->destination,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,stereo),"Set UNIFY client format");
        TRY(PROP(e->destination,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,out),"Install UNIFY output callback");
        TRY(AudioUnitInitialize(e->destination),"Initialize UNIFY output");e->actual_destination=current(e->destination,0);
    }
    TRY(AudioOutputUnitStart(e->voice),"Start microphone processing");
    if(sending)TRY(AudioOutputUnitStart(e->destination),"Start UNIFY output");
    return noErr;
}
int32_t vb_bypass(VBEngine *e,bool b){if(!e||!e->voice)return -50;if(e->use_rnnoise){atomic_store(&e->bypass,b);return noErr;}UInt32 v=b;OSStatus s=PROP(e->voice,kAUVoiceIOProperty_BypassVoiceProcessing,kAudioUnitScope_Global,0,v);if(!s)e->bypass=b;return s;}
int32_t vb_agc(VBEngine *e,bool b){if(!e||!e->voice||e->use_rnnoise)return -50;UInt32 v=b;OSStatus s=PROP(e->voice,kAUVoiceIOProperty_VoiceProcessingEnableAGC,kAudioUnitScope_Global,0,v);if(!s)e->agc=b;return s;}
static double db(double x){return x>0?fmax(-120,20*log10(x)):-120;}
VBStats vb_stats(VBEngine *e){VBStats s={0};if(!e)return s;
    s.input_frames=atomic_load(&e->input_frames);s.output_frames=atomic_load(&e->output_frames);s.input_callbacks=atomic_load(&e->input_callbacks);s.output_callbacks=atomic_load(&e->output_callbacks);s.reference_callbacks=atomic_load(&e->reference_callbacks);
    s.underruns=atomic_load(&e->underruns);s.overflows=atomic_load(&e->queue.drops);s.clipped_samples=atomic_load(&e->clipped);s.invalid_samples=atomic_load(&e->invalid);s.render_error=atomic_load(&e->render_error);
    s.last_input_host_time=atomic_load(&e->last_input);s.last_output_host_time=atomic_load(&e->last_output);
    uint64_t r=atomic_load(&e->queue.r),w=atomic_load(&e->queue.w);s.queue_ms=(w>=r?w-r:0)*1000.0/RATE;
    s.rms_db=db(atomic_load(&e->rms));s.peak_db=db(atomic_load(&e->peak));s.rate_ratio=atomic_load(&e->ratio);
    s.input_block_frames=atomic_load(&e->input_block_frames);uint64_t arrived=atomic_load(&e->callback_arrival),now=mach_absolute_time();s.callback_age_ms=arrived && now>=arrived?(now-arrived)*e->host_tick_ms:-1;
    s.echo_enabled=e->echo!=NULL;s.echo=vb_echo_stats(e->echo);
    s.rnnoise_enabled=e->use_rnnoise;s.rnnoise_speech_probability=atomic_load(&e->speech_probability);s.processing_ms=atomic_load(&e->processing_ms);
    s.ducking_status=e->ducking_status;s.actual_input=e->actual_input;s.actual_speaker=e->actual_speaker;s.actual_destination=e->actual_destination;s.bypass=e->bypass;s.agc=e->agc;s.sending=e->sending;return s;
}
void vb_recording(VBEngine *e,bool b){if(e)atomic_store(&e->record,b);}
uint32_t vb_read_recording(VBEngine *e,float *p,uint32_t n){return e?drain(&e->recording,p,n):0;}
uint64_t vb_recording_drops(VBEngine *e){return e?atomic_load(&e->recording.drops):0;}
int vb_transport_selftest(void){
    Queue *q=calloc(1,sizeof(Queue));if(!q)return 1;float in[257],out[257];
    for(int k=0;k<1000;k++){for(int j=0;j<257;j++)in[j]=(float)(k*257+j);if(push(q,in,257)!=257||drain(q,out,257)!=257){free(q);return 2;}if(memcmp(in,out,sizeof(in))){free(q);return 3;}}
    float *full=calloc(CAP,sizeof(float));if(!full){free(q);return 4;}push(q,full,CAP);if(push(q,in,257)!=0||atomic_load(&q->drops)!=257){free(full);free(q);return 5;}free(full);free(q);
    VBEngine *e=vb_create();if(!e)return 6;
    float signal[4096],left[480],right[480];for(int i=0;i<4096;i++)signal[i]=0.25f;
    struct {UInt32 count; AudioBuffer buffers[2];} buffers={2,{{1,sizeof(left),left},{1,sizeof(right),right}}};
    AudioUnitRenderActionFlags flags=0;AudioTimeStamp time={0};
    output(e,&flags,&time,0,480,(AudioBufferList*)&buffers);
    if(left[0]!=0 || atomic_load(&e->output_frames)!=0){vb_destroy(e);return 7;}
    push(&e->queue,signal,4096);
    output(e,&flags,&time,0,480,(AudioBufferList*)&buffers);
    for(int i=0;i<480;i++)if(fabs(left[i]-0.25f)>0.00001 || left[i]!=right[i]){vb_destroy(e);return 8;}
    for(int i=0;i<1000;i++){push(&e->queue,signal,480);output(e,&flags,&time,0,480,(AudioBufferList*)&buffers);}
    if(atomic_load(&e->underruns) || atomic_load(&e->queue.drops)){vb_destroy(e);return 9;}
    for(int i=0;i<100;i++)output(e,&flags,&time,0,480,(AudioBufferList*)&buffers);
    if(!atomic_load(&e->underruns)){vb_destroy(e);return 10;}
    push(&e->queue,signal,4096);output(e,&flags,&time,0,480,(AudioBufferList*)&buffers);
    if(left[0]!=0.25f){vb_destroy(e);return 11;}
    vb_destroy(e);
    // Cover small direct-HAL blocks as well as the original 4096-frame bursts,
    // with varying capture/output phase. Priming must avoid recurring gaps.
    const uint32_t sizes[]={480,512,1024,4096};
    for(uint32_t reserve=480;reserve<=1440;reserve+=480)for(uint32_t size=0;size<4;size++)for(uint32_t phase=0;phase<sizes[size];phase+=sizes[size]/8){
        uint32_t block=sizes[size];
        e=vb_create();if(!e)return 12;atomic_store(&e->input_block_frames,block);
        if(!vb_output_reserve(e,reserve)){vb_destroy(e);return 14;}
        uint64_t produced=0;
        for(uint32_t tick=0;tick<2000;tick++){
            uint64_t due=((uint64_t)tick*480+phase)/block+1;
            while(produced<due){push(&e->queue,signal,block);produced++;}
            output(e,&flags,&time,0,480,(AudioBufferList*)&buffers);
        }
        if(atomic_load(&e->underruns)||atomic_load(&e->queue.drops)||!atomic_load(&e->output_frames)){vb_destroy(e);return 13;}
        vb_destroy(e);
    }
    return 0;
}

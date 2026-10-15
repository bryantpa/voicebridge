#include "Echo.h"
#include <speex/speex_echo.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>
#include <mach/mach_time.h>
#define EFRAME 480u
#define REFCAP 262144u
// Timestamped reference samples are resampled onto the microphone's host-time
// timeline. This avoids assuming that USB input and built-in output clocks match.
struct VBEcho {
    SpeexEchoState *state;
    struct {uint64_t time;float value;} reference[REFCAP];
    _Atomic uint64_t r,w,drops,callbacks,reference_frames,last_reference,missing,processed,frames,skipped;
    _Atomic double reference_rms,pre_rms,post_rms;
    _Atomic uint64_t last_reference_sample,last_mic_sample;
    _Atomic int32_t error;
    double ticks_per_sample,tick_ms;
    spx_int16_t near[EFRAME],pending_near[EFRAME],far[EFRAME],out[EFRAME];
    uint64_t times[EFRAME],pending_times[EFRAME];
    bool have_pending;
    float delayed[EFRAME];
    uint32_t pos,valid;
    bool reset_needed;
};
static double edb(double v){return v>0?fmax(-120,20*log10(v)):-120;}
VBEcho *vb_echo_create(void){
    VBEcho *e=calloc(1,sizeof(*e));if(!e)return NULL;
    mach_timebase_info_data_t tb;mach_timebase_info(&tb);
    e->tick_ms=(double)tb.numer/tb.denom/1e6;e->ticks_per_sample=1.0/(48*e->tick_ms);
    e->state=speex_echo_state_init(EFRAME,9600);if(!e->state){free(e);return NULL;}
    int rate=48000;speex_echo_ctl(e->state,SPEEX_ECHO_SET_SAMPLING_RATE,&rate);return e;
}
void vb_echo_destroy(VBEcho *e){if(e){speex_echo_state_destroy(e->state);free(e);}}
void vb_echo_reference_error(VBEcho *e,int32_t code){atomic_store(&e->error,code);}
void vb_echo_reference(VBEcho *e,const float *input,uint32_t n,uint64_t host){
    uint64_t w=atomic_load_explicit(&e->w,memory_order_relaxed),r=atomic_load_explicit(&e->r,memory_order_acquire);
    uint32_t count=(uint32_t)fmin(n,REFCAP-(w-r));double power=0;
    for(uint32_t i=0;i<count;i++){
        float x=isfinite(input[i])?input[i]:0;power+=(double)x*x;
        e->reference[(w+i)&(REFCAP-1)].time=host+(uint64_t)(i*e->ticks_per_sample);
        e->reference[(w+i)&(REFCAP-1)].value=x;
    }
    if(count)atomic_store(&e->last_reference_sample,host+(uint64_t)((count-1)*e->ticks_per_sample));
    atomic_store_explicit(&e->w,w+count,memory_order_release);
    atomic_fetch_add(&e->drops,n-count);atomic_fetch_add(&e->reference_frames,count);atomic_fetch_add(&e->callbacks,1);
    atomic_store(&e->reference_rms,count?sqrt(power/count):0);atomic_store(&e->last_reference,mach_absolute_time());
}
static float reference_at(VBEcho *e,uint64_t time,bool *valid){
    uint64_t r=atomic_load_explicit(&e->r,memory_order_relaxed),w=atomic_load_explicit(&e->w,memory_order_acquire);
    while(r+1<w && e->reference[(r+1)&(REFCAP-1)].time<=time)r++;
    atomic_store_explicit(&e->r,r,memory_order_release);
    *valid=false;if(r+1>=w)return 0;
    uint64_t a=e->reference[r&(REFCAP-1)].time,b=e->reference[(r+1)&(REFCAP-1)].time;
    // Gaps, stale samples, and timestamps outside the captured range bypass AEC.
    if(time<a||b<=a||b-a>e->ticks_per_sample*4)return 0;
    double f=(double)(time-a)/(b-a);*valid=true;
    return e->reference[r&(REFCAP-1)].value*(1-f)+e->reference[(r+1)&(REFCAP-1)].value*f;
}
static spx_int16_t pcm(float x){return (spx_int16_t)lrintf(fmaxf(-32768,fminf(32767,(isfinite(x)?x:0)*32768)));}
void vb_echo_process(VBEcho *e,const float *input,float *output,uint32_t n,uint64_t host){
    if(n)atomic_store(&e->last_mic_sample,host+(uint64_t)((n-1)*e->ticks_per_sample));
    uint64_t missing=0;double before=0,after=0;
    for(uint32_t i=0;i<n;i++){
        float x=isfinite(input[i])?input[i]:0;
        e->near[e->pos]=pcm(x);e->times[e->pos]=host+(uint64_t)(i*e->ticks_per_sample);
        output[i]=e->delayed[e->pos];before+=(double)x*x;after+=(double)output[i]*output[i];
        if(++e->pos==EFRAME){
            // Join the preceding microphone frame with the speaker reference.
            // Waiting one frame lets trailing tap samples arrive; timestamps,
            // not a guessed acoustic delay, still determine the reference used.
            if(e->have_pending){
                uint32_t valid_count=0;
                for(uint32_t j=0;j<EFRAME;j++){bool valid;float ref=reference_at(e,e->pending_times[j],&valid);e->far[j]=pcm(ref);valid_count+=valid;missing+=!valid;}
                if(valid_count==EFRAME){
                    if(e->reset_needed){speex_echo_state_reset(e->state);e->reset_needed=false;}
                    speex_echo_cancellation(e->state,e->pending_near,e->far,e->out);atomic_fetch_add(&e->frames,1);
                    for(uint32_t j=0;j<EFRAME;j++)e->delayed[j]=e->out[j]/32768.0f;
                }else{
                    for(uint32_t j=0;j<EFRAME;j++)e->delayed[j]=e->pending_near[j]/32768.0f;
                    atomic_fetch_add(&e->skipped,1);e->reset_needed=true;
                }
            }
            for(uint32_t j=0;j<EFRAME;j++){e->pending_near[j]=e->near[j];e->pending_times[j]=e->times[j];}
            e->have_pending=true;e->pos=0;
        }
    }
    atomic_fetch_add(&e->missing,missing);atomic_fetch_add(&e->processed,n);
    atomic_store(&e->pre_rms,n?sqrt(before/n):0);atomic_store(&e->post_rms,n?sqrt(after/n):0);
}
VBEchoStats vb_echo_stats(VBEcho *e){
    VBEchoStats s={0};if(!e)return s;
    s.reference_frames=atomic_load(&e->reference_frames);s.reference_callbacks=atomic_load(&e->callbacks);s.reference_drops=atomic_load(&e->drops);
    s.missing_samples=atomic_load(&e->missing);s.processed_samples=atomic_load(&e->processed);s.echo_frames=atomic_load(&e->frames);s.skipped_frames=atomic_load(&e->skipped);
    s.reference_db=edb(atomic_load(&e->reference_rms));s.pre_echo_db=edb(atomic_load(&e->pre_rms));s.post_echo_db=edb(atomic_load(&e->post_rms));
    uint64_t last=atomic_load(&e->last_reference),now=mach_absolute_time();s.reference_age_ms=last && now>=last?(now-last)*e->tick_ms:-1;
    uint64_t ref=atomic_load(&e->last_reference_sample),mic=atomic_load(&e->last_mic_sample);s.reference_lead_ms=((double)ref-(double)mic)*e->tick_ms;
    s.reference_error=atomic_load(&e->error);return s;
}
int vb_echo_selftest(void){
    VBEcho *e=vb_echo_create();if(!e)return 1;
    float ref[960],near[480],out[480];uint32_t seed=7;double inputPower=0,outputPower=0;
    uint64_t host=1000000000;
    // Known linear echo with 10 ms delay. The real room must be tested separately.
    float previous[480]={0},late[120]={0};
    for(uint32_t frame=0;frame<900;frame++){
        for(uint32_t i=0;i<480;i++){seed=seed*1664525u+1013904223u;ref[i]=((int32_t)(seed>>8)-8388608)/8388608.0f*0.1f;near[i]=previous[i]*0.5f;previous[i]=ref[i];}
        uint64_t t=host+(uint64_t)(frame*480*e->ticks_per_sample);
        // Deliberately withhold 2.5 ms of each reference block until the next call.
        if(frame)vb_echo_reference(e,late,120,t-(uint64_t)(120*e->ticks_per_sample));
        vb_echo_reference(e,ref,360,t);for(int j=0;j<120;j++)late[j]=ref[360+j];
        vb_echo_process(e,near,out,480,t);
        if(frame>700)for(int i=0;i<480;i++){if(!isfinite(out[i])){vb_echo_destroy(e);return 2;}inputPower+=near[i]*near[i];outputPower+=out[i]*out[i];}
    }
    if(atomic_load(&e->missing)||outputPower>inputPower*0.1){vb_echo_destroy(e);return 3;}
    // Missing reference must pass microphone audio after the adapter's fixed delay.
    for(int i=0;i<480;i++)near[i]=0.125f;
    uint64_t t=host+(uint64_t)(2000*480*e->ticks_per_sample);
    vb_echo_process(e,near,out,480,t);vb_echo_process(e,near,out,480,t+(uint64_t)(480*e->ticks_per_sample));vb_echo_process(e,near,out,480,t+(uint64_t)(960*e->ticks_per_sample));
    for(int i=0;i<480;i++)if(fabsf(out[i]-0.125f)>0.0001f){vb_echo_destroy(e);return 4;}
    vb_echo_destroy(e);return 0;
}

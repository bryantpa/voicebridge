#include "Noise.h"
#include "rnnoise.h"
#include <stdlib.h>
#include <math.h>
struct VBNoise { DenoiseState *state; float in[480],out[480],probability; uint32_t pos; };
VBNoise *vb_noise_create(void) {
    if(rnnoise_get_frame_size()!=480)return NULL;
    VBNoise *p=calloc(1,sizeof(*p));if(!p)return NULL;
    p->state=rnnoise_create(NULL);if(!p->state){free(p);return NULL;}return p;
}
void vb_noise_destroy(VBNoise *p){if(p){rnnoise_destroy(p->state);free(p);}}
void vb_noise_process(VBNoise *p,const float *in,float *out,uint32_t n){
    for(uint32_t i=0;i<n;i++){
        float x=isfinite(in[i])?in[i]:0;
        p->in[p->pos]=x*32768.0f;
        out[i]=p->out[p->pos]/32768.0f;
        if(++p->pos==480){p->probability=rnnoise_process_frame(p->state,p->out,p->in);p->pos=0;}
    }
}
float vb_noise_probability(VBNoise *p){return p?p->probability:0;}
int vb_noise_selftest(void){
    const uint32_t n=12000;
    float *input=calloc(n,sizeof(float)),*a=calloc(n,sizeof(float)),*b=calloc(n,sizeof(float));
    VBNoise *p=vb_noise_create(),*q=vb_noise_create();int result=0;
    if(!input||!a||!b||!p||!q){result=1;goto done;}
    for(uint32_t i=0;i<n;i++)input[i]=0.1f*sinf(i*0.075f)+(i%1009==0?0.3f:0);
    vb_noise_process(p,input,a,n);
    // Chunk boundaries must not alter results. Includes in-place processing.
    for(uint32_t i=0;i<n;i++)b[i]=input[i];
    for(uint32_t i=0;i<n;){uint32_t count=(i%997)+1;if(count>n-i)count=n-i;vb_noise_process(q,b+i,b+i,count);i+=count;}
    for(uint32_t i=0;i<n;i++)if(!isfinite(a[i])||fabsf(a[i]-b[i])>1e-6f){result=2;goto done;}
    if(vb_noise_probability(p)<0||vb_noise_probability(p)>1){result=3;goto done;}
    for(uint32_t i=0;i<480;i++)if(a[i]!=0){result=4;goto done;}
done:
    free(input);free(a);free(b);vb_noise_destroy(p);vb_noise_destroy(q);return result;
}

#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include "Echo.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
struct VBSpeakerTap { AudioObjectID tap,aggregate; AudioDeviceIOProcID proc; VBEcho *echo; AudioStreamBasicDescription format; float mono[8192]; };
static OSStatus tap_io(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,const AudioTimeStamp *inputTime,AudioBufferList *output,const AudioTimeStamp *outputTime,void *context){
    VBSpeakerTap *t=context;
    if(output)for(UInt32 i=0;i<output->mNumberBuffers;i++)if(output->mBuffers[i].mData)memset(output->mBuffers[i].mData,0,output->mBuffers[i].mDataByteSize);
    if(!input || !input->mNumberBuffers || !(inputTime->mFlags&kAudioTimeStampHostTimeValid)){vb_echo_reference_error(t->echo,-7001);return noErr;}
    UInt32 channels=0,frames=UINT32_MAX;
    for(UInt32 b=0;b<input->mNumberBuffers;b++){
        UInt32 c=input->mBuffers[b].mNumberChannels;if(!c)continue;
        UInt32 count=input->mBuffers[b].mDataByteSize/(4*c);if(count<frames)frames=count;channels+=c;
    }
    if(!channels||frames>8192){vb_echo_reference_error(t->echo,-7002);return noErr;}
    memset(t->mono,0,frames*sizeof(float));
    for(UInt32 b=0;b<input->mNumberBuffers;b++){
        UInt32 c=input->mBuffers[b].mNumberChannels;const float *p=input->mBuffers[b].mData;if(!p)continue;
        for(UInt32 i=0;i<frames;i++)for(UInt32 j=0;j<c;j++)t->mono[i]+=p[i*c+j]/channels;
    }
    vb_echo_reference(t->echo,t->mono,frames,inputTime->mHostTime);return noErr;
}
void vb_tap_stop(VBSpeakerTap *t){
    if(!t)return;
    if(t->aggregate&&t->proc){AudioDeviceStop(t->aggregate,t->proc);AudioDeviceDestroyIOProcID(t->aggregate,t->proc);}
    if(t->aggregate)AudioHardwareDestroyAggregateDevice(t->aggregate);
    if(t->tap)AudioHardwareDestroyProcessTap(t->tap);
    free(t);
}
VBSpeakerTap *vb_tap_start(VBEcho *echo,uint32_t speaker,char *error,uint32_t size){
    if(@available(macOS 14.2,*)){@autoreleasepool{
        VBSpeakerTap *t=calloc(1,sizeof(*t));if(!t)return NULL;t->echo=echo;OSStatus s=0;const char *stage="Read speaker UID";CATapDescription *desc=nil;NSDictionary *description=nil;
        AudioObjectPropertyAddress a={kAudioDevicePropertyDeviceUID,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        CFStringRef uid=NULL;UInt32 bytes=sizeof(uid);s=AudioObjectGetPropertyData(speaker,&a,0,NULL,&bytes,&uid);if(s)goto fail;
        pid_t pid=getpid();AudioObjectID process=0;a.mSelector=kAudioHardwarePropertyTranslatePIDToProcessObject;bytes=sizeof(process);
        s=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(pid),&pid,&bytes,&process);
        if(s||!process){if(!s)s=-7004;CFRelease(uid);stage="Identify VoiceBridge for reference exclusion";goto fail;}
        desc=[[CATapDescription alloc] initExcludingProcesses:@[@(process)] andDeviceUID:(__bridge NSString*)uid withStream:0];CFRelease(uid);
        desc.name=@"VoiceBridge speaker reference";desc.private=YES;desc.muteBehavior=CATapUnmuted;desc.UUID=[NSUUID UUID];
        stage="Create speaker tap (allow macOS system-audio access)";s=AudioHardwareCreateProcessTap(desc,&t->tap);
        if(s){goto fail;}
        a.mSelector=kAudioTapPropertyFormat;bytes=sizeof(t->format);s=AudioObjectGetPropertyData(t->tap,&a,0,NULL,&bytes,&t->format);
        if(s){stage="Read speaker-tap format";goto fail;}
        if(t->format.mSampleRate!=48000 || t->format.mFormatID!=kAudioFormatLinearPCM || !(t->format.mFormatFlags&kAudioFormatFlagIsFloat) || t->format.mBitsPerChannel!=32 || (t->format.mFormatFlags&kAudioFormatFlagIsBigEndian)){
            s=-7003;stage="Speaker tap needs 48 kHz Float32 audio for this prototype";goto fail;
        }
        description=@{
            @kAudioAggregateDeviceNameKey:@"VoiceBridge private speaker tap",
            @kAudioAggregateDeviceUIDKey:[[NSUUID UUID] UUIDString],
            @kAudioAggregateDeviceIsPrivateKey:@YES,
            @kAudioAggregateDeviceIsStackedKey:@NO,
            @kAudioAggregateDeviceTapAutoStartKey:@YES,
            @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:desc.UUID.UUIDString,@kAudioSubTapDriftCompensationKey:@YES}]
        };
        stage="Create private speaker-tap device";s=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description,&t->aggregate);if(s)goto fail;
        stage="Install speaker-tap callback";s=AudioDeviceCreateIOProcID(t->aggregate,tap_io,t,&t->proc);if(s)goto fail;
        stage="Start speaker-reference capture";s=AudioDeviceStart(t->aggregate,t->proc);if(s)goto fail;
        return t;
    fail:
        snprintf(error,size,"%s (OSStatus %d)",stage,(int)s);vb_tap_stop(t);return NULL;
    }}
    snprintf(error,size,"Speaker-reference capture requires macOS 14.2 or later");return NULL;
}

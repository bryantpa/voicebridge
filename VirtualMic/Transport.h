#pragma once
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

// Timestamp-addressed stereo loopback. One mixed-output writer, any number
// of independent readers. Tags prevent replay of old audio after wrap or stop.
// Every shared field is atomic; callbacks never allocate, block, or retry.
#define VM_CAPACITY 32768u
#define VM_DELAY 512u
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Lock-free 64-bit atomics required");
typedef struct { _Atomic(uint64_t) tag, stereo; } VMSlot;
typedef struct {
    VMSlot slots[VM_CAPACITY];
    _Atomic(uint64_t) written, read, missing;
} VMTransport;
static void vm_reset(VMTransport *t) {
    // Only while all device IO is stopped.
    for (unsigned i=0;i<VM_CAPACITY;i++) {
        atomic_store(&t->slots[i].tag, UINT64_MAX);
        atomic_store(&t->slots[i].stereo, 0);
    }
    atomic_store(&t->written,0); atomic_store(&t->read,0); atomic_store(&t->missing,0);
}
static void vm_write(VMTransport *t, int64_t start, unsigned n, const float *p) {
    for(unsigned i=0;i<n;i++) {
        int64_t frame=start+i;
        if(frame<0) continue;
        VMSlot *s=&t->slots[(uint64_t)frame%VM_CAPACITY];
        float v[2]={isfinite(p[2*i])?p[2*i]:0,isfinite(p[2*i+1])?p[2*i+1]:0};
        uint64_t bits;memcpy(&bits,v,sizeof bits);
        // Sequential consistency makes the tag / payload / tag read coherent
        // even when the writer wraps while a reader is accessing that slot.
        atomic_store(&s->tag,UINT64_MAX);
        atomic_store(&s->stereo,bits);
        atomic_store(&s->tag,(uint64_t)frame);
    }
    atomic_fetch_add(&t->written,n);
}
static void vm_read(VMTransport *t, int64_t start, unsigned n, float *p) {
    uint64_t missing=0;
    for(unsigned i=0;i<n;i++) {
        int64_t frame=start+i-VM_DELAY;
        uint64_t bits=0;
        if(frame>=0) {
            VMSlot *s=&t->slots[(uint64_t)frame%VM_CAPACITY];
            uint64_t before=atomic_load(&s->tag);
            uint64_t value=atomic_load(&s->stereo);
            uint64_t after=atomic_load(&s->tag);
            if(before==(uint64_t)frame && after==before) bits=value;
            else missing++;
        } else missing++;
        memcpy(p+2*i,&bits,sizeof bits);
    }
    atomic_fetch_add(&t->read,n);atomic_fetch_add(&t->missing,missing);
}

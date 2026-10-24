# Claude review: input-only microphone proposal

Date: 2026-10-16. Reviewer: Claude CLI, configured Opus/high; a same-configuration model check resolved `claude-opus-5-5`. The supplementary transport review explicitly selected that model. No review tools were enabled and no files were modified by Claude.

Scope: design note, complete `VirtualMic/Driver.c`, its diff against commit `9a4dc6a`, `VirtualMic/test.c`, and `Sources/VoiceBridge/Devices.swift`. A separate review supplied the previously omitted `VirtualMic/Transport.h` and driver IO routines. These are model-generated findings, not an authoritative statement of Apple's contracts or completed runtime validation. See the [design decision and triage](../input-only-microphone.md#review-outcome).

## Main review (verbatim)

## Verdict

**The bounded experiment is justified, but the prototype is not ready to install.** I found no definite coreaudiod crash in the `Driver.c` diff. Three things block installation:

- The test suite is stale.
- The current app cannot use the new topology.
- The split adds cross-thread ring concurrency that I can't review, because `Transport.h` wasn't provided.

A cheaper test can also run against the current install first, and it may settle whether this topology can help at all.

## Findings

### Blockers (introduced)

1. **New concurrency in the ring is unreviewed.** As I understand the HAL, each device runs its own IO thread. In the duplex device, `ReadInput` and `WriteMix` ran one after the other on the same thread. After the split, `vm_write` (feed thread) and `vm_read` (mic thread) run truly concurrently. Both RT threads also now contend on `gDevice_IOMutex` in `VoiceBridgeMic_GetZeroTimeStamp`.
   - The writer/reader thread test in `test.c` is encouraging, but it only uses 1-frame writes.
   - It needs ThreadSanitizer, not only ASan/UBSan, plus multi-frame writes that wrap and overlap reads.
   - `vm_reset` in `VoiceBridgeMic_StartIO` runs under the state mutex only. It is safe only if the HAL never runs either device's IO while the shared count is 0. Document that invariant and assert it.

2. **`VirtualMic/test.c` will fail against this driver.**
   - It calls `WriteMix` on `kObjectID_Device`/`kObjectID_Stream_Output`, which `VoiceBridgeMic_DoIOOperation` now rejects with `kAudioHardwareUnsupportedOperationError`.
   - It expects the mic to own 2 objects; it now owns 1.
   - It never exercises the feed.
   - The driver calls are made inside `assert()`, so an `NDEBUG` build silently skips them while still printing "PASS".

3. **The current app has no destination under the new driver.** In `Sources/VoiceBridge/Devices.swift`, `processedDestination` requires `outputs == 2` on the mic UID, and the mic now has 0 outputs. The feed is hidden, and as I recall the header docs, hidden devices are left out of `kAudioHardwarePropertyDevices`. If so, `Devices.all()` never sees the feed (verify on the target OS).
   - Installing the driver alone would break the working setup.
   - Ship the driver with an app that resolves the feed via `kAudioHardwarePropertyTranslateUIDToDevice` and detects the topology by channel counts, not by name.

### Should fix (introduced; property contract and experiment hygiene)

4. **Directional properties are advertised on scopes the device doesn't have.** `VoiceBridgeMic_HasDeviceProperty` returns true on both input and output scope, for both devices, for:
   - Latency
   - SafetyOffset
   - PreferredChannelsForStereo
   - PreferredChannelLayout
   - CanBeDefaultDevice

   The legacy path then returns a stereo layout for the mic's output scope. Gate these with `vm_scope`.

5. **The public mic changed in more ways than "lose its output".**
   - The fast path in `VoiceBridgeMic_GetDevicePropertyData` changes ClockDomain from 0 to `'VBMC'` for both devices.
   - The two devices also share a ModelUID (legacy path) and a box, and the feed's stream reports TerminalType `Speaker`.

   These add variables, and they are plausible pairing hints for VPIO. For the first run, keep the mic identical to today apart from its streams: ClockDomain 0, a distinct feed ModelUID, and arguably a non-speaker terminal type. Returning only the device itself for RelatedDevices is the right call; keep the two devices unrelated.

6. **The sample-rate paths are latent hazards.** They can't be reached while 48 kHz is the only rate, but:
   - `SetDevicePropertyData` and `SetStreamPropertyData` always request the change on `kObjectID_Device`, even when called for the feed.
   - `PerformDeviceConfigurationChange` changes shared timing state. The HAL only stops IO on the device being changed, so the other device's IO may still be running.

   Make the rate and format non-settable, or handle both devices together.

7. **`vbst` counters are global and can mislead.** `missingFrames` grows whenever the mic reads while the feed is idle, so starvation can't be told apart from "app not running". Count reads made while the writer is running separately, or report per device.

8. **Minor:** the `kAudioBoxPropertyDeviceList` data path in `GetBoxPropertyData` dropped the state lock, while the size path still takes it.

Looks correct as far as I can tell:
- Plug-in, box and device lists, and their sizes
- UID translation
- Stream owners and directions
- WillDo/DoIO gating per device
- Per-device IsRunning
- Shared timeline: the first start resets and bumps the seed, and a later join keeps the clock

### Pre-existing (not introduced; fix while redeploying into coreaudiod)

- `kAudioBoxPropertyBoxUID` never sets `*outDataSize`.
- `VoiceBridgeMic_Initialize` reads the box name from the `"box acquired"` key.
- Control objects 5–12 are orphans: they report Owner = Device, but no object owns them.
- The sample `'PCst'` custom property calls `CFShow` on client data, and `SetPlugInPropertyData` doesn't NULL-check `inData`. Remove it.
- The `ItemName` qualifier is dereferenced without a NULL check.
- The `ResourceBundle` size check uses `AudioObjectID`.
- `NominalSampleRate` is settable even though only one rate exists.

Hidden-feed access is not a regression. Any process could already write to the old, visible duplex output.

## Answers to the review questions

**Q1: Does the evidence justify the experiment?** Yes, for a bounded test. An attenuation of roughly 18–20 dB with a collapsed envelope fits linear AEC cancelling a perfectly correlated reference. That is my inference, and it says nothing about *which* output is the reference. Competing explanations to rule out:
- VPIO pairs with the default output, and the same speech reached it (monitoring, or the diagnostic's playback lead).
- VPIO noise suppression or AGC, or the macOS Mic Mode (e.g. Voice Isolation), is reacting to synthetic or already-processed speech.
- RNNoise gating interacts with VPIO's own processing; it's unclear whether the diagnostic bypassed VoiceBridge's DSP.

During reruns, record the Mic Mode and Firefox's cubeb/audio logs.

**Q2: Is a hidden output different enough from a duplex loopback?** It depends on how VPIO picks its reference:
- If it uses the input device's own output side, any split fixes it, and hiding the feed is just UI hygiene.
- If it uses something broader, such as same clock domain, same box, or system-wide output, a hidden feed may not help, and option 3 would be needed.
- If it pairs only with the default output, the topology is probably not the cause.

Don't jump to option 3 before testing this.

**Q3: Does the prototype keep the property and shared-clock contracts?** Mostly yes; the gaps are findings 4–6. The clock is shared correctly. Alignment of the two devices' HAL sample times when one joins late is untested (H3 below).

**Q4: What would make it unsafe to install?** Blockers 1–3.

**Q5: Is there a simpler approach?** None I'm confident in. Private app-to-driver IPC is the usual pattern for commercial virtual microphones. The driver runs sandboxed, so check the IPC entitlements, e.g. the `AudioServerPlugIn_MachServices` Info.plist key, before scoping option 3.

## Hypotheses that need hardware or browser testing

- **H1:** Which output device VPIO pairs with for a duplex input versus an input-only one.
- **H2:** AUHAL/AVAudioEngine accepts a hidden device as its output.
- **H3:** Sample times stay aligned across the two devices, including late joins, with no ±1-frame seams.
- **H4:** The feed doesn't appear in System Settings, browsers or call apps.
- **H5:** Whether the shared clock domain, box or ModelUID affects VPIO pairing.

## Smallest decisive plan

0. **No install, against the current driver.** Write a native VoiceProcessingIO harness with VoiceBridge Mic as input and generated speech fed in by the app. Measure the same envelope metric with the VPIO output set to (a) the speakers, kept silent, (b) VoiceBridge, and (c) processing bypassed. If VPIO builds an internal aggregate, as I believe it does, inspect which sub-devices it contains.
   - If VoiceBridge's output side is the reference, a split should help.
   - If the speakers are the reference and suppression persists anyway, stop: the topology is not the cause.
   - The harness is not Firefox, so confirm with Firefox's logs.

1. **One install, after fixing blockers 1–3.** Use a test build in which the mic can play a bundled speech clip loaded in `Initialize`, with the feed idle. With Firefox on its default backend, run 3–5 captures each of "internal clip" versus "app → hidden feed":

   | Internal clip | App → hidden feed | Conclusion |
   | --- | --- | --- |
   | Clean | Clean | Option 2 works |
   | Clean | Degraded | VPIO still uses the hidden output as a reference; option 3 is justified |
   | Degraded | — | Not a routing problem; neither option helps |

2. **Only after a clean result:** measure latency and missing frames, then test real dictation, calls and Safari. Keep the old installer and the Firefox pref change ready for rollback, and restart browsers after each install.


## Supplementary transport review (verbatim)

## Ring coherence under concurrent wrap

**Yes, per frame, assuming exactly one writer.** The stereo payload is a single 64-bit atomic, so L/R cannot tear. The seq_cst `MAX → payload → frame` / `tag → payload → tag` sequence is a valid seqlock:

- If the reader sees `before == frame`, the payload load is ordered after that frame's final tag store.
- If the payload came from a wrapping write (`frame+C`), that write's `tag=MAX` precedes it in the total order, so `after != frame` and the reader counts the frame as missing.
- A reader lagging by ≥C frames, or a gap after an overload, also counts as missing. It does not replay old audio.

**This breaks with two concurrent writers.** If two writers interleave on the same slot, one can publish its tag over the other's payload. The design needs one WriteMix caller at a time. The HAL normally runs one IO thread per device, so this holds in practice, but it is an assumption, not a documented guarantee.

## Defects

**New two-device risks**

1. **Reset races a straggling IO call.** `vm_reset` runs when `gDevice_IOIsRunning` reaches 0→1. Nothing proves the other device's in-flight `DoIOOperation` has returned. A late `vm_write` can restore `tag=frame` from the old session. Because sample time restarts at 0, the new session accepts it as valid, which is exactly the replay the tags are meant to prevent. Fix: put an epoch (`gClockSeed`) into the tag, or hold an IO-side quiescence counter before resetting.
2. **Capacity versus lead is unchecked.** `inIOBufferFrameSize > VM_CAPACITY` is too loose. The writer runs ahead of now by about `bufOut + safetyOut`. The reader needs frames back to about `now − bufIn − safetyIn − 512`. If that whole span reaches 32768, the writer overwrites slots the reader has not consumed yet, and every frame reads as silence. Clamp `kAudioDevicePropertyBufferFrameSizeRange` on both devices so the worst-case span is well under C.
3. **Device state that is still global.** Any property that reads `gDevice_IOIsRunning` must use the per-device count instead, or both devices report "running" when only one is. This includes `DeviceIsRunning` and any sample-rate or format change guard. The same applies to notifications. A sample-rate change mutates the shared `gDevice_HostTicksPerFrame`, so it must request a config change on both devices and be refused while either device is running.
4. **Format assumption.** `vm_write` and `vm_read` assume interleaved 2-channel Float32. If either stream allows another format (for example mono), `vm_write` reads past `ioMainBuffer`. Lock both streams to a single format.

**Existing (inherited from the NullAudio pattern)**

- `GetZeroTimeStamp` takes a pthread mutex on the realtime thread. This allows priority inversion against `StartIO`, which holds the state mutex and then the IO mutex. Every other path must take the two locks in the same order.
- `written` counts frames skipped because `frame < 0`. This is only a diagnostic inaccuracy.
- `DoIOOperation` uses `return` inconsistently with `goto Done`. Harmless.
- `gRunningByDevice` increments with no overflow check. This is moot in practice.

## HAL scheduling assumptions to qualify

- **No ordering between the two devices.** A shared clock means the same timeline (same seed, period, and anchor). It does not mean the IO threads run in lockstep. They wake independently, with their own buffer sizes and safety offsets. The 512-frame `VM_DELAY` is slack for writer jitter. Availability actually depends on the output lead.
- **Writer absent means silence.** When the hidden Feed device has no client, the public device returns zeros and `missing` grows without bound. Confirm that this behavior is intended.
- **StopIO may not imply quiescence.** That `StopIO` arrives only after the device's IO thread has stopped calling `DoIOOperation` is likely, but it is not guaranteed across devices. This is why item 1 matters.

## Validate before installing

1. Both devices report the same `ClockDomain` and the same `ZeroTimeStampPeriod`, and stream ownership is correct (`Stream_Output`→Feed, `Stream_Input`→Device).
2. The buffer-size range satisfies the span bound in item 2 at the largest settings, measured with real safety offsets.
3. Stress start/stop: start one device, start the other, stop the first, restart. Then check:
   - no stale audio after a full stop/start (add an epoch first);
   - the `missing` and `read` counters behave sensibly.
4. Overload and glitch: force IO overloads and confirm gaps produce silence, not replayed audio.
5. Sample-rate change attempted while one device is running is rejected or propagates to both devices.
6. Run under TSan in a userspace harness with two writer and reader threads. Also add a debug assert for single-writer entry (an atomic flag around `vm_write`).
7. Check `coreaudiod` logs for timestamp-seed churn or "device not responding" errors with both devices active.

Fix items 1 and 2 before shipping. The rest is hardening.

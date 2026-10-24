# Proposal: separate microphone input from its audio feed

Status: design review, 2026-10-16. The driver prototype compiles but is not installed. App integration and tests have not yet been updated. The working installation still uses the existing duplex device and Firefox workaround.

## Problem and evidence

VoiceBridge currently sends processed speech to the output of a virtual Core Audio device and exposes that same audio through the device's input. Firefox/ChatGPT dictation produced incomplete or empty transcripts with this route, while direct physical-microphone dictation worked.

Changing Firefox's `media.getusermedia.audio.processing.platform.enabled` preference from `true` to `false`, followed by restarting Firefox, restored dictation in the user's test. This selects a different audio-processing backend; it does not necessarily disable browser echo cancellation, noise suppression, or gain control.

A local diagnostic injected generated speech into the virtual device, captured Firefox's MediaRecorder output, and compared its energy envelope against the source. No user dictation audio was retained for this experiment.

| Capture configuration | Envelope similarity | Relative level |
| --- | ---: | ---: |
| Browser processing disabled, run 1 | 0.951 | -0.30 dB |
| Browser processing disabled, repeat | 0.992 | +0.02 dB |
| Firefox defaults, platform backend, run 1 | 0.206 | -19.56 dB |
| Firefox defaults, platform backend, repeat | 0.448 | -17.72 dB |
| Firefox defaults, software backend | 0.879 | +1.36 dB |

The metric is cosine similarity of 2 ms RMS energy bins, not waveform fidelity or a transcription score. The software-backend result has only one completed run. Timing offsets include an intentional playback lead and startup, so these results do not measure mouth-to-call latency. An attempted echo-only comparison caused Firefox to report all three processing features disabled; it cannot isolate echo cancellation as the cause.

The evidence implicates the browser's platform processing path. It does **not** prove precisely what Apple's VoiceProcessingIO implementation is doing internally. Our hypothesis is that it treats the virtual output containing local speech as an echo reference and suppresses matching virtual input.

A [BlackHole maintainer report](https://github.com/ExistentialAudio/BlackHole/discussions/874) describes a similar Safari/Firefox echo-cancellation failure and reports success with an input-only interface in another product. It does not establish that the hidden-output design below will work. Firefox's platform-processing integration is discussed in [Mozilla bug 1404972](https://bugzilla.mozilla.org/show_bug.cgi?id=1404972); the platform preference is defined in [Mozilla's default preferences](https://github.com/mozilla-firefox/firefox/blob/main/modules/libpref/init/all.js).

## Proposed experiment

Split the existing duplex driver into two Core Audio devices while retaining its timestamped ring buffer:

```text
Physical mic → VoiceBridge DSP → VoiceBridge Audio Feed (hidden output)
                                             ↓ shared timestamped ring
Calling app ← VoiceBridge Microphone (public input only)
```

| Property | Public microphone | Audio feed |
| --- | --- | --- |
| UID | Existing `VoiceBridgeMicDevice_UID` | New `VoiceBridgeFeedDevice_UID` |
| Channels | Two input, zero output | Zero input, two output |
| Default-device eligibility | Input only | None |
| Hidden | No | Yes |
| Purpose | Browser/call-app capture | App writes processed samples |

Both devices use the existing 48 kHz format, shared clock, and ring. The prototype retains the 512-frame transport delay; it makes no latency-improvement claim. Public naming and UID stay stable to reduce migration friction, though applications may cache stream topology and require reopening after installation.

Hidden means excluded from ordinary discovery/UI, **not access-controlled or private IPC**. Another Core Audio client may resolve the feed's UID. The decisive unknown is whether Apple's processing still uses that hidden output as a reference. We must test this with Firefox's platform backend restored to its default. If it still fails, this design has not solved the problem.

## App and lifecycle changes required

- Resolve the hidden feed explicitly by UID. Keep the public microphone as the destination shown to the user, but pass the actual feed device ID to the output engine.
- Distinguish the selected logical destination from the actual output device in diagnostics. A missing feed must produce an actionable error, not silently send nowhere.
- Support the old duplex driver during migration and rollback. Detect device capabilities rather than assuming a name or version proves installation succeeded.
- Update the delay checker to write to the feed and capture the public input.
- Keep one shared timebase while either device has active clients. Starting or stopping one side must not reset the other's sample timeline. Reset stale samples when both sides stop and a new session starts.
- Report per-device running state, correct stream owners, stream directions, UID translation, and default-device eligibility consistently.
- Keep routing experiments separate from changes to RNNoise and acoustic echo cancellation, so comparisons have one main variable.

## Alternatives

1. **Keep the Firefox workaround.** Already useful on this machine and lowest immediate risk. It is browser-specific and does not establish compatibility with Safari or other clients.
2. **Hidden output plus public input.** Smallest change to existing transport. Retains Core Audio scheduling, but success with Apple processing is an experimental question.
3. **Input-only driver with a non-audio feed.** Move samples from app to driver via an explicitly designed shared-memory/control transport. This avoids advertising a feed as any output device, but adds producer ownership, permissions, mapping lifetime, crash recovery, synchronization, and real-time-safety work. It is a fallback to design separately, not a small extension of this patch.

Recommendation before review: test option 2 as a bounded experiment. Do not replace the working installation merely because it compiles.

## Risks and validation gates

The driver runs in the system audio service. A property-contract, lifetime, or synchronization error can affect audio beyond VoiceBridge. Two independent device callback schedules may also require more timing reserve than the old duplex route. Shared clock-domain metadata alone does not prove callback alignment or eliminate underruns.

Before installation:

- Extend driver tests for both device lists, UID lookup, owners, stream directions, hidden/default flags, property sizes, and rejected invalid device/stream/operation combinations.
- Exercise writer-first and reader-first starts, multiple readers, each side stopping/restarting while the other runs, and a complete stop/restart. Verify clock continuity, bounded silence on missing samples, and no stale replay.
- Retain ring-wrap, concurrent access, invalid timestamp, and format checks under AddressSanitizer and UndefinedBehaviorSanitizer. Review real-time callbacks for unsafe blocking/allocation and races not covered by those sanitizers.
- Test app destination resolution for old/new drivers and a missing feed. Build the app and delay checker and run the repository checks in [testing.md](testing.md).

After a reviewed build is ready:

1. Preserve a known-working app and driver installer. Install outside calls; administrator authorization and an audio-service restart are required.
2. Verify public input visibility and hidden-feed discovery using real Core Audio APIs. Confirm no unexpected feed appears in normal speaker pickers.
3. Run repeated native routing and lifecycle tests. Check actual latency and driver missing-frame counters rather than assuming the old values still apply.
4. Repeat generated-speech browser captures with the platform backend enabled and disabled, restarting Firefox between configurations. Retain configuration and summary metrics; do not mistake envelope similarity for speech quality.
5. Verify real dictation and ordinary calls, and separately check keyboard reduction, local voice preservation, and speaker echo. Test Safari if available. Keep call-app echo cancellation until the acoustic setup is validated.

Success requires reliable capture with the browser's default backend, acceptable measured latency, no sustained missing frames, and successful normal dictation. If the new topology fails, restore the working driver/app and Firefox workaround. Stop short of a larger transport rewrite until its scope is reviewed.

## Questions for independent review

1. Does the evidence justify this experiment, and what competing explanations should we test?
2. Is a hidden output sufficiently different from a duplex loopback for this hypothesis, or should we go directly to non-audio transport?
3. Does the prototype maintain the Core Audio property and shared-clock contracts across two devices?
4. Which failures would make this unsafe to install, and what is the smallest decisive test plan?
5. Are there simpler approaches that preserve a system-wide processed microphone without app-specific preferences?

## Review outcome

Claude Opus 5.5 reviewed the proposal and prototype, with a separate transport review. The [full review](reviews/2026-10-16-claude-input-only.md) is saved for another reviewer. Its verdict: the bounded experiment is justified, but the prototype is not ready to install.

Triage after reading the findings against the source:

- **Confirmed unfinished integration:** the app still requires an output on the public microphone, and driver tests still write to that old output. Both need updating before this driver can be used. The existing test script does not define `NDEBUG`; the review's assertion concern is future test hardening, not evidence that today's tests skip execution.
- **Confirmed prototype cleanup:** preferred stereo/layout properties still describe both directions; the box device-list read dropped its existing state lock; configuration-change requests still target only the public device. Audit these paths before installing. Only 48 kHz and the fixed stereo float format are currently accepted, so arbitrary format changes are not a demonstrated failure.
- **Concurrency needs stronger validation:** the supplementary review found the ring's atomic tag/payload scheme coherent with a single writer. Test multi-frame concurrent wrap, independent device starts/stops, and timestamp alignment. A reset racing a late IO callback is a conditional concern: establish HAL's quiescence contract or add appropriate protection. Do not label an unobserved race as a reproduced bug. ASan/UBSan do not establish race freedom; add a focused ThreadSanitizer harness where supported.
- **Do not adopt speculative metadata changes blindly:** Claude suggested changing clock-domain/model metadata to test pairing. A shared clock domain should accurately describe the clock; there is no evidence yet that the domain value causes the browser failure. Use controlled comparisons and truthful properties. A hidden feed is still not private IPC.
- **Diagnostics should separate idle from failure:** expose whether the feed is running alongside shared missing-frame counters. Expected silence when VoiceBridge is stopped should be distinguishable from starvation during processing.
- **Additional inherited sample-code issues:** the review identifies property-size, qualifier validation, and unused example-control paths. These need source verification and focused tests as driver hardening, not a claim that they caused the dictation issue.

The review proposed a native VoiceProcessingIO test against the existing driver before another installation. This is a useful next experiment: inject generated speech directly (bypassing VoiceBridge DSP), control the output reference and processing bypass, and compare capture levels. Keep physical playback silent, record macOS Mic Mode and browser settings, and restore the live route afterward. This can narrow the explanation but cannot prove how Firefox configures its audio unit.

A possible later comparison is an input generated within a test driver versus the same signal arriving through the hidden feed. This adds test-only code to the system audio service and is not required for the first experiment. Its results would be evidence, not the categorical proof suggested by the review's outcome table: damaged internal playback could also reflect a faulty test or other processing.

Decision: keep the working installation and Firefox workaround. First investigate with the native harness, then finish and validate the two-device experiment if the evidence still supports it. Do not expand into shared-memory IPC yet. No prototype installation, browser setting change, or public push was performed as part of this review.


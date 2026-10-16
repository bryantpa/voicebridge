# Testing and measurement

## Checks that do not touch the live audio route

From the repository root:

```sh
bash test.sh
bash VirtualMic/test.sh
bash build.sh
bash LatencyCheck/build.sh
```

The audio-core and driver tests use AddressSanitizer and UndefinedBehaviorSanitizer. The main test script also checks diagnostic log rotation and retention against temporary folders, including preservation of explicit reports and recordings. The helper's build runs synthetic known-delay, zero-delay, silence, and missing-capture correlation checks. A successful build does not install the driver or launch either app.

## Live microphone comparison

The current helper is specific to an **XCM-50 at 48 kHz** and either VoiceBridge Microphone or the original UNIFY route. Processing tests also look for **Mac mini Speakers**. These assumptions are in `LatencyCheck/Main.swift`; the helper is not a universal device benchmark yet.

Leave VoiceBridge processing and sending, open `LatencyCheck/VoiceBridge Delay Check.app`, and click **Measure 10 Seconds**. Speak a few phrases with short pauses and keep the speakers quiet. The helper compares raw physical input with virtual input on their timestamp timelines. It writes timing results, not audio.

## Automatic routing loop

1. Finish calls and stop VoiceBridge processing. The helper does not stop or restart it for you.
2. Open `LatencyCheck/VoiceBridge Delay Check.app` and allow input access if asked.
3. Click **Run Automatic Test Loop**. The checked-in `TestPlan.json` runs three routing-only tests, about ten seconds each, without speaking or a voice fixture.
4. Quit the helper and press **Start** in VoiceBridge to restore the processed microphone.

The generated internal signal is written into the virtual microphone. Do not run the loop while a call or voice-typing app is listening to that device.

The helper reads `TestPlan.json` beside its app bundle. Changing the plan does not require a rebuild. `route` accepts `voicebridge` or `unify`; test modes are `route`, `bypass`, and `processed`, with `reserveMS` from 10 to 60. Up to 20 tests may be specified. For UNIFY comparisons, its Chat mix must contain only the Virtual channel.

## Full processing loop with a private fixture

Use your own **mono 48 kHz CAF** speech clip with a voiced opening. The helper repeats up to its first three seconds at several gains to keep correlation windows usable after noise suppression. It uses the same AudioCore implementation as the app and replaces live input samples with the fixture for these tests.

```sh
VB_TEST_FIXTURE="/absolute/path/to/your-private-speech.caf" bash LatencyCheck/build.sh
cp LatencyCheck/ProcessingPlan.example.json LatencyCheck/TestPlan.json
```

The clip is copied into the local helper's app bundle. **Do not distribute that bundle with private speech inside it.** Rebuilding without `VB_TEST_FIXTURE` removes the bundled fixture. No fixture is included in Git; routing-only tests do not need one. Restore the checked-in routing plan with `git restore LatencyCheck/TestPlan.json` when finished.

Stop VoiceBridge, run the loop, then restart VoiceBridge. Allow system-audio capture if requested. Keep the selected physical speaker output active so its Core Audio tap has a reference clock. An idle output can stop delivering reference samples. This timing test does not need audible speaker content, but it also does not prove acoustic echo suppression.

## Interpret the evidence

Reports are saved under `~/Library/Application Support/VoiceBridge/LatencyReports`.

- `accepted` means the timing match passed correlation/consistency checks and, for injected processing tests, engine underrun/drop/render checks. It does not mean the audio sounds good.
- `echoReferenceHealthy` separately checks that the processing test received reference frames without reported reference errors or missing samples. It is not an acoustic echo-quality score.
- Driver counters can include startup missing frames. Inspect them rather than assuming a clean engine means every driver frame was present.
- Queue depth, callback age, and DSP duration are different quantities. None alone equals total microphone delay.
- Compare repeated runs. Timestamp assumptions, hardware buffering, clock drift, and the signal itself affect the estimate.
- The 2 ms envelope bins establish analysis resolution, not calibrated accuracy.

The README's early measurements were taken before publication on the same development setup. Successful active-speaker full-processing runs had zero engine underruns, dropped frames, render errors, and missing echo-reference samples. Driver missing-frame counts were 896 per run, consistent with startup. Raw development reports and speech clips are intentionally not published because they contain personal audio and device information.

For acoustic evaluation, separately listen to speaker-only playback, speech-only input, typing between phrases, and speech overlapping speaker playback. Check both echo leakage and whether the local voice is damaged. Keep call-app echo cancellation enabled until that real-use setup has been validated.

import Foundation
import AppKit
import AVFoundation
import AudioCore
import CoreAudio
@MainActor final class Model: ObservableObject {
    @Published var devices: [Device] = []
    @Published var micUID = ""
    @Published var speakerUID = ""
    @Published var destinationUID = ""
    @Published var backend = "RNNoise"
    @Published var echoEnabled = false
    @Published var sending = false
    @Published var running = false
    @Published var starting = false
    @Published var bypass = false
    @Published var agc = false
    @Published var status = "Microphone stopped. Press Start to begin."
    @Published var health = "Start in analysis mode to test without sending audio to the virtual microphone."
    @Published var note = ""
    @Published var category = "General"
    @Published var lastReport = ""
    @Published var recording = false
    @Published var recordingSeconds: Double = 0
    @Published var recordingStatus = "No audio recorded this session."
    @Published var meter: Double = -120
    @Published var peak: Double = -120
    @Published var details = "No audio captured."
    @Published var setupWaiting = false
    @Published var setupMessage = ""
    private var setupDeadline: Date?
    var engine: OpaquePointer?
    var diagnostics: Diagnostics?
    private var timer: Timer?
    private var clipTimer: Timer?
    private var meterTimer: Timer?
    private var windowPeak: Double = -120
    private var windowRMS: Double = -120
    private var clip: AVAudioFile?
    private var clipFrames: Int = 0
    private var clipURL: URL?
    private var selectedDevices: [Device] = []
    private var previousInput: UInt64 = 0
    private var previousOutput: UInt64 = 0
    private var noInputTicks = 0
    private var noOutputTicks = 0
    private var previousStats: VBStats?
    private var observers: [NSObjectProtocol] = []
    private var audioActivity: NSObjectProtocol?
    init() {
        do { diagnostics = try Diagnostics() } catch { status = "Diagnostics unavailable: \(error.localizedDescription)" }
        let saved = UserDefaults.standard
        micUID = saved.string(forKey: "micUID") ?? ""
        speakerUID = saved.string(forKey: "speakerUID") ?? ""
        destinationUID = saved.string(forKey: "destinationUID") ?? ""
        backend = saved.string(forKey: "backend") == "Apple" ? "Apple" : "RNNoise"
        echoEnabled = saved.bool(forKey: "echoEnabled")
        sending = saved.bool(forKey: "sending")
        refresh()
        if saved.bool(forKey:"virtualMicSetupRequested") {
            setupWaiting=true;setupDeadline=Date().addingTimeInterval(300)
            setupMessage="Waiting for macOS to load VoiceBridge Microphone…"
        }
        diagnostics?.event("app_started",["build":"0.5.2-preview","os":ProcessInfo.processInfo.operatingSystemVersionString,"architecture":"arm64","devices":deviceJSON(),"backend":backend,"aecValidation":"unverified"])
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.stop(reason:"Mac going to sleep. Press Start after waking.") }
        })
        let displayTimer = Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in Task { @MainActor in self?.updateMeter() } }
        RunLoop.main.add(displayTimer,forMode:.common);meterTimer=displayTimer
        let healthTimer = Timer(timeInterval:1,repeats:true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        RunLoop.main.add(healthTimer,forMode:.common);timer=healthTimer
    }
    func saveSettings() {
        let saved = UserDefaults.standard
        saved.set(micUID, forKey: "micUID");saved.set(speakerUID, forKey: "speakerUID")
        saved.set(destinationUID, forKey: "destinationUID");saved.set(backend, forKey: "backend")
        saved.set(echoEnabled, forKey: "echoEnabled");saved.set(sending, forKey: "sending")
    }
    func refresh() {
        devices = Devices.all()
        if micUID.isEmpty { micUID = devices.first(where:{$0.inputs>0 && $0.name.contains("XCM")})?.uid ?? devices.first(where:{$0.inputs>0 && $0.physical})?.uid ?? "" }
        if speakerUID.isEmpty { speakerUID = devices.first(where:{$0.outputs>0 && $0.physical && $0.id == Devices.defaultOutput})?.uid ?? devices.first(where:{$0.outputs>0 && $0.name.contains("Speakers")})?.uid ?? "" }
        if destinationUID.isEmpty { destinationUID = devices.first(where:{$0.processedDestination})?.uid ?? "" }
    }
    var ownMicrophoneAvailable: Bool {
        devices.contains(where:{$0.voiceBridgeMic && $0.inputs==2 && $0.outputs==2 && $0.sampleRate==48000})
    }
    func setupMicrophone() {
        guard !running && !starting && !setupWaiting else {return}
        refresh()
        if ownMicrophoneAvailable {selectOwnMicrophone();return}
        guard let package=Bundle.main.url(forResource:"Install VoiceBridge Microphone",withExtension:"pkg") else {
            setupMessage="The microphone installer is missing from this app. Rebuild or reinstall VoiceBridge."
            diagnostics?.event("microphone_setup_failed",["reason":"bundled installer missing"]);return
        }
        setupWaiting=true;setupDeadline=Date().addingTimeInterval(300)
        UserDefaults.standard.set(true,forKey:"virtualMicSetupRequested")
        setupMessage="Finish the macOS installer and administrator prompt. Sound will briefly restart. VoiceBridge will select the microphone when it appears."
        diagnostics?.event("microphone_setup_requested")
        if !NSWorkspace.shared.open(package) {
            cancelMicrophoneSetup()
            setupMessage="macOS could not open the microphone installer. Try setup again."
            diagnostics?.event("microphone_setup_failed",["reason":"installer open failed"])
        }
    }
    func cancelMicrophoneSetup() {
        setupWaiting=false;setupDeadline=nil
        UserDefaults.standard.removeObject(forKey:"virtualMicSetupRequested")
        setupMessage="Setup check stopped. If Installer is open, cancel it there too."
    }
    private func selectOwnMicrophone() {
        guard !running,let destination=devices.first(where:{$0.voiceBridgeMic && $0.processedDestination && $0.inputs==2 && $0.sampleRate==48000}) else {return}
        destinationUID=destination.uid;sending=true;saveSettings()
        setupWaiting=false;setupDeadline=nil
        UserDefaults.standard.removeObject(forKey:"virtualMicSetupRequested")
        setupMessage="VoiceBridge Microphone is ready. Press Start, then select VoiceBridge Microphone as the input in your calling app. UNIFY is not needed for this route."
        diagnostics?.event("microphone_setup_ready",["deviceUID":destination.uid])
    }
    private func checkMicrophoneSetup() {
        guard setupWaiting else {return}
        refresh()
        if ownMicrophoneAvailable {selectOwnMicrophone();return}
        if let deadline=setupDeadline,Date()>deadline {
            cancelMicrophoneSetup()
            setupMessage="VoiceBridge Microphone has not appeared. Complete Installer, then try setup again. If installation succeeded, restarting the Mac may be required."
            diagnostics?.event("microphone_setup_timeout")
        }
    }
    func start() {
        guard !running && !starting && !setupWaiting else { return }
        guard diagnostics != nil else { status = "Cannot start without writable diagnostics.";return }
        saveSettings()
        starting = true
        let permission = AVCaptureDevice.authorizationStatus(for:.audio)
        if permission == .authorized { startAuthorized();return }
        if permission == .notDetermined {
            AVCaptureDevice.requestAccess(for:.audio) { [weak self] allowed in Task { @MainActor in
                if allowed { self?.startAuthorized() } else { self?.starting=false;self?.status="Microphone access denied. Enable VoiceBridge in System Settings → Privacy & Security → Microphone." }
            }}
        } else { starting=false;status="Enable VoiceBridge in System Settings → Privacy & Security → Microphone." }
    }
    private func startAuthorized() {
        defer { starting=false }
        refresh()
        guard let mic=devices.first(where:{$0.uid==micUID && $0.inputs>0 && $0.physical}),let speaker=devices.first(where:{$0.uid==speakerUID && $0.outputs>0 && $0.physical}) else { status="Select a physical microphone and physical speakers.";return }
        let destination=devices.first(where:{$0.uid==destinationUID && $0.processedDestination})
        if sending {
            guard destination != nil else { status="Selected virtual microphone output is missing. Install the VoiceBridge driver or open UNIFY, then refresh devices.";return }
            guard !NSRunningApplication.runningApplications(withBundleIdentifier:"com.obsproject.obs-studio").contains(where:{!$0.isTerminated}) else { status="Quit OBS before sending processed audio, so two mic signals cannot mix. Analysis mode works with OBS open.";return }
        }
        selectedDevices=[mic,speaker]+(sending ? (destination.map{[$0]} ?? []) : [])
        guard let e=vb_create() else { status="Could not allocate audio buffers.";return }
        engine=e
        var error=[CChar](repeating:0,count:512)
        let result=vb_start(e,mic.id,speaker.id,destination?.id ?? 0,sending,backend=="RNNoise",echoEnabled && backend=="RNNoise",&error,512)
        guard result==0 else { let message=String(cString:error);diagnostics?.event("start_failed",["error":message,"code":result,"configuration":configuration()]);vb_destroy(e);engine=nil;status=message;return }
        windowPeak = -120;windowRMS = -120;running=true;bypass=false;agc=false;previousInput=0;previousOutput=0;noInputTicks=0;noOutputTicks=0;previousStats=nil
        status=sending ? "Running \(backend) → \(destination?.voiceBridgeMic == true ? "VoiceBridge Microphone" : "UNIFY → Unify Chat")" : "Running \(backend) in analysis mode"
        // Keep active audio work responsive when the diagnostics window is hidden,
        // while still allowing the Mac's normal idle sleep behavior.
        audioActivity=ProcessInfo.processInfo.beginActivity(options:.userInitiatedAllowingIdleSystemSleep,reason:"Process microphone audio")
        diagnostics?.event("engine_started",configuration())
    }
    func stop(reason: String = "Microphone stopped. Press Start to resume.") {
        if recording { finishClip() }
        if let e=engine { diagnostics?.event("engine_stopping",statsJSON(vb_stats(e)));vb_destroy(e);engine=nil }
        if let activity=audioActivity { ProcessInfo.processInfo.endActivity(activity);audioActivity=nil }
        running=false;starting=false;meter = -120;peak = -120;health="Capture stopped.";details="No live audio measurements.";status=reason;diagnostics?.event("engine_stopped",["reason":reason])
    }
    func setBypass(_ value: Bool) {
        guard let e=engine else { return }
        let code=vb_bypass(e,value)
        if code==0 { bypass=value;diagnostics?.event("bypass_changed",["bypassed":value]) } else { status="Bypass failed: \(code)";diagnostics?.event("control_failed",["control":"bypass","code":code]) }
    }
    func setAGC(_ value: Bool) {
        guard let e=engine else {return};let code=vb_agc(e,value)
        if code==0 {agc=value;diagnostics?.event("agc_changed",["enabled":value])}else{status="Gain control failed: \(code)"}
    }
    func updateMeter() {
        guard let e=engine else{return};let s=vb_stats(e)
        // Show the latest completed block directly: no visual decay or animation.
        meter=s.rms_db;peak=s.peak_db
        windowPeak=max(windowPeak,s.peak_db);windowRMS=max(windowRMS,s.rms_db)
    }
    func tick() {
        checkMicrophoneSetup()
        guard let e=engine else { return }
        let s=vb_stats(e)
        noInputTicks = s.input_frames==previousInput ? noInputTicks+1 : 0;previousInput=s.input_frames
        noOutputTicks = s.output_frames==previousOutput ? noOutputTicks+1 : 0;previousOutput=s.output_frames
        let deltaUnderruns=s.underruns-(previousStats?.underruns ?? 0), deltaDrops=s.overflows-(previousStats?.overflows ?? 0)
        details=String(format:"Queue %.1f ms • underruns %llu • dropped frames %llu\nInput %llu frames • output %llu frames • clipped %llu • invalid %llu\nClock ratio %.6f • Apple speaker callbacks %llu\nInput blocks %.1f ms • last callback %.1f ms ago (not total latency)",s.queue_ms,s.underruns,s.overflows,s.input_frames,s.output_frames,s.clipped_samples,s.invalid_samples,s.rate_ratio,s.reference_callbacks,Double(s.input_block_frames)/48.0,s.callback_age_ms)
        if s.echo_enabled {details+=String(format:"\nSpeaker ref %.1f dBFS • age %.1f ms • missing %.2f%%\nAEC input %.1f / output %.1f dBFS (not an echo score)",s.echo.reference_db,s.echo.reference_age_ms,100*Double(s.echo.missing_samples)/Double(max(1,s.echo.processed_samples)),s.echo.pre_echo_db,s.echo.post_echo_db)}
        if s.rnnoise_enabled {details+=String(format:"\nRNNoise speech score %.2f • DSP %.2f ms per block",s.rnnoise_speech_probability,s.processing_ms)}
        health = noInputTicks>2 ? "No input callbacks — microphone capture has stalled." : (sending && noOutputTicks>2 ? "Virtual microphone output has stalled." : (deltaUnderruns>0 || deltaDrops>0 ? "Audio buffering trouble detected. Mark a problem to save the evidence." : (backend=="RNNoise" ? "Audio callbacks healthy. RNNoise filters noise; it does not cancel speaker echo." : "Audio callbacks healthy. Echo removal still needs a listening test.")))
        if s.echo_enabled {
            health = s.echo.reference_error != 0 ? "Speaker-reference format/timestamp error. Echo test is not valid." : (s.echo.reference_age_ms<0 || s.echo.reference_age_ms>500 ? "Speaker reference missing or stalled; echo cancellation may be bypassing." : (s.echo.processed_samples>48000 && Double(s.echo.missing_samples)/Double(s.echo.processed_samples)>0.05 ? "Speaker reference timing is incomplete; echo cancellation is skipping frames." : "Speaker reference is arriving. Echo removal still needs a listening test."))
        }
        var metrics=statsJSON(s);metrics["windowPeakDBFS"]=windowPeak;metrics["windowMaxRMSDBFS"]=windowRMS
        if let d=selectedDevices.first(where:{$0.voiceBridgeMic}),let driver=Devices.virtualMicStats(d.id) {metrics["virtualMicDriver"]=driver}
        diagnostics?.event("metrics",metrics);windowPeak = -120;windowRMS = -120;previousStats=s
        if s.render_error != 0 || noInputTicks>=5 || (sending && noOutputTicks>=5) { stop(reason:"Stopped after audio failure. Mark a problem to save diagnostics.");return }
        let current=Devices.all()
        if selectedDevices.contains(where:{selected in !current.contains(where:{$0.uid==selected.uid && $0.id==selected.id})}) { stop(reason:"Audio device changed or disconnected. Refresh devices and restart.");return }
        if sending && NSRunningApplication.runningApplications(withBundleIdentifier:"com.obsproject.obs-studio").contains(where:{!$0.isTerminated}) { stop(reason:"OBS opened. VoiceBridge stopped to prevent duplicate mic audio.") }
    }
    func configuration() -> [String:Any] { ["build":"0.5.2-preview","backend":backend,"outputReserveMS":10,"captureAPI":backend=="RNNoise" ? "Direct HAL input" : "VoiceProcessingIO","rnnoiseCommit":"70f1d256acd4b34a572f999a05c87bf00b67730d","micUID":micUID,"speakerUID":speakerUID,"destinationUID":destinationUID,"sending":sending,"bypassed":bypass,"automaticGain":agc,"sampleRate":48000,"echoEnabled":echoEnabled && backend=="RNNoise","aecValidation":echoEnabled ? "SpeexDSP + speaker tap — not acoustically verified" : (backend=="RNNoise" ? "disabled — RNNoise only" : "Apple not acoustically verified"),"reference":echoEnabled ? "Private unmuted Core Audio tap of selected speaker output; VoiceBridge excluded; timestamp-aligned reference" : "macOS VoiceProcessingIO physical output device; own render callback supplies silence","devices":deviceJSON(),"permission":AVCaptureDevice.authorizationStatus(for:.audio).rawValue] }
    func deviceJSON() -> [[String:Any]] { devices.map{["id":$0.id,"uid":$0.uid,"name":$0.name,"inputs":$0.inputs,"outputs":$0.outputs,"rate":$0.sampleRate,"transport":$0.transport]} }
    func statsJSON(_ s: VBStats) -> [String:Any] { ["echoEnabled":s.echo_enabled,"echo":echoJSON(s.echo),"rnnoiseEnabled":s.rnnoise_enabled,"rnnoiseSpeechProbability":s.rnnoise_speech_probability,"processingMS":s.processing_ms,"inputBlockFrames":s.input_block_frames,"inputBlockMS":Double(s.input_block_frames)/48.0,"callbackAgeMS":s.callback_age_ms,"inputFrames":s.input_frames,"outputFrames":s.output_frames,"inputCallbacks":s.input_callbacks,"outputCallbacks":s.output_callbacks,"speakerIOCallbacks":s.reference_callbacks,"rmsDBFS":s.rms_db,"peakDBFS":s.peak_db,"queueMS":s.queue_ms,"rateRatio":s.rate_ratio,"underruns":s.underruns,"overflowFrames":s.overflows,"clippedSamples":s.clipped_samples,"invalidSamples":s.invalid_samples,"renderError":s.render_error,"duckingStatus":s.ducking_status,"actualInputID":s.actual_input,"actualSpeakerID":s.actual_speaker,"actualDestinationID":s.actual_destination,"lastInputHostTime":s.last_input_host_time,"lastOutputHostTime":s.last_output_host_time,"bypassed":s.bypass,"agc":s.agc,"recordingDrops":engine.map{vb_recording_drops($0)} ?? 0] }
    func echoJSON(_ e: VBEchoStats)->[String:Any] { ["referenceFrames":e.reference_frames,"referenceCallbacks":e.reference_callbacks,"referenceDrops":e.reference_drops,"referenceDBFS":e.reference_db,"referenceAgeMS":e.reference_age_ms,"missingSamples":e.missing_samples,"processedSamples":e.processed_samples,"echoFrames":e.echo_frames,"skippedFrames":e.skipped_frames,"preEchoDBFS":e.pre_echo_db,"postEchoDBFS":e.post_echo_db,"referenceError":e.reference_error,"referenceLeadMS":e.reference_lead_ms] }
    func markProblem() {
        var state=configuration();state["status"]=status;state["health"]=health
        if let e=engine {state["metrics"]=statsJSON(vb_stats(e))};if let path=clipURL?.path {state["lastExplicitClip"]=path}
        do { guard let url=try diagnostics?.report(note:note,category:category,state:state) else{return};lastReport=url.path;note="" } catch {lastReport="Report save failed: \(error.localizedDescription)"}
    }
    func recordClip() {
        guard let e=engine,!recording,let directory=diagnostics?.session else{return}
        do {
            let url=directory.appendingPathComponent("explicit-clip-\(Int(Date().timeIntervalSince1970)).caf")
            let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
            clip=try AVAudioFile(forWriting:url,settings:format.settings);clipURL=url;clipFrames=0
            // Remove stale queued data before starting an explicitly requested clip.
            var discard=[Float](repeating:0,count:32768);_ = vb_read_recording(e,&discard,32768)
            recordingSeconds=0;recordingStatus="Recording locally…";recording=true;vb_recording(e,true);diagnostics?.event("clip_started",["path":url.path,"processingBypassed":bypass,"backend":backend,"echoEnabled":echoEnabled])
            let recorderTimer=Timer(timeInterval:0.1,repeats:true) { [weak self] _ in Task { @MainActor in self?.drainClip() } }
            RunLoop.main.add(recorderTimer,forMode:.common);clipTimer=recorderTimer
        } catch {status="Could not start clip: \(error.localizedDescription)"}
    }
    private func drainClip() {
        guard let e=engine,let file=clip else{return}
        let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:32768)!
        let count=vb_read_recording(e,buffer.floatChannelData![0],32768)
        let remaining=max(0,480000-clipFrames);buffer.frameLength=min(count,UInt32(remaining))
        do {if buffer.frameLength>0 {try file.write(from:buffer);clipFrames+=Int(buffer.frameLength);recordingSeconds=Double(clipFrames)/48000}}catch{status="Clip write failed: \(error.localizedDescription)";finishClip();return}
        if clipFrames>=480000{finishClip()}
    }
    func finishClip() {
        if let e=engine{vb_recording(e,false)};clipTimer?.invalidate();clipTimer=nil;clip=nil;recording=false
        recordingStatus=String(format:"Saved %.1f seconds locally. %@",Double(clipFrames)/48000,clipURL?.lastPathComponent ?? "")
        diagnostics?.event("clip_finished",["frames":clipFrames,"seconds":Double(clipFrames)/48000,"drops":engine.map{vb_recording_drops($0)} ?? 0]);lastReport=clipURL?.path ?? ""
    }
    func revealReports() {if let url=diagnostics?.session{NSWorkspace.shared.open(url)}}
}

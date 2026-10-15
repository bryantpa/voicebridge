import AppKit
import AVFoundation

struct TestCase: Codable {let name:String;let mode:String;let reserveMS:Int}
struct TestPlan: Codable {let tests:[TestCase];let route:String?}

@MainActor final class CheckApp: NSObject,NSApplicationDelegate {
    var window:NSWindow!
    let label=NSTextField(wrappingLabelWithString:"For a live test, leave VoiceBridge running. Click Measure and speak for ten seconds. For the automatic test, stop VoiceBridge first.\n\nThe selected route comes from TestPlan.json. No new audio is saved or uploaded.")
    let button=NSButton(title:"Measure 10 Seconds",target:nil,action:nil)
    let routeButton=NSButton(title:"Measure Routing Only",target:nil,action:nil)
    let suiteButton=NSButton(title:"Run Automatic Test Loop",target:nil,action:nil)
    var route="voicebridge"
    var routingOnly=false
    var pipelineProbe=false,pipelineBypass=false
    var engine:OpaquePointer?
    var pendingTests:[TestCase]=[],suiteResults:[[String:Any]]=[]
    var currentTest="",suiteActive=false
    var currentReserveMS=30,totalTests=0
    var raw:OpaquePointer?,processed:OpaquePointer?
    var timer:Timer?,started:Date?
    var reportURL:URL!
    func applicationDidFinishLaunching(_ notification:Notification) {
        let planURL=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("TestPlan.json")
        if let data=try? Data(contentsOf:planURL),let plan=try? JSONDecoder().decode(TestPlan.self,from:data),let selected=plan.route,["voicebridge","unify"].contains(selected) {route=selected}
        reportURL=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VoiceBridge/LatencyReports")
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:570,height:350),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="VoiceBridge — local delay check"
        label.frame=NSRect(x:24,y:150,width:522,height:180);label.font = .systemFont(ofSize:15)
        button.frame=NSRect(x:24,y:80,width:220,height:38);button.target=self;button.action=#selector(measure)
        routeButton.frame=NSRect(x:270,y:80,width:240,height:38);routeButton.target=self;routeButton.action=#selector(measureRouting)
        suiteButton.frame=NSRect(x:24,y:28,width:486,height:38);suiteButton.target=self;suiteButton.action=#selector(runSuite)
        window.contentView?.addSubview(label);window.contentView?.addSubview(button);window.contentView?.addSubview(routeButton);window.contentView?.addSubview(suiteButton)
        window.center();window.makeKeyAndOrderFront(nil)
        let menu=NSMenu(),item=NSMenuItem(),appMenu=NSMenu()
        appMenu.addItem(withTitle:"Quit Delay Check",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");item.submenu=appMenu;menu.addItem(item);NSApp.mainMenu=menu;NSApp.activate(ignoringOtherApps:true)
    }
    @objc func measure() { routingOnly=false;pipelineProbe=false; requestMeasurement() }
    @objc func measureRouting() { routingOnly=true;pipelineProbe=false; requestMeasurement() }
    @objc func runSuite() {
        suiteActive=true;suiteResults=[]
        let url=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("TestPlan.json")
        do {
            let plan=try JSONDecoder().decode(TestPlan.self,from:Data(contentsOf:url))
            guard !plan.tests.isEmpty,plan.tests.count<=20,plan.tests.allSatisfy({["route","bypass","processed"].contains($0.mode) && (10...60).contains($0.reserveMS)}) else{fail("Invalid test plan.");return}
            guard plan.route == nil || ["unify","voicebridge"].contains(plan.route!) else {fail("Unknown test route.");return}
            route=plan.route ?? "voicebridge"
            pendingTests=plan.tests;totalTests=pendingTests.count
        }catch{fail("Could not read TestPlan.json: \(error.localizedDescription)");return}
        nextTest()
    }
    func nextTest() {
        guard !pendingTests.isEmpty else {completeSuite();return}
        let test=pendingTests.removeFirst();currentTest=test.name;currentReserveMS=test.reserveMS
        routingOnly=test.mode=="route";pipelineProbe = !routingOnly
        pipelineBypass=test.mode=="bypass"
        requestMeasurement()
    }
    func requestMeasurement() {
        button.isEnabled=false;routeButton.isEnabled=false;suiteButton.isEnabled=false
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized: begin()
        case .notDetermined:
            label.stringValue=routingOnly ? "Allow audio input access to measure the selected virtual microphone. The internal signal test starts automatically; no speaking is needed. VoiceBridge should be stopped during this test." : "Allow microphone access, then speak naturally for ten seconds. The test will start automatically after approval."
            AVCaptureDevice.requestAccess(for:.audio){allowed in Task{@MainActor in if allowed{self.begin()}else{self.fail("Microphone access was denied.")}}}
        default: fail("Enable microphone access for VoiceBridge Delay Check in System Settings, then try again.")
        }
    }
    func begin() {
        let devices=Devices.all()
        guard let mic=devices.first(where:{$0.physical && $0.name.contains("XCM") && $0.inputs==1}),let chat=devices.first(where:{(route=="voicebridge" ? $0.voiceBridgeMic : $0.uid=="RodeUnifyAudioDevice_UID_2") && $0.inputs==2}),mic.sampleRate==48000,chat.sampleRate==48000 else {fail("This test needs the XCM-50 and the selected virtual microphone at 48 kHz.");return}
        raw=pipelineProbe ? nil : lc_create();processed=lc_create()
        guard (pipelineProbe || raw != nil),processed != nil else {fail("Unable to allocate capture buffers.");return}
        let origin=lc_now()
        guard let virtual=devices.first(where:{(route=="voicebridge" ? $0.voiceBridgeMic : $0.uid=="RodeUnifyAudioDevice_UID_6") && $0.outputs==2}) else{fail("Selected virtual microphone output is missing.");return}
        let b=lc_start(processed,chat.id,2,origin)
        var a:Int32=0
        if pipelineProbe {
            guard let speaker=devices.first(where:{$0.name=="Mac mini Speakers"}),let fixture=Bundle.main.url(forResource:"test-fixture",withExtension:"caf") else{fail("Physical speakers or local voice fixture missing. Build with VB_TEST_FIXTURE for processing tests; routing tests need no fixture.");return}
            do {
                let file=try AVAudioFile(forReading:fixture)
                guard file.processingFormat.sampleRate==48000,file.processingFormat.channelCount==1 else{fail("Fixture must be mono 48 kHz.");return}
                let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:AVAudioFrameCount(min(file.length,480000)))!
                try file.read(into:buffer)
                engine=vb_create()
                // Repeat the voiced opening through every analysis window, with
                // different gains. Silence-heavy source tails otherwise cannot
                // establish timing after RNNoise suppresses them.
                let period=min(Int(buffer.frameLength),144000)
                guard period>0 else {fail("The voice fixture is empty.");return}
                let signal=(0..<480000).map{ i in buffer.floatChannelData![0][i%period] * [Float(1),0.8,1.1,0.9][i/period%4] }
                guard let engine,signal.withUnsafeBufferPointer({vb_probe_prepare(engine,$0.baseAddress,UInt32($0.count),origin)}),vb_output_reserve(engine,UInt32(currentReserveMS*48)) else{fail("Could not prepare fixture.");return}
                var error=[CChar](repeating:0,count:512)
                a=vb_start(engine,mic.id,speaker.id,virtual.id,true,true,true,&error,512)
                if a != 0 {fail(String(cString:error));return}
                if pipelineBypass {_=vb_bypass(engine,true)}
            }catch{fail("Could not read the local test fixture: \(error.localizedDescription)");return}
        }else{a=routingOnly ? lc_start_output(raw,virtual.id,origin) : lc_start(raw,mic.id,1,origin)}
        guard a==0,b==0 else {fail("Could not open both microphone inputs (\(a), \(b)).");return}
        started=Date();label.stringValue=routingOnly ? "Measuring the selected virtual output → input with a quiet internal signal. No speaking is needed.\n\nDo not use voice calling during this ten-second test." : "Speak now for ten seconds. Use a few different phrases with short pauses.\n\nMeasuring raw mic → VoiceBridge → virtual microphone…"
        if suiteActive {label.stringValue="Automatic test \(suiteResults.count+1) of \(totalTests): \(currentTest)\n\nNo speaking needed. Uses the earlier local test clip in place of live microphone samples. Keep VoiceBridge stopped and avoid voice calls until finished.\n\nNo new audio is saved."}
        timer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self] _ in Task{@MainActor in self?.tick()}}
    }
    func tick() {
        guard let started else{return}
        let elapsed=Date().timeIntervalSince(started)
        if elapsed>=10.5 { finish();return }
        button.title="Measuring… \(max(0,10-Int(elapsed)))s"
    }
    func finish() {
        timer?.invalidate();timer=nil
        if let engine {vb_stop(engine)}
        lc_stop(raw);lc_stop(processed)
        guard (pipelineProbe || lc_error(raw)==0),lc_error(processed)==0 else{fail("Audio capture failed; please retry.");return}
        let x=(0..<5000).map{pipelineProbe ? vb_probe_reference_rms(engine,UInt32($0)) : lc_bin_rms(raw,UInt32($0))},y=(0..<5000).map{lc_bin_rms(processed,UInt32($0))}
        let vx=(0..<5000).map{(pipelineProbe ? vb_probe_reference_count(engine,UInt32($0)) : lc_bin_count(raw,UInt32($0)))>=48},vy=(0..<5000).map{lc_bin_count(processed,UInt32($0))>=48}
        var result=DelayAnalysis.estimate(x,y,vx,vy)
        result["mode"]=routingOnly ? "Virtual microphone routing only" : "Raw mic to virtual microphone"
        if routingOnly {result["scope"]="HAL output presentation timeline to HAL input timeline on selected virtual microphone; excludes VoiceBridge DSP and microphone. Driver timestamps not independently calibrated."}
        if pipelineProbe,let engine {
            result["mode"]=currentTest
            result["reserveMS"]=currentReserveMS
            result["scope"]="Known speech injected at the shared VoiceBridge capture callback → identical DSP and output queue → selected virtual microphone. Excludes acoustic/ADC latency and call/network. Live mic samples discarded; original fixture already existed locally."
            let stats=vb_stats(engine)
            result["echoReferenceHealthy"]=stats.echo.reference_frames>0 && stats.echo.reference_error==0 && stats.echo.missing_samples==0
            result["engine"]=["underruns":stats.underruns,"droppedFrames":stats.overflows,"renderError":Int64(stats.render_error),"inputBlockFrames":UInt64(stats.input_block_frames),"echoSkippedFrames":stats.echo.skipped_frames,"echoMissingSamples":stats.echo.missing_samples,"outputFrames":stats.output_frames]
            if stats.underruns>0 || stats.overflows>0 || stats.render_error != 0 {result["accepted"]=false;result["audioFailure"]=true}
        }
        result["route"]=route
        if route=="voicebridge",let device=Devices.all().first(where:{$0.voiceBridgeMic}),let counters=Devices.virtualMicStats(device.id) {result["driver"]=counters}
        result["time"]=ISO8601DateFormatter().string(from:Date());result["audioSaved"]=false
        let accepted=result["accepted"] as? Bool == true
        let ms=result["delayMS"] as? Int ?? 0
        label.stringValue=accepted ? "Estimated local microphone delay: \(ms) ms\n\nThis measures the raw RØDE input to the selected virtual microphone. It excludes the calling app, network and the other person's playback. Repeat to check consistency.\n\nOnly timing results are saved." : "No reliable timing match this time.\n\nCheck that VoiceBridge is sending to the selected virtual microphone. For UNIFY, Chat must contain only the Virtual channel. Speak clearly throughout the next test, with short pauses.\n\nNo audio was saved."
        if routingOnly && accepted {label.stringValue="Virtual microphone routing delay: \(ms) ms\n\nMeasured from selected virtual output to its corresponding input using a generated signal. VoiceBridge processing is excluded.\n\nTest complete. Restart VoiceBridge to restore your microphone."}
        do {try FileManager.default.createDirectory(at:reportURL,withIntermediateDirectories:true);let url=reportURL.appendingPathComponent("latency-\(Int(Date().timeIntervalSince1970)).json");try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:url)}catch{label.stringValue+="\nCould not save report: \(error.localizedDescription)"}
        cleanup();button.title="Measure Again";button.isEnabled=true;routeButton.isEnabled=true
        if suiteActive {suiteResults.append(result);nextTest()}else{suiteButton.isEnabled=true}
    }
    func completeSuite() {
        suiteActive=false;suiteButton.isEnabled=true
        let passed=suiteResults.filter{$0["accepted"] as? Bool == true}
        var lines=["Automatic loop: \(passed.count)/\(suiteResults.count) reliable matches"]
        if let routing=passed.first(where:{$0["mode"] as? String == "Virtual microphone routing only"}){lines.append("Routing alone: \(routing["delayMS"] ?? "?") ms")}
        for reserve in [30,20,10] {
            let values=passed.filter{($0["mode"] as? String ?? "").hasPrefix("Full processing") && $0["reserveMS"] as? Int == reserve}.compactMap{$0["delayMS"] as? Int}.sorted()
            if !values.isEmpty{lines.append("\(reserve) ms buffer: \(values.first!)–\(values.last!) ms measured")}
        }
        label.stringValue=lines.joined(separator:"\n")+"\n\nFinished. Restart VoiceBridge to restore your mic."
        do {let url=reportURL.appendingPathComponent("suite-\(Int(Date().timeIntervalSince1970)).json");try JSONSerialization.data(withJSONObject:["tests":suiteResults,"audioSaved":false,"fixture":"User-supplied local voice fixture (not published)","engineSource":"Shared AudioCore implementation; no separate simulated DSP"],options:[.prettyPrinted,.sortedKeys]).write(to:url)}catch{label.stringValue+="\nReport save failed."}
    }
    func cleanup(){timer?.invalidate();timer=nil;lc_destroy(raw);lc_destroy(processed);raw=nil;processed=nil;if let engine{vb_destroy(engine)};engine=nil}
    func fail(_ message:String){cleanup();suiteActive=false;pendingTests=[];label.stringValue=message;button.title="Measure 10 Seconds";button.isEnabled=true;routeButton.isEnabled=true;suiteButton.isEnabled=true}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{true}
    func applicationWillTerminate(_ notification:Notification){cleanup()}
}
@main struct Main {
    @MainActor static func main(){
        if CommandLine.arguments.contains("--self-test"){let ok=DelayAnalysis.selftest();print(ok ? "PASS: known delay, zero delay, silence and missing capture rejected appropriately" : "FAIL");exit(ok ? 0 : 1)}
        let app=NSApplication.shared;app.setActivationPolicy(.regular);let delegate=CheckApp();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}
    }
}

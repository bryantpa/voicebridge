import SwiftUI
import AppKit
import AudioCore
struct LevelMeter: View {
    let rms: Double
    let peak: Double
    private func fraction(_ db: Double) -> Double { max(0,min(1,(db+70)/70)) }
    var body: some View {
        GeometryReader { box in
            ZStack(alignment:.leading) {
                Rectangle().fill(Color.secondary.opacity(0.2))
                Rectangle().fill(Color.green).frame(width:box.size.width*fraction(rms))
                Rectangle().fill(Color.orange).frame(width:2).offset(x:max(0,(box.size.width-2)*fraction(peak)))
            }
        }.frame(height:10)
        .transaction { $0.animation=nil; $0.disablesAnimations=true }
        .accessibilityElement(children:.ignore)
        .accessibilityLabel("Live microphone level")
        .accessibilityValue(String(format:"RMS %.1f, peak %.1f decibels",rms,peak))
    }
}
struct Panel: View {
    @ObservedObject var model: Model
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack { Text("VoiceBridge").font(.title.bold());Text("0.5.2-preview · experimental").foregroundStyle(.secondary);Spacer();Circle().fill(model.running ? .green : .gray).frame(width:10,height:10) }
            Text("\(model.micName) → noise and echo processing → virtual microphone").foregroundStyle(.secondary)
            VStack(alignment:.leading,spacing:6) {
                HStack {
                    Button(model.setupWaiting ? "Waiting for microphone…" : (model.ownMicrophoneAvailable ? "Use VoiceBridge Microphone" : "Set up VoiceBridge Microphone…")) {model.setupMicrophone()}
                        .disabled(model.running || model.starting || model.setupWaiting)
                    if model.setupWaiting {Button("Cancel check"){model.cancelMicrophoneSetup()}}
                }
                Text(model.setupMessage.isEmpty ? "One-time setup opens the macOS installer. Administrator approval is required and sound briefly restarts. Finish calls before setup." : model.setupMessage)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            GroupBox("Audio route") {
                VStack(spacing:10) {
                    Picker("Microphone",selection:$model.micUID) {ForEach(model.devices.filter{$0.inputs>0 && $0.physical}){Text($0.name).tag($0.uid)}}
                    Picker("Physical speakers (echo reference)",selection:$model.speakerUID) {ForEach(model.devices.filter{$0.outputs>0 && $0.physical}){Text($0.name).tag($0.uid)}}
                    Picker("Processed audio destination",selection:$model.destinationUID) {ForEach(model.devices.filter{$0.processedDestination}){Text($0.name).tag($0.uid)}}
                    Picker("Noise filter",selection:$model.backend) {Text("RNNoise — keyboard-noise test").tag("RNNoise");Text("Apple voice processing — experimental echo").tag("Apple")}
                    Toggle("Cancel speaker echo — experimental",isOn:$model.echoEnabled).disabled(model.backend != "RNNoise")
                    Toggle("Send to virtual microphone",isOn:$model.sending)
                    HStack {Text("Off = analysis only; no audio is sent to the virtual microphone.").font(.caption).foregroundStyle(.secondary);Spacer();Button("Refresh devices"){model.refresh()}}
                }.padding(6).disabled(model.running || model.starting || model.setupWaiting)
            }
            HStack {
                Button(model.starting ? "Starting…" : (model.running ? "Stop" : "Start")) {if model.running{model.stop()}else{model.start()}}.buttonStyle(.borderedProminent).disabled(model.starting || model.setupWaiting)
                Toggle("Bypass processing",isOn:Binding(get:{model.bypass},set:{model.setBypass($0)})).disabled(!model.running)
                Toggle("Auto gain",isOn:Binding(get:{model.agc},set:{model.setAGC($0)})).disabled(!model.running || model.backend=="RNNoise")
            }
            Text(model.status).font(.headline).textSelection(.enabled)
            GroupBox("Live diagnostics") {
                VStack(alignment:.leading,spacing:8) {
                    HStack{Text(model.bypass ? "Bypassed mic" : "Processed mic");Spacer();Text(String(format:"RMS %.1f dBFS / Peak %.1f",model.meter,model.peak)).monospacedDigit()}
                    LevelMeter(rms:model.meter,peak:model.peak)
                    Text("Green: current level · Orange: current peak · No display smoothing").font(.caption).foregroundStyle(.secondary)
                    Text(model.health).foregroundStyle(.secondary)
                    Text(model.details).font(.system(.caption,design:.monospaced)).textSelection(.enabled).fixedSize(horizontal:false,vertical:true)
                    Text(model.backend=="RNNoise" ? (model.echoEnabled ? "Speaker-tap echo cancellation is experimental. Keep call-app echo cancellation on until tested." : "RNNoise mode has no echo cancellation. Keep echo cancellation enabled in your calling app.") : "Echo cancellation is experimental. Healthy callbacks do not prove that echo is removed.").font(.caption).foregroundStyle(.orange)
                }.padding(6)
            }
            GroupBox("Something sounded wrong") {
                VStack(alignment:.leading,spacing:8) {
                    Picker("Issue",selection:$model.category){ForEach(["General","Echo leaked","Keyboard leaked","Voice clipped","Robotic voice","Silence","Dropouts","Volume changed"],id:\.self){Text($0)}}
                    TextField("What happened? e.g. first word clipped while typing",text:$model.note)
                    HStack{Button("Mark problem"){model.markProblem()};Button("Show reports"){model.revealReports()};Spacer();Button(model.recording ? "Stop recording" : "Record 10-second sample"){if model.recording{model.finishClip()}else{model.recordClip()}}.disabled(!model.running)}
                    if model.recording { Text(String(format:"● Recording %.1f / 10 seconds",model.recordingSeconds)).foregroundStyle(.red).monospacedDigit() }
                    else { Text(model.recordingStatus).font(.caption).foregroundStyle(.secondary) }
                    Text("Reports contain local measurements and your note. Audio is saved only when you press Record. Automatic logs rotate; saved reports and samples are kept.").font(.caption).foregroundStyle(.secondary)
                    if !model.lastReport.isEmpty{Text(model.lastReport).font(.caption).textSelection(.enabled).lineLimit(2)}
                    if let error=model.diagnostics?.lastError{Text(error).foregroundStyle(.red)}
                }.padding(6)
            }
            Text("Close this window to keep running in the menu bar. Select VoiceBridge Microphone in calls when using its driver."+(model.unifySelected ? " For the UNIFY destination, keep UNIFY running and select RØDE Unify Chat." : "")+" Stop before changing the destination.").font(.caption).foregroundStyle(.secondary)
        }.padding(22).frame(width:740)
    }
}
@main struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.count==4 && CommandLine.arguments[1]=="--denoise" {
            do {try Offline.denoise(input:CommandLine.arguments[2],output:CommandLine.arguments[3]);return}
            catch {fputs("Denoising failed: \(error)\n",stderr);exit(1)}
        }
        if CommandLine.arguments.contains("--self-test") {let result=vb_transport_selftest()+vb_noise_selftest()+vb_echo_selftest();print("Transport self-test: \(result == 0 ? "PASS" : "FAIL \(result)")");exit(result == 0 ? 0 : 1)}
        if CommandLine.arguments.contains("--devices") {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];if let data=try? encoder.encode(Devices.all()){print(String(decoding:data,as:UTF8.self))};return}
        let app=NSApplication.shared;app.setActivationPolicy(.accessory);let delegate=Delegate();app.delegate=delegate;withExtendedLifetime(delegate){app.run()}
    }
}

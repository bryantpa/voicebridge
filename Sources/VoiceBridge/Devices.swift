import Foundation
import CoreAudio
struct Device: Identifiable, Codable, Hashable {
    let id: UInt32
    let uid: String
    let name: String
    let inputs: Int
    let outputs: Int
    let sampleRate: Double
    let transport: UInt32
    var voiceBridgeMic: Bool { uid == "VoiceBridgeMicDevice_UID" }
    var processedDestination: Bool { outputs == 2 && (voiceBridgeMic || uid == "RodeUnifyAudioDevice_UID_6") }
    var physical: Bool { transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate }
}
enum Devices {
    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func string(_ id: UInt32, _ selector: AudioObjectPropertySelector) -> String {
        var a = address(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr else { return "Unknown" }
        return value.map { $0.takeRetainedValue() as String } ?? "Unknown"
    }
    static func scalar<T>(_ id: UInt32, _ selector: AudioObjectPropertySelector, fallback: T) -> T {
        var a = address(selector), value = fallback, size = UInt32(MemoryLayout<T>.size)
        _ = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &a, 0, nil, &size, $0) }
        return value
    }
    static func channels(_ id: UInt32, _ scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, ptr) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    static func all() -> [Device] {
        var a = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size)/4)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return ids.map { Device(id: $0, uid: string($0, kAudioDevicePropertyDeviceUID), name: string($0,kAudioObjectPropertyName), inputs: channels($0,kAudioDevicePropertyScopeInput), outputs: channels($0,kAudioDevicePropertyScopeOutput), sampleRate: scalar($0,kAudioDevicePropertyNominalSampleRate,fallback:0.0), transport:scalar($0,kAudioDevicePropertyTransportType,fallback:UInt32(0))) }
    }
    static func virtualMicStats(_ id: UInt32) -> [String:Any]? {
        var a=address(0x76627374) // 'vbst': read-only JSON counters, no audio.
        guard AudioObjectHasProperty(id,&a) else {return nil}
        let value=string(id,0x76627374)
        guard let data=value.data(using:.utf8) else {return nil}
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
    }
    static var defaultOutput: UInt32 { scalar(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDefaultOutputDevice,fallback:UInt32(0)) }
}

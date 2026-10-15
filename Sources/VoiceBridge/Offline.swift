import Foundation
import AVFoundation
import AudioCore
// Process an existing consented recording; never opens a microphone or network.
enum Offline {
    static func denoise(input: String, output: String) throws {
        let source=try AVAudioFile(forReading:URL(fileURLWithPath:input))
        guard source.processingFormat.sampleRate==48000,source.processingFormat.channelCount==1,
              let processor=vb_noise_create() else { throw NSError(domain:"VoiceBridge",code:1,userInfo:[NSLocalizedDescriptionKey:"Expected mono 48 kHz input and a working RNNoise model."]) }
        defer {vb_noise_destroy(processor)}
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:1)!
        let file=try AVAudioFile(forWriting:URL(fileURLWithPath:output),settings:format.settings)
        let block=AVAudioPCMBuffer(pcmFormat:source.processingFormat,frameCapacity:4096)!
        while source.framePosition<source.length {
            try source.read(into:block)
            guard block.frameLength>0 else{break}
            vb_noise_process(processor,block.floatChannelData![0],block.floatChannelData![0],block.frameLength)
            try file.write(from:block)
        }
        // Preserve the delayed tail without trimming or normalizing either take.
        let tail=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:9600)!;tail.frameLength=9600
        tail.floatChannelData![0].initialize(repeating:0,count:9600)
        vb_noise_process(processor,tail.floatChannelData![0],tail.floatChannelData![0],9600)
        try file.write(from:tail)
        print("RNNoise processed existing clip locally: \(output)")
    }
}

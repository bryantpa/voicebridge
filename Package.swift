// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "VoiceBridge", platforms: [.macOS("14.4")],
    products: [.executable(name: "VoiceBridge", targets: ["VoiceBridge"])],
    targets: [
        .target(name: "RNNoise", exclude: ["COPYING","PROVENANCE.txt"], publicHeadersPath: "include", cSettings: [.headerSearchPath("src"), .define("RNNOISE_BUILD")]),
        .target(name: "SpeexDSP", exclude: ["COPYING","PROVENANCE.txt"], publicHeadersPath: "include", cSettings: [.headerSearchPath("src"), .define("FLOATING_POINT"), .define("USE_SMALLFT"), .define("EXPORT", to: "")]),
        .target(name: "AudioCore", dependencies: ["RNNoise", "SpeexDSP"], publicHeadersPath: "include", linkerSettings: [.linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio")]),
        .executableTarget(name: "VoiceBridge", dependencies: ["AudioCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("AVFoundation")])
    ], swiftLanguageModes: [.v5])

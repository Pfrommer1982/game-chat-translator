// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SystemAudioTranscriber",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SystemAudioTranscriber", targets: ["SystemAudioTranscriber"]),
        .executable(name: "GameChatTranslatorApp", targets: ["GameChatTranslatorApp"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SystemAudioTranscriber",
            dependencies: ["CWhisperBridge"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/src",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-blas",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-metal"
                ])
            ]
        ),
        .target(
            name: "CWhisperBridge",
            cxxSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../../vendor/whisper.cpp/include"),
                .headerSearchPath("../../vendor/whisper.cpp/ggml/include"),
                .unsafeFlags(["-std=c++17"])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Lvendor/whisper.cpp/build/src",
                    "-Lvendor/whisper.cpp/build/ggml/src",
                    "-lwhisper",
                    "-lggml"
                ])
            ]
        ),
        .executableTarget(
            name: "GameChatTranslatorApp",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI")
            ]
        )
    ]
)

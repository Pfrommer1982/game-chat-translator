// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SystemAudioTranscriber",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SystemAudioTranscriber", targets: ["SystemAudioTranscriber"]),
        .executable(name: "GameChatTranslatorApp", targets: ["GameChatTranslatorApp"]),
        .executable(name: "RunTests", targets: ["RunTests"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "SystemAudioTranscriber",
            dependencies: ["GameChatTranslatorCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/src",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-blas",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-metal"
                ])
            ]
        ),
        .target(
            name: "GameChatTranslatorCore",
            dependencies: ["CWhisperBridge"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate")
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
            dependencies: ["GameChatTranslatorCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
                .linkedFramework("LocalAuthentication"),
                .unsafeFlags([
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/src",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-blas",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-metal"
                ])
            ]
        ),
        .executableTarget(
            name: "RunTests",
            dependencies: ["GameChatTranslatorCore"],
            path: "Tests/GameChatTranslatorTests",
            swiftSettings: [
                .unsafeFlags([
                    "-Fsystem",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Fsystem",
                    "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-framework", "Testing",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/src",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-blas",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../../../vendor/whisper.cpp/build/ggml/src/ggml-metal"
                ])
            ]
        )
    ]
)

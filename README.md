# SystemAudioTranscriber

Minimal macOS command-line prototype for capturing system audio with ScreenCaptureKit, keeping captured audio in memory, converting it to 16 kHz mono Float32 PCM, and sending PCM directly to whisper.cpp through an in-process C/C++ bridge.

## Requirements

- macOS 13+
- Xcode command line tools with Swift 5.9+
- Local `whisper.cpp` checkout under `vendor/whisper.cpp`
- A local whisper.cpp model file, for example `models/ggml-base.bin`

macOS permission is required:

System Settings -> Privacy & Security -> Screen & System Audio Recording

Enable permission for the terminal app that runs `swift run`.

## Create Project

```sh
mkdir -p SystemAudioTranscriber
cd SystemAudioTranscriber
swift package init --type executable
mkdir -p Sources/CWhisperBridge/include vendor models
```

This repository already contains the intended final layout:

```text
SystemAudioTranscriber/
  Package.swift
  Sources/
    SystemAudioTranscriber/
      main.swift
      SystemAudioCapture.swift
      PCMConverter.swift
      AudioRingBuffer.swift
      AudioLevelMeter.swift
      TranscriptionScheduler.swift
      WhisperTranscriber.swift
    CWhisperBridge/
      include/
        whisper_bridge.h
      whisper_bridge.cpp
  vendor/
    whisper.cpp/
```

## Add whisper.cpp

```sh
git submodule add https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp
```

or, without submodules:

```sh
git clone https://github.com/ggml-org/whisper.cpp vendor/whisper.cpp
```

## Build whisper.cpp

The SwiftPM package links against the local whisper.cpp build output. Build whisper.cpp first:

```sh
cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF
cmake --build vendor/whisper.cpp/build --config Release
```

whisper.cpp changes its library layout from time to time. `Package.swift` assumes the common CMake output paths:

- `vendor/whisper.cpp/build/src/libwhisper.*`
- `vendor/whisper.cpp/build/ggml/src/libggml.*`

If your checkout emits additional ggml split libraries, add their `-L` and `-l` entries in `Package.swift`. Do not work around this by invoking the whisper CLI with audio files.

## Download Model

Use whisper.cpp's model script:

```sh
bash vendor/whisper.cpp/models/download-ggml-model.sh base
mkdir -p models
cp vendor/whisper.cpp/models/ggml-base.bin models/ggml-base.bin
```

The model is read from disk. Captured audio is never written to disk.

## Build

```sh
swift build
```

## Run

Milestone 1 capture/debug mode:

```sh
swift run SystemAudioTranscriber --verbose
```

Milestone 2 local transcription mode:

```sh
swift run SystemAudioTranscriber \
  --model ./models/ggml-base.bin \
  --chunk-seconds 5 \
  --language auto \
  --verbose
```

Expected startup:

```text
Listening to system audio...
Audio: 16000 Hz mono Float32
Buffer: 5.0s
```

Example transcript output:

```text
[detected: en] this is a test sentence
[detected: de] das ist ein test
[detected: nl] dit is een test
```

## Memory-Only Audio Path

ScreenCaptureKit emits system audio as `CMSampleBuffer` values through `SCStreamOutput` for `.audio`. `PCMConverter` copies each sample buffer into an `AVAudioPCMBuffer`, uses `AVAudioConverter` when needed, and returns 16 kHz mono Float32 samples. `AudioRingBuffer` stores only a bounded rolling buffer in RAM. `TranscriptionScheduler` copies a short chunk from that ring buffer and passes `[Float]` directly to `WhisperTranscriber`, which calls `whisper_bridge_transcribe` with a raw `float *` and sample count. The bridge calls `whisper_full` in-process.

There is no WAV stage, no temporary captured audio file, and no whisper CLI invocation.

## Privacy Checklist

- No WAV files are created.
- No temporary audio files are created.
- Captured audio is not written to `/tmp`.
- Captured audio is not written to disk anywhere.
- Audio remains in process memory as Float32 PCM.
- Old rolling-buffer samples are discarded after the configured RAM duration.
- Transcription chunks are zeroed after bridge use where practical.
- No cloud API or paid service is used.
- No microphone input is used.
- `AVAudioEngine.inputNode` is not used.
- BlackHole, Loopback, Soundflower, aggregate devices, and virtual drivers are not used.
- System audio capture uses ScreenCaptureKit with `SCStreamConfiguration.capturesAudio = true`.
- Current process audio is excluded where the OS exposes `excludesCurrentProcessAudio`.

## TODO: Local Translation Only

- Translation must be local only.
- Do not send transcripts to cloud APIs.
- Translation should consume transcript text only, not raw audio.
- Possible engines:
  - Argos Translate
  - LibreTranslate running locally
  - CTranslate2/NLLB


# Game Chat Translator

Local macOS command-line prototype for near real-time game voice-chat translation.

It captures macOS system audio with ScreenCaptureKit, keeps captured audio in RAM, runs whisper.cpp in-process, and can translate detected speech to English locally. It was built for setups like PS Remote Play audio while playing on a PS5/TV.

## What It Does

- Captures system audio directly with ScreenCaptureKit.
- Does not use the microphone.
- Converts audio in memory to 16 kHz mono Float32 PCM.
- Uses local whisper.cpp through a C/C++ bridge.
- Supports local speech-to-English translation with `--translate-to en`.
- Uses voice activity gating so silence and most game noise are not sent to Whisper.
- In `--realtime` mode, groups speech into utterances instead of printing overlapping partial windows.

## Requirements

- macOS 13+
- Swift 5.9+
- Xcode Command Line Tools
- Homebrew `cmake`
- Screen & System Audio Recording permission for your terminal app

```sh
brew install cmake
```

Enable permission:

```text
System Settings -> Privacy & Security -> Screen & System Audio Recording
```

After changing this permission, quit and reopen Terminal.

## Clone

```sh
git clone --recursive https://github.com/Pfrommer1982/game-chat-translator.git
cd game-chat-translator
```

If you already cloned without submodules:

```sh
git submodule update --init --recursive
```

## Build whisper.cpp

This project links against a local whisper.cpp build. Metal is disabled for now because the current tested setup was more stable with CPU/Accelerate.

```sh
cmake -S vendor/whisper.cpp -B vendor/whisper.cpp/build \
  -DWHISPER_BUILD_TESTS=OFF \
  -DWHISPER_BUILD_EXAMPLES=OFF \
  -DGGML_METAL=OFF

cmake --build vendor/whisper.cpp/build --config Release
```

## Download A Model

Recommended first model:

```sh
mkdir -p models
curl -L --fail -o models/ggml-small.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin
```

`small` is a good baseline for multilingual game chat. `base` is faster but less accurate.

Do not commit model files to GitHub.

## Build The App

```sh
swift build
```

## Run The macOS GUI

```sh
swift run GameChatTranslatorApp
```

The GUI lets you choose a model, select a preset, start/stop translation, and copy or clear the live transcript. It currently launches the translator engine as a local helper process, so keep running it from the repository folder for development builds.

## Run: Game Chat To English

Balanced live game-chat preset:

```sh
swift run SystemAudioTranscriber \
  --model ./models/ggml-small.bin \
  --language auto \
  --translate-to en \
  --realtime \
  --threads 6 \
  --utterance-end-silence 0.45 \
  --utterance-max-seconds 5
```

Better for longer sentences and testing with clean spoken text:

```sh
swift run SystemAudioTranscriber \
  --model ./models/ggml-small.bin \
  --language auto \
  --translate-to en \
  --realtime \
  --threads 6 \
  --utterance-end-silence 0.75 \
  --utterance-max-seconds 9
```

For raw transcription without translation:

```sh
swift run SystemAudioTranscriber \
  --model ./models/ggml-small.bin \
  --language auto \
  --realtime \
  --threads 6
```

## Useful Options

- `--translate-to en`: translate detected speech to English locally.
- `--language auto`: let Whisper detect the spoken language.
- `--language fr`: force a known source language when testing.
- `--realtime`: use utterance-based live mode for voice chat.
- `--threads 6`: CPU threads for Whisper.
- `--silence-threshold 0.003`: raise to ignore more noise, lower if speech is missed.
- `--utterance-end-silence 0.45`: lower means faster output after speech pauses.
- `--utterance-max-seconds 5`: maximum speech segment length before forced translation.
- `--verbose`: show capture/VAD/transcription diagnostics.

## Privacy

Captured audio is not written to disk.

- No WAV files.
- No temporary captured-audio files.
- No microphone input.
- No cloud APIs.
- No virtual audio drivers.
- Audio exists as in-process RAM buffers only.
- Model files are read from disk, but captured audio is not saved.
- Recognized text is printed to stdout.

## Known Limits

- This is a CLI alpha, not a polished macOS app.
- Game audio and voice chat are mixed together by Remote Play, so loud explosions/music can still hurt accuracy.
- Whisper translation is best with complete phrases. Extremely short chunks are faster but less accurate.
- `small` is the practical starting point. `base` is faster but worse; larger models are better but slower.

## Troubleshooting

If you see silence only:

- Make sure audio is actually playing.
- Check Screen & System Audio Recording permission.
- Restart Terminal after granting permission.
- Try `--verbose`.

If it hallucinates when nobody is talking:

- Increase `--silence-threshold`, for example `0.005`.
- Lower game audio and raise chat audio in PlayStation/Remote Play settings.

If it skips speech:

- Lower `--silence-threshold`, for example `0.002`.
- Increase `--utterance-end-silence` for longer speech.

If model loading fails:

- Re-download the model with `curl -L --fail`.
- `ggml-small.bin` should be hundreds of MB, not a tiny partial download.

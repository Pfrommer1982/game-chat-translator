# Game Chat Translator

macOS app and command-line prototype for near real-time game voice-chat translation.

It captures macOS system audio with ScreenCaptureKit and keeps captured audio in RAM. The GUI supports Groq, OpenAI, custom OpenAI-compatible audio endpoints, and local whisper.cpp models. Every cloud provider can fall back to the selected local model automatically. It was built for setups like PS Remote Play audio while playing on a PS5/TV.

## What It Does

- Captures system audio directly with ScreenCaptureKit.
- Does not use the microphone.
- Converts audio in memory to 16 kHz mono Float32 PCM.
- Uses local whisper.cpp through a C/C++ bridge.
- Supports local speech-to-English translation with `--translate-to en`.
- Uses voice activity gating so silence and most game noise are not sent to Whisper.
- In `--realtime` mode, groups speech into utterances instead of printing overlapping partial windows.

## Requirements

- macOS 13.3+
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
  -DGGML_METAL=OFF \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3

cmake --build vendor/whisper.cpp/build --config Release
```

## Download A Model

Recommended realtime model:

```sh
mkdir -p models
curl -L --fail -o models/ggml-base.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
```

`base` is the default balance for multilingual game chat. The GUI recommends `tiny`, `base`, or `small` from the Mac's CPU and memory, and can open any compatible model file.

Do not commit model files to GitHub.

## Build The App

```sh
swift build
```

## Run The macOS GUI

```sh
swift run GameChatTranslatorApp
```

The GUI lets you choose a provider and model, select a preset, start/stop translation, open macOS privacy settings, and copy or clear the live transcript.

The packaged `.app` runs capture in-process. There is no separate audio-capture helper executable, so macOS only needs Screen & System Audio Recording permission for `GameChatTranslator.app` itself. Local Mode keeps translation on the Mac. Cloud modes send short utterances to the selected audio-translation endpoint and store each provider key in the user's local Application Support folder with user-only file permissions. Failed cloud requests immediately use the selected local model. Battle Mode retains queued utterances and allows repeated commands instead of discarding them as duplicate text.

Provider options:

- **Groq**: `whisper-large-v3-turbo` for speed or `whisper-large-v3` for quality.
- **OpenAI**: `gpt-4o-mini-transcribe`, `gpt-4o-transcribe`, or `whisper-1`.
- **Compatible API**: enter a full OpenAI-compatible audio translations endpoint, API key, and model name.
- **Local**: select any compatible whisper.cpp model discovered by the app or choose one from disk.

## Build A Release App

Build a standalone macOS app bundle:

```sh
./scripts/build_app.sh
```

This creates:

```text
dist/GameChatTranslator.app
dist/GameChatTranslator-0.1.0.zip
```

If `models/ggml-base.bin` exists, the script bundles it into the app so first launch works without choosing a model. To ship without a bundled model:

```sh
INCLUDE_MODEL=none ./scripts/build_app.sh
```

To bundle another model:

```sh
INCLUDE_MODEL="$PWD/models/ggml-medium.bin" ./scripts/build_app.sh
```

The default local build is ad-hoc signed for testing. For public distribution you need an Apple Developer ID certificate:

```sh
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh
xcrun notarytool submit dist/GameChatTranslator-0.1.0.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/GameChatTranslator.app
ditto -c -k --keepParent dist/GameChatTranslator.app dist/GameChatTranslator-0.1.0-notarized.zip
```

Upload the notarized zip as a GitHub Release asset.

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
- Audio exists as in-process RAM buffers only and is not saved to disk.
- Groq Mode uploads short utterances for English translation; Local Mode does not send audio over the network.
- Model files are read from disk, but captured audio is not saved.
- Recognized text is printed to stdout.

## Known Limits

- The packaged app is unsigned/ad-hoc unless you build it with your own Developer ID identity.
- Game audio and voice chat are mixed together by Remote Play, so loud explosions/music can still hurt accuracy.
- Whisper translation is best with complete phrases. Extremely short chunks are faster but less accurate.
- `base` is the practical realtime starting point. `tiny` is faster but less accurate; `small` and larger models improve accuracy at the cost of latency.

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

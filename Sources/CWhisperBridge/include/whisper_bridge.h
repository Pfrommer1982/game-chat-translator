#ifndef WHISPER_BRIDGE_H
#define WHISPER_BRIDGE_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct WhisperBridge WhisperBridge;

typedef struct {
    const char * text;
    const char * language;
    float average_token_probability;
    int token_count;
} WhisperBridgeResult;

WhisperBridge * whisper_bridge_create(const char * model_path);
void whisper_bridge_free(WhisperBridge * bridge);
void whisper_bridge_set_language(WhisperBridge * bridge, const char * language);
void whisper_bridge_set_translate_to_english(WhisperBridge * bridge, bool enabled);
void whisper_bridge_set_realtime_mode(WhisperBridge * bridge, bool enabled);
void whisper_bridge_set_thread_count(WhisperBridge * bridge, int thread_count);

WhisperBridgeResult whisper_bridge_transcribe(
    WhisperBridge * bridge,
    const float * samples,
    int sample_count,
    int sample_rate
);

void whisper_bridge_result_free(WhisperBridgeResult result);

#ifdef __cplusplus
}
#endif

#endif

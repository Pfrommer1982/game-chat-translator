#include "whisper_bridge.h"

#include "whisper.h"

#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

struct WhisperBridge {
    whisper_context * ctx;
    std::string language;
    bool translate_to_english;
    bool realtime_mode;
    int thread_count;
    std::mutex mutex;
};

static void whisper_bridge_silent_log(enum ggml_log_level, const char *, void *) {
}

static char * copy_string(const std::string & value) {
    char * out = static_cast<char *>(std::malloc(value.size() + 1));
    if (!out) {
        return nullptr;
    }
    std::memcpy(out, value.c_str(), value.size() + 1);
    return out;
}

WhisperBridge * whisper_bridge_create(const char * model_path) {
    if (!model_path || std::strlen(model_path) == 0) {
        return nullptr;
    }

    whisper_log_set(whisper_bridge_silent_log, nullptr);

    whisper_context_params cparams = whisper_context_default_params();
    whisper_context * ctx = whisper_init_from_file_with_params(model_path, cparams);
    if (!ctx) {
        return nullptr;
    }

    WhisperBridge * bridge = new WhisperBridge;
    bridge->ctx = ctx;
    bridge->language = "auto";
    bridge->translate_to_english = false;
    bridge->realtime_mode = false;
    bridge->thread_count = 4;
    return bridge;
}

void whisper_bridge_free(WhisperBridge * bridge) {
    if (!bridge) {
        return;
    }

    if (bridge->ctx) {
        whisper_free(bridge->ctx);
    }
    delete bridge;
}

void whisper_bridge_set_language(WhisperBridge * bridge, const char * language) {
    if (!bridge) {
        return;
    }

    std::lock_guard<std::mutex> lock(bridge->mutex);
    bridge->language = (language && std::strlen(language) > 0) ? language : "auto";
}

void whisper_bridge_set_translate_to_english(WhisperBridge * bridge, bool enabled) {
    if (!bridge) {
        return;
    }

    std::lock_guard<std::mutex> lock(bridge->mutex);
    bridge->translate_to_english = enabled;
}

void whisper_bridge_set_realtime_mode(WhisperBridge * bridge, bool enabled) {
    if (!bridge) {
        return;
    }

    std::lock_guard<std::mutex> lock(bridge->mutex);
    bridge->realtime_mode = enabled;
}

void whisper_bridge_set_thread_count(WhisperBridge * bridge, int thread_count) {
    if (!bridge) {
        return;
    }

    std::lock_guard<std::mutex> lock(bridge->mutex);
    bridge->thread_count = thread_count > 0 ? thread_count : 4;
}

WhisperBridgeResult whisper_bridge_transcribe(
    WhisperBridge * bridge,
    const float * samples,
    int sample_count,
    int sample_rate
) {
    WhisperBridgeResult result = { nullptr, nullptr, 0.0f, 0.0f, 0 };
    if (!bridge || !bridge->ctx || !samples || sample_count <= 0 || sample_rate != 16000) {
        result.text = copy_string("");
        result.language = copy_string("");
        return result;
    }

    std::lock_guard<std::mutex> lock(bridge->mutex);

    const whisper_sampling_strategy strategy = bridge->realtime_mode
        ? WHISPER_SAMPLING_GREEDY
        : WHISPER_SAMPLING_BEAM_SEARCH;
    whisper_full_params params = whisper_full_default_params(strategy);
    params.print_realtime = false;
    params.print_progress = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = bridge->translate_to_english;
    params.no_context = bridge->translate_to_english || bridge->realtime_mode;
    params.single_segment = bridge->translate_to_english || bridge->realtime_mode;
    params.language = bridge->language == "auto" ? nullptr : bridge->language.c_str();
    params.detect_language = false;
    params.n_threads = bridge->thread_count;
    params.temperature = 0.0f;
    params.temperature_inc = 0.0f;
    params.no_speech_thold = 0.45f;
    params.logprob_thold = -0.6f;
    params.suppress_blank = true;
    params.suppress_nst = true;
    if (bridge->realtime_mode) {
        params.audio_ctx = 768;
        params.max_tokens = 24;
        params.max_len = 96;
        params.greedy.best_of = 1;
    } else {
        params.beam_search.beam_size = 5;
    }

    std::vector<float> pcm(samples, samples + sample_count);
    int rc = whisper_full(bridge->ctx, params, pcm.data(), static_cast<int>(pcm.size()));
    std::fill(pcm.begin(), pcm.end(), 0.0f);

    if (rc != 0) {
        result.text = copy_string("");
        result.language = copy_string("");
        return result;
    }

    std::string text;
    float token_probability_sum = 0.0f;
    int token_probability_count = 0;
    float no_speech_probability = 0.0f;
    const int segments = whisper_full_n_segments(bridge->ctx);
    for (int i = 0; i < segments; ++i) {
        no_speech_probability = std::max(
            no_speech_probability,
            whisper_full_get_segment_no_speech_prob(bridge->ctx, i)
        );
        const char * segment = whisper_full_get_segment_text(bridge->ctx, i);
        if (segment) {
            text += segment;
        }

        const int tokens = whisper_full_n_tokens(bridge->ctx, i);
        for (int j = 0; j < tokens; ++j) {
            token_probability_sum += whisper_full_get_token_p(bridge->ctx, i, j);
            token_probability_count += 1;
        }
    }

    std::string language;
    const int langId = whisper_full_lang_id(bridge->ctx);
    if (langId >= 0) {
        const char * lang = whisper_lang_str(langId);
        if (lang) {
            language = lang;
        }
    }

    result.text = copy_string(text);
    result.language = copy_string(language);
    result.token_count = token_probability_count;
    result.no_speech_probability = no_speech_probability;
    result.average_token_probability = token_probability_count > 0
        ? token_probability_sum / static_cast<float>(token_probability_count)
        : 0.0f;
    return result;
}

void whisper_bridge_result_free(WhisperBridgeResult result) {
    if (result.text) {
        std::free(const_cast<char *>(result.text));
    }
    if (result.language) {
        std::free(const_cast<char *>(result.language));
    }
}

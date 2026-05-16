#include "config.hpp"

#include <charconv>
#include <concepts>
#include <cstdlib>
#include <format>
#include <stdexcept>
#include <string>
#include <string_view>

namespace stt {

namespace {

template <std::integral Int>
Int parse_int_or_throw(std::string_view key, std::string_view raw) {
    Int value{};
    const auto* end = raw.data() + raw.size();
    const auto [ptr, ec] = std::from_chars(raw.data(), end, value);
    if (ec != std::errc{} || ptr != end) {
        throw std::runtime_error(std::format("invalid integer for {}: {}", key, raw));
    }
    return value;
}

template <std::integral Int>
Int with_default(const EnvLookup& env, std::string_view key, Int fallback) {
    if (auto raw = env(key); raw && !raw->empty()) {
        return parse_int_or_throw<Int>(key, *raw);
    }
    return fallback;
}

std::string with_default(const EnvLookup& env, std::string_view key, std::string fallback) {
    if (auto raw = env(key); raw && !raw->empty()) {
        return std::move(*raw);
    }
    return fallback;
}

// Env values for time durations are always milliseconds (FLUSH_INTERVAL_MS,
// INFERENCE_TIMEOUT_MS, …) — collapse the parse-as-int64-then-wrap pattern
// into one call instead of three.
std::chrono::milliseconds with_default_ms(const EnvLookup& env, std::string_view key,
                                          std::chrono::milliseconds fallback) {
    return std::chrono::milliseconds(with_default<std::int64_t>(env, key, fallback.count()));
}

}  // namespace

Config load_config(const EnvLookup& env) {
    Config config;
    config.port = with_default<std::uint16_t>(env, "PORT", config.port);
    config.inference_url = with_default(env, "INFERENCE_URL", config.inference_url);
    config.inference_timeout = with_default_ms(env, "INFERENCE_TIMEOUT_MS", config.inference_timeout);
    config.inference_http_clients = with_default(env, "INFERENCE_HTTP_CLIENTS", config.inference_http_clients);
    config.cpu_passes = with_default(env, "CPU_PASSES", config.cpu_passes);
    config.model_delay_ms = with_default(env, "MODEL_DELAY_MS", config.model_delay_ms);
    config.flush_interval = with_default_ms(env, "FLUSH_INTERVAL_MS", config.flush_interval);
    config.flush_phase_jitter = with_default_ms(env, "FLUSH_PHASE_JITTER_MS", config.flush_phase_jitter);
    config.worker_threads = with_default(env, "WORKER_THREADS", config.worker_threads);

    // A non-positive flush interval would spin `FlushTimerWheel::tick`'s
    // catch-up loop forever; reject at the config boundary.
    if (config.flush_interval.count() <= 0) {
        throw std::runtime_error(std::format("FLUSH_INTERVAL_MS must be positive, got {}",
                                             config.flush_interval.count()));
    }
    return config;
}

Config load_config_from_process_env() {
    return load_config([](std::string_view key) -> std::optional<std::string> {
        const auto key_str = std::string(key);
        if (const char* value = std::getenv(key_str.c_str())) {
            return std::string(value);
        }
        return std::nullopt;
    });
}

}  // namespace stt

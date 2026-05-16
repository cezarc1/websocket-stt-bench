#include "doctest/doctest.h"

#include <chrono>
#include <map>
#include <optional>
#include <string>
#include <string_view>

#include "config.hpp"

using namespace std::chrono_literals;

namespace {

// In-memory env lookup — far simpler than mutating the process environment
// and parallel-test-safe.
stt::EnvLookup with_env(std::map<std::string, std::string> entries) {
    return [entries = std::move(entries)](std::string_view key) -> std::optional<std::string> {
        if (auto it = entries.find(std::string(key)); it != entries.end()) {
            return it->second;
        }
        return std::nullopt;
    };
}

}  // namespace

TEST_CASE("defaults match the docker-compose env spec") {
    const auto config = stt::load_config(with_env({}));
    CHECK(config.port == 1500);
    CHECK(config.inference_url == "http://inference-server:9000");
    CHECK(config.inference_timeout == 2000ms);
    CHECK(config.inference_http_clients == 128);
    CHECK(config.cpu_passes == 4);
    CHECK(config.model_delay_ms == 75);
    CHECK(config.flush_interval == 1000ms);
    CHECK(config.flush_phase_jitter == 0ms);
    CHECK(config.worker_threads == 1);
}

TEST_CASE("env vars override defaults") {
    const auto config = stt::load_config(with_env({
        {"PORT", "2500"},
        {"INFERENCE_URL", "http://example:9001"},
        {"INFERENCE_TIMEOUT_MS", "500"},
        {"INFERENCE_HTTP_CLIENTS", "8"},
        {"CPU_PASSES", "2"},
        {"MODEL_DELAY_MS", "42"},
        {"FLUSH_INTERVAL_MS", "250"},
        {"FLUSH_PHASE_JITTER_MS", "100"},
        {"WORKER_THREADS", "4"},
    }));
    CHECK(config.port == 2500);
    CHECK(config.inference_url == "http://example:9001");
    CHECK(config.inference_timeout == 500ms);
    CHECK(config.inference_http_clients == 8);
    CHECK(config.cpu_passes == 2);
    CHECK(config.model_delay_ms == 42);
    CHECK(config.flush_interval == 250ms);
    CHECK(config.flush_phase_jitter == 100ms);
    CHECK(config.worker_threads == 4);
}

TEST_CASE("unparseable integer is an error") {
    CHECK_THROWS_AS(stt::load_config(with_env({{"PORT", "twenty-five-hundred"}})), std::runtime_error);
}

TEST_CASE("empty value falls back to default") {
    // An env var defined with an empty value (e.g. `FOO=`) is a common shape
    // in docker-compose; we treat that as "not set" so the gateway picks the
    // default instead of trying to parse the empty string as a number.
    const auto config = stt::load_config(with_env({{"CPU_PASSES", ""}}));
    CHECK(config.cpu_passes == 4);
}

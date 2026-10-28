#pragma once

#include <chrono>
#include <cstddef>
#include <cstdint>
#include <functional>
#include <optional>
#include <string>
#include <string_view>

namespace stt {

inline constexpr std::size_t FRAME_BYTES = 640;
inline constexpr std::string_view RUNTIME_NAME = "cpp23-uwebsockets";
// uWS limit on one WebSocket message. Anything larger is `forceClose`d by uWS
// itself (TCP drop, no Close frame), so it must sit well above FRAME_BYTES for
// oversized frames to reach Session::on_binary and get the contract's 1003.
// uWS only buffers a message when it spans TCP reads or is fragmented, so this
// costs nothing for normal 640-byte traffic; it is the per-connection cap on
// what a misbehaving client can make us buffer before the 1003.
inline constexpr unsigned int MAX_WS_MESSAGE_BYTES = 1024 * 1024;
static_assert(MAX_WS_MESSAGE_BYTES > 64 * 1024, "must admit the conformance oversized frame");

inline constexpr int CLOSE_PROTOCOL_ERROR = 1002;
inline constexpr int CLOSE_UNSUPPORTED_DATA = 1003;
inline constexpr std::string_view REASON_NEED_START = "first message must be start";
inline constexpr std::string_view REASON_TEXT_AFTER_START =
    "expected binary PCM frames after start";
inline constexpr std::string_view REASON_BAD_FRAME_SIZE = "expected 640 byte PCM frame";

struct Config {
    std::uint16_t port = 1500;
    std::string inference_url = "http://inference-server:9000";
    std::chrono::milliseconds inference_timeout{2000};
    int inference_http_clients = 128;
    int cpu_passes = 4;
    std::int64_t model_delay_ms = 75;
    std::chrono::milliseconds flush_interval{1000};
    std::chrono::milliseconds flush_phase_jitter{0};
    int worker_threads = 1;
};

using EnvLookup = std::function<std::optional<std::string>(std::string_view)>;

// `[[nodiscard]]` is omitted intentionally: doctest's `CHECK_THROWS_AS` macro
// drops the result without a `(void)` cast, which trips `-Wunused-result`
// when the function under test is nodiscard. The factory shape is obvious
// enough that callers won't accidentally drop the result.
Config load_config(const EnvLookup& env);

Config load_config_from_process_env();

}  // namespace stt

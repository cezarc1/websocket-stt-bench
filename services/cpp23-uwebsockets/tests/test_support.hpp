#pragma once

#include <array>
#include <chrono>
#include <cstddef>
#include <functional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "config.hpp"
#include "inference.hpp"
#include "protocol.hpp"
#include "session.hpp"

namespace stt::test_support {

// Records every outbound payload + close in a vector so test bodies can assert
// directly on the wire shape.
class RecordingSink final : public OutboundSink {
public:
    void send(std::string_view payload) override { sent.emplace_back(payload); }
    void close_with(int code, std::string_view reason) override {
        close_code = code;
        close_reason = reason;
    }
    void mark_closed() noexcept override { marked_closed = true; }
    std::vector<std::string> sent;
    bool marked_closed = false;
    int close_code = 0;
    std::string close_reason;
};

// Captures every inference request without performing any work — tests pull
// the captured callback and invoke it manually, simulating either a
// successful response or a classified failure.
class CapturingInference final : public InferenceClient {
public:
    void infer_async(std::vector<std::byte> body, int cpu_passes,
                     std::function<void(InferenceResult)> on_complete) override {
        requests.push_back(Request{
            .body = std::move(body),
            .cpu_passes = cpu_passes,
            .callback = std::move(on_complete),
        });
    }
    struct Request {
        std::vector<std::byte> body;
        int cpu_passes;
        std::function<void(InferenceResult)> callback;
    };
    std::vector<Request> requests;
};

// In production the Scheduler bounces tasks onto the owning uWS loop. Tests
// don't have a loop, so we run inline — preserves call ordering and lets the
// callback observe state as it was at submission time.
class InlineScheduler final : public Scheduler {
public:
    void post(std::function<void()> task) override { task(); }
};

// All other fields use `Config{}` defaults.
inline Config base_config() { return Config{.inference_url = "http://stub"}; }

inline std::array<std::byte, FRAME_BYTES> frame_of(unsigned char fill) {
    std::array<std::byte, FRAME_BYTES> bytes{};
    bytes.fill(static_cast<std::byte>(fill));
    return bytes;
}

inline std::span<const std::byte> as_span(const std::array<std::byte, FRAME_BYTES>& frame) noexcept {
    return {frame.data(), frame.size()};
}

inline std::span<const std::byte> as_span(const std::vector<std::byte>& frame) noexcept {
    return {frame.data(), frame.size()};
}

struct SessionFixture {
    Config config = base_config();
    CapturingInference inference;
    RecordingSink sink;
    std::shared_ptr<InlineScheduler> scheduler = std::make_shared<InlineScheduler>();
    // Non-owning alias: the Session takes the sink by shared_ptr now, but
    // the fixture still owns `sink` by value so tests assert on it directly.
    std::shared_ptr<Session> session = std::make_shared<Session>(
        config, inference, std::shared_ptr<OutboundSink>(std::shared_ptr<void>{}, &sink),
        scheduler);
};

}  // namespace stt::test_support

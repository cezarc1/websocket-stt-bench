#pragma once

#include <array>
#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <vector>

#include "config.hpp"
#include "inference.hpp"
#include "protocol.hpp"

namespace stt {

struct Frame {
    std::uint64_t seq;
    std::array<std::byte, FRAME_BYTES> payload;
    std::chrono::steady_clock::time_point received_at;
};

// Per-flush context captured at flush time; shared by success and error paths
// via the inference callback.
struct BatchContext {
    std::uint64_t oldest_seq;
    std::uint64_t newest_seq;
    std::uint64_t frames;
    std::uint64_t body_bytes;
    double flush_lateness_ms;
    std::chrono::steady_clock::time_point started_at;
    std::chrono::steady_clock::time_point oldest_received_at;
    std::chrono::steady_clock::time_point newest_received_at;
};

// What the WebSocket side of the world looks like to the Session. Production
// wires this to `uWS::WebSocket::send` / `uWS::WebSocket::end`; tests use an
// in-memory recorder.
class OutboundSink {
public:
    OutboundSink() = default;
    OutboundSink(const OutboundSink&) = delete;
    OutboundSink& operator=(const OutboundSink&) = delete;
    OutboundSink(OutboundSink&&) = delete;
    OutboundSink& operator=(OutboundSink&&) = delete;
    virtual ~OutboundSink() = default;

    virtual void send(std::string_view payload) = 0;
    virtual void close_with(int code, std::string_view reason) = 0;
};

// Schedules a task back onto the Session's owning event loop. Production wraps
// `uWS::Loop::defer`; tests run the task inline. Implementations are
// non-copyable + non-movable so call sites can stash a stable reference.
class Scheduler {
public:
    Scheduler() = default;
    Scheduler(const Scheduler&) = delete;
    Scheduler& operator=(const Scheduler&) = delete;
    Scheduler(Scheduler&&) = delete;
    Scheduler& operator=(Scheduler&&) = delete;
    virtual ~Scheduler() = default;

    // Note: `std::function` rather than `std::move_only_function` because
    // toolchains_llvm 1.7.0's Linux sysroot picks up a libstdc++ that doesn't
    // reliably expose `<move_only_function>` even at -std=c++23. The captures
    // we actually use (weak_ptr, BatchContext, raw pointer, expected) are all
    // copyable, so move-only isn't load-bearing here.
    virtual void post(std::function<void()> task) = 0;
};

// Per-connection state machine. Single-threaded relative to its owning event
// loop — every public method must be called on that loop's thread.
class Session : public std::enable_shared_from_this<Session> {
public:
    // Scheduler by `shared_ptr` so an in-flight inference callback can
    // keep it alive across Session destruction.
    Session(const Config& config, InferenceClient& inference, OutboundSink& sink,
            std::shared_ptr<Scheduler> scheduler);

    void on_text(std::string_view text);
    void on_binary(std::span<const std::byte> payload);
    // `now` is passed in (not read from steady_clock::now) so tests can drive
    // a virtual clock without sleeping.
    void on_flush_tick(std::chrono::steady_clock::time_point now);

    // Direct injection paths used by `session_test` to simulate inference
    // completion without spinning up libcurl.
    void on_inference_succeeded(InferResponse infer, const BatchContext& ctx);
    void on_inference_failed(InferenceFailure err, const BatchContext& ctx);

    bool started() const noexcept { return state_ == State::Started; }
    bool closed() const noexcept { return state_ == State::Closed; }
    bool inflight() const noexcept { return inflight_; }
    std::size_t buffer_size() const noexcept { return buffer_.size(); }
    std::uint64_t dropped_frames() const noexcept { return dropped_frames_; }
    std::optional<std::chrono::steady_clock::time_point> expected_next_flush() const noexcept {
        return expected_next_flush_;
    }
    void set_expected_next_flush(std::chrono::steady_clock::time_point when) noexcept {
        expected_next_flush_ = when;
    }

private:
    // Connection-level state machine. `inflight_` is a separate flush-level
    // flag because it can flip true/false within a `Started` session.
    enum class State : std::uint8_t { Pending, Started, Closed };

    void fail_protocol(int code, std::string_view reason);
    void submit_inference(const BatchContext& ctx, std::vector<std::byte> body);

    const Config& config_;
    InferenceClient& inference_;
    OutboundSink& sink_;
    std::shared_ptr<Scheduler> scheduler_;

    State state_ = State::Pending;
    bool inflight_ = false;
    std::uint64_t seq_ = 0;
    std::uint64_t dropped_frames_ = 0;
    std::vector<Frame> buffer_;
    std::optional<std::chrono::steady_clock::time_point> expected_next_flush_;

    // Scratch buffers reused across flushes. Per-session ownership keeps each
    // buffer warm at the typical batch size (50 frames of PCM, ~250 B of JSON).
    std::vector<std::byte> body_scratch_;
    std::string json_scratch_;
};

}  // namespace stt

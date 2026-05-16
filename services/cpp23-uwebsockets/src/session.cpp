#include "session.hpp"

#include <cstring>
#include <string>
#include <utility>

#include <glaze/glaze.hpp>

namespace stt {

namespace {

double elapsed_ms(std::chrono::steady_clock::time_point now,
                  std::chrono::steady_clock::time_point earlier) {
    using namespace std::chrono;
    const auto delta = now > earlier ? now - earlier : steady_clock::duration::zero();
    return duration<double, std::milli>(delta).count();
}

}  // namespace

Session::Session(const Config& config, InferenceClient& inference, OutboundSink& sink,
                 std::shared_ptr<Scheduler> scheduler)
    : config_(config), inference_(inference), sink_(sink), scheduler_(std::move(scheduler)) {
    // Pre-size to the typical batch (50 frames at 20 ms cadence + headroom).
    // Without this, the first 50 push_backs each trigger a vector realloc.
    buffer_.reserve(64);
}

void Session::fail_protocol(int code, std::string_view reason) {
    state_ = State::Closed;
    sink_.close_with(code, reason);
}

void Session::on_text(std::string_view text) {
    if (state_ == State::Closed) {
        return;
    }
    if (state_ == State::Started) {
        fail_protocol(CLOSE_PROTOCOL_ERROR, REASON_TEXT_AFTER_START);
        return;
    }
    StartMessage parsed{};
    if (auto err = glz::read<STRICT_JSON>(parsed, text); err || parsed.type != "start") {
        fail_protocol(CLOSE_PROTOCOL_ERROR, REASON_NEED_START);
        return;
    }
    state_ = State::Started;
}

void Session::on_binary(std::span<const std::byte> payload) {
    if (state_ == State::Closed) {
        return;
    }
    if (state_ == State::Pending) {
        fail_protocol(CLOSE_PROTOCOL_ERROR, REASON_NEED_START);
        return;
    }
    if (payload.size() != FRAME_BYTES) {
        fail_protocol(CLOSE_UNSUPPORTED_DATA, REASON_BAD_FRAME_SIZE);
        return;
    }
    if (buffer_.size() >= MAX_BUFFERED_FRAMES) {
        buffer_.erase(buffer_.begin());
        ++dropped_frames_;
    }
    // emplace_back() default-constructs Frame, leaving `payload` indeterminate;
    // memcpy then fills it. Saves the 640-byte zero-fill from designated-init
    // (≈96 MB/s of dead writes at the saturated 150k-frame/s rate).
    Frame& frame = buffer_.emplace_back();
    frame.seq = ++seq_;
    std::memcpy(frame.payload.data(), payload.data(), FRAME_BYTES);
    frame.received_at = std::chrono::steady_clock::now();
}

void Session::on_flush_tick(std::chrono::steady_clock::time_point now) {
    if (state_ != State::Started) {
        return;
    }
    double lateness = 0.0;
    if (expected_next_flush_) {
        lateness = elapsed_ms(now, *expected_next_flush_);
        *expected_next_flush_ += config_.flush_interval;
    }

    if (inflight_ || buffer_.empty()) {
        return;
    }
    inflight_ = true;

    // Build the body in the scratch vector — reused across flushes so capacity
    // converges at ~50 frames of PCM (~32 KiB) and stays out of the allocator.
    body_scratch_.clear();
    body_scratch_.reserve(buffer_.size() * FRAME_BYTES);
    for (const auto& frame : buffer_) {
        body_scratch_.append_range(frame.payload);
    }

    const auto& oldest = buffer_.front();
    const auto& newest = buffer_.back();
    const BatchContext ctx{
        .oldest_seq = oldest.seq,
        .newest_seq = newest.seq,
        .frames = buffer_.size(),
        .body_bytes = body_scratch_.size(),
        .flush_lateness_ms = lateness,
        .started_at = now,
        .oldest_received_at = oldest.received_at,
        .newest_received_at = newest.received_at,
    };

    auto body = std::move(body_scratch_);
    buffer_.clear();

    submit_inference(ctx, std::move(body));
}

void Session::submit_inference(const BatchContext& ctx, std::vector<std::byte> body) {
    inference_.infer_async(
        std::move(body), config_.cpu_passes,
        // `sched` is a shared_ptr copy so the post path survives Session
        // destruction between submission and completion.
        [weak = weak_from_this(), ctx, sched = scheduler_](InferenceResult result) {
            sched->post([weak, ctx, result = std::move(result)]() mutable {
                if (auto self = weak.lock()) {
                    if (result) {
                        self->on_inference_succeeded(std::move(*result), ctx);
                    } else {
                        self->on_inference_failed(std::move(result.error()), ctx);
                    }
                }
            });
        });
}

void Session::on_inference_succeeded(InferResponse infer, const BatchContext& ctx) {
    inflight_ = false;
    if (state_ == State::Closed) {
        return;
    }
    const PartialContext partial_ctx{
        .oldest_frame_seq = ctx.oldest_seq,
        .newest_frame_seq = ctx.newest_seq,
        .frames = ctx.frames,
        .flush_lateness_ms = ctx.flush_lateness_ms,
        .cpu_passes = static_cast<std::uint32_t>(config_.cpu_passes),
        .model_delay_ms = static_cast<std::uint64_t>(config_.model_delay_ms),
    };
    const PartialMessage partial = partial_from(infer, partial_ctx);
    json_scratch_.clear();
    if (auto err = glz::write<WIRE_JSON>(partial, json_scratch_); err) {
        return;
    }
    sink_.send(json_scratch_);
}

void Session::on_inference_failed(InferenceFailure err, const BatchContext& ctx) {
    inflight_ = false;
    if (state_ == State::Closed) {
        return;
    }
    const auto now = std::chrono::steady_clock::now();
    ErrorMessage msg{
        .type = ERROR_TYPE,
        .stage = to_wire(err.stage),
        .kind = to_wire(err.kind),
        .message = std::move(err.detail),
        .oldest_frame_seq = ctx.oldest_seq,
        .newest_frame_seq = ctx.newest_seq,
        .frames = ctx.frames,
        .audio_bytes = ctx.body_bytes,
        .oldest_age_ms = elapsed_ms(now, ctx.oldest_received_at),
        .newest_age_ms = elapsed_ms(now, ctx.newest_received_at),
        .flush_lateness_ms = ctx.flush_lateness_ms,
        .inference_elapsed_ms = elapsed_ms(now, ctx.started_at),
        .inflight_gateway_batches = 1,
        .gateway_buffer_frames = buffer_.size(),
        .inference_status = err.status,
        .retryable = err.retryable,
    };
    json_scratch_.clear();
    if (auto write_err = glz::write<WIRE_JSON>(msg, json_scratch_); write_err) {
        return;
    }
    sink_.send(json_scratch_);
}

}  // namespace stt

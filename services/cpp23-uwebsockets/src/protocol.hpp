#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include <glaze/glaze.hpp>

namespace stt {

inline constexpr std::string_view PARTIAL_TYPE = "partial";
inline constexpr std::string_view ERROR_TYPE = "error";

// Shared Glaze read options — every decoder in this gateway rejects unknown
// fields, matching the strict Pydantic/serde/circe setups in sibling gateways.
inline constexpr glz::opts STRICT_JSON{.error_on_unknown_keys = true};
inline constexpr glz::opts WIRE_JSON{.error_on_unknown_keys = true, .skip_null_members = false};

enum class ErrorStage : std::uint8_t {
    WebsocketReceive,
    BatchFlush,
    InferenceRequest,
    InferenceResponseParse,
    WebsocketSend,
};

// Inline + constexpr so the switch folds at call sites where the enum is known
// at compile time (every call site in this gateway, today).
[[nodiscard]] constexpr std::string_view to_wire(ErrorStage stage) noexcept {
    switch (stage) {
        case ErrorStage::WebsocketReceive: return "websocket_receive";
        case ErrorStage::BatchFlush: return "batch_flush";
        case ErrorStage::InferenceRequest: return "inference_request";
        case ErrorStage::InferenceResponseParse: return "inference_response_parse";
        case ErrorStage::WebsocketSend: return "websocket_send";
    }
    std::unreachable();
}

enum class ErrorKind : std::uint8_t {
    Timeout,
    PoolTimeout,
    Http5xx,
    Http429,
    ConnectionReset,
    ParseError,
    SendError,
};

[[nodiscard]] constexpr std::string_view to_wire(ErrorKind kind) noexcept {
    switch (kind) {
        case ErrorKind::Timeout: return "timeout";
        case ErrorKind::PoolTimeout: return "pool_timeout";
        case ErrorKind::Http5xx: return "http_5xx";
        case ErrorKind::Http429: return "http_429";
        case ErrorKind::ConnectionReset: return "connection_reset";
        case ErrorKind::ParseError: return "parse_error";
        case ErrorKind::SendError: return "send_error";
    }
    std::unreachable();
}

// Inbound: `{"type":"start"}`. Strict — any other field rejects the connection.
struct StartMessage {
    std::string type;
};

// Inbound: deserialised from the inference server's response JSON. Field
// widths match the inference server's wire types (checksum is u32 from
// FNV-1a; everything else u64).
struct InferResponse {
    double rms = 0.0;
    std::uint64_t zero_crossings = 0;
    std::uint32_t checksum = 0;
    std::uint64_t samples = 0;
    std::string transcript;
    std::uint64_t audio_bytes = 0;
};

// Outbound: one of these is sent per flush on success. Field widths match
// the conformance harness's expected schema in `loadgen/rust/src/protocol.rs`.
struct PartialMessage {
    std::string_view type = PARTIAL_TYPE;
    std::uint64_t oldest_frame_seq = 0;
    std::uint64_t newest_frame_seq = 0;
    std::uint64_t frames = 0;
    double rms = 0.0;
    std::uint64_t zero_crossings = 0;
    std::uint32_t checksum = 0;
    std::uint64_t samples = 0;
    std::string transcript;
    std::uint64_t audio_bytes = 0;
    std::uint32_t cpu_passes = 0;
    std::uint64_t model_delay_ms = 0;
    double flush_lateness_ms = 0.0;
    std::uint64_t inflight_model_jobs = 0;
};

// Outbound: one of these is sent per flush on failure.
struct ErrorMessage {
    std::string_view type = ERROR_TYPE;
    std::string_view stage;
    std::string_view kind;
    std::string message;
    std::uint64_t oldest_frame_seq = 0;
    std::uint64_t newest_frame_seq = 0;
    std::uint64_t frames = 0;
    std::uint64_t audio_bytes = 0;
    double oldest_age_ms = 0.0;
    double newest_age_ms = 0.0;
    double flush_lateness_ms = 0.0;
    std::optional<double> inference_elapsed_ms;
    std::uint64_t inflight_gateway_batches = 1;
    std::uint64_t gateway_buffer_frames = 0;
    std::optional<std::uint16_t> inference_status;
    bool retryable = false;
};

// Build a `PartialMessage` from an `InferResponse` plus per-flush context.
struct PartialContext {
    std::uint64_t oldest_frame_seq;
    std::uint64_t newest_frame_seq;
    std::uint64_t frames;
    double flush_lateness_ms;
    std::uint32_t cpu_passes;
    std::uint64_t model_delay_ms;
};

[[nodiscard]] PartialMessage partial_from(const InferResponse& infer, const PartialContext& ctx);

}  // namespace stt

// Field order in each `object(...)` block below controls wire output order and
// must match the Rust/Go/Java/Scala gateways exactly — the load generator
// expects identical shape from every runtime.
template <>
struct glz::meta<stt::StartMessage> {
    using T = stt::StartMessage;
    static constexpr auto value = object("type", &T::type);
};

template <>
struct glz::meta<stt::InferResponse> {
    using T = stt::InferResponse;
    static constexpr auto value = object(
        "rms", &T::rms,
        "zero_crossings", &T::zero_crossings,
        "checksum", &T::checksum,
        "samples", &T::samples,
        "transcript", &T::transcript,
        "audio_bytes", &T::audio_bytes);
};

template <>
struct glz::meta<stt::PartialMessage> {
    using T = stt::PartialMessage;
    static constexpr auto value = object(
        "type", &T::type,
        "oldest_frame_seq", &T::oldest_frame_seq,
        "newest_frame_seq", &T::newest_frame_seq,
        "frames", &T::frames,
        "rms", &T::rms,
        "zero_crossings", &T::zero_crossings,
        "checksum", &T::checksum,
        "samples", &T::samples,
        "transcript", &T::transcript,
        "audio_bytes", &T::audio_bytes,
        "cpu_passes", &T::cpu_passes,
        "model_delay_ms", &T::model_delay_ms,
        "flush_lateness_ms", &T::flush_lateness_ms,
        "inflight_model_jobs", &T::inflight_model_jobs);
};

template <>
struct glz::meta<stt::ErrorMessage> {
    using T = stt::ErrorMessage;
    static constexpr auto value = object(
        "type", &T::type,
        "stage", &T::stage,
        "kind", &T::kind,
        "message", &T::message,
        "oldest_frame_seq", &T::oldest_frame_seq,
        "newest_frame_seq", &T::newest_frame_seq,
        "frames", &T::frames,
        "audio_bytes", &T::audio_bytes,
        "oldest_age_ms", &T::oldest_age_ms,
        "newest_age_ms", &T::newest_age_ms,
        "flush_lateness_ms", &T::flush_lateness_ms,
        "inference_elapsed_ms", &T::inference_elapsed_ms,
        "inflight_gateway_batches", &T::inflight_gateway_batches,
        "gateway_buffer_frames", &T::gateway_buffer_frames,
        "inference_status", &T::inference_status,
        "retryable", &T::retryable);
};

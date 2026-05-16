#include "doctest/doctest.h"

#include <string>

#include <glaze/glaze.hpp>

#include "protocol.hpp"

TEST_CASE("StartMessage accepts the canonical body") {
    stt::StartMessage parsed{};
    const auto err = glz::read<stt::STRICT_JSON>(parsed, std::string("{\"type\":\"start\"}"));
    CHECK_FALSE(err);
    CHECK(parsed.type == "start");
}

TEST_CASE("StartMessage rejects unknown fields under strict opts") {
    stt::StartMessage parsed{};
    const auto err = glz::read<stt::STRICT_JSON>(parsed, std::string("{\"type\":\"start\",\"sneaky\":1}"));
    CHECK(static_cast<bool>(err));
}

TEST_CASE("InferResponse round-trips") {
    const std::string json =
        R"({"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"hello","audio_bytes":1280})";
    stt::InferResponse parsed{};
    const auto err = glz::read<stt::STRICT_JSON>(parsed, json);
    CHECK_FALSE(err);
    CHECK(parsed.rms == doctest::Approx(1.5));
    CHECK(parsed.zero_crossings == 2);
    CHECK(parsed.checksum == 3);
    CHECK(parsed.samples == 1280);
    CHECK(parsed.transcript == "hello");
    CHECK(parsed.audio_bytes == 1280);
}

TEST_CASE("InferResponse rejects unknown fields under strict opts") {
    const std::string json =
        R"({"rms":0,"zero_crossings":0,"checksum":0,"samples":0,"transcript":"","audio_bytes":0,"extra":1})";
    stt::InferResponse parsed{};
    const auto err = glz::read<stt::STRICT_JSON>(parsed, json);
    CHECK(static_cast<bool>(err));
}

TEST_CASE("PartialMessage encodes with stable wire shape") {
    const stt::PartialContext ctx{
        .oldest_frame_seq = 1,
        .newest_frame_seq = 5,
        .frames = 5,
        .flush_lateness_ms = 0.0,
        .cpu_passes = 4,
        .model_delay_ms = 75,
    };
    const stt::InferResponse infer{
        .rms = 1.5,
        .zero_crossings = 2,
        .checksum = 3,
        .samples = 1280,
        .transcript = "ok",
        .audio_bytes = 1280,
    };
    const auto partial = stt::partial_from(infer, ctx);
    std::string out;
    const auto err = glz::write<stt::WIRE_JSON>(partial, out);
    CHECK_FALSE(err);

    // We don't assert on exact whitespace — that's Glaze's choice — but the
    // type literal and the inflight_model_jobs zero must both be present
    // because they're the wire-shape contract with the load generator.
    CHECK(out.contains("\"type\":\"partial\""));
    CHECK(out.contains("\"oldest_frame_seq\":1"));
    CHECK(out.contains("\"newest_frame_seq\":5"));
    CHECK(out.contains("\"inflight_model_jobs\":0"));
}

TEST_CASE("ErrorMessage preserves null for absent optionals") {
    const stt::ErrorMessage msg{
        .type = stt::ERROR_TYPE,
        .stage = stt::to_wire(stt::ErrorStage::InferenceRequest),
        .kind = stt::to_wire(stt::ErrorKind::Timeout),
        .message = "timed out",
        .oldest_frame_seq = 1,
        .newest_frame_seq = 1,
        .frames = 1,
        .audio_bytes = 640,
        .oldest_age_ms = 1.0,
        .newest_age_ms = 1.0,
        .flush_lateness_ms = 0.0,
        .inference_elapsed_ms = std::nullopt,
        .inflight_gateway_batches = 1,
        .gateway_buffer_frames = 0,
        .inference_status = std::nullopt,
        .retryable = true,
    };
    std::string out;
    const auto err = glz::write<stt::WIRE_JSON>(msg, out);
    CHECK_FALSE(err);
    // The other gateways serialise absent optionals as `null` rather than
    // dropping the key entirely — the loadgen and analyzer rely on that.
    CHECK(out.contains("\"inference_elapsed_ms\":null"));
    CHECK(out.contains("\"inference_status\":null"));
    CHECK(out.contains("\"retryable\":true"));
    CHECK(out.contains("\"kind\":\"timeout\""));
}

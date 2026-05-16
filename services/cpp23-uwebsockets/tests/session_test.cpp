#include "doctest/doctest.h"

#include <chrono>
#include <cstddef>
#include <expected>
#include <optional>
#include <string>
#include <vector>

#include "inference.hpp"
#include "protocol.hpp"
#include "session.hpp"
#include "test_support.hpp"

using namespace std::chrono_literals;
using stt::test_support::as_span;
using stt::test_support::frame_of;
using stt::test_support::SessionFixture;

TEST_CASE("flush builds a partial and clears the buffer") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    CHECK(fx.session->started());

    fx.session->on_binary(as_span(frame_of(0x01)));
    CHECK(fx.session->buffer_size() == 1);

    const auto now = std::chrono::steady_clock::now();
    fx.session->set_expected_next_flush(now);
    fx.session->on_flush_tick(now);

    REQUIRE(fx.inference.requests.size() == 1);
    CHECK(fx.session->buffer_size() == 0);
    CHECK(fx.session->inflight());

    fx.inference.requests.front().callback(stt::InferResponse{
        .rms = 1.5,
        .zero_crossings = 2,
        .checksum = 3,
        .samples = 1280,
        .transcript = "hi",
        .audio_bytes = 1280,
    });

    CHECK_FALSE(fx.session->inflight());
    REQUIRE(fx.sink.sent.size() == 1);
    const auto& payload = fx.sink.sent.front();
    CHECK(payload.contains("\"type\":\"partial\""));
    CHECK(payload.contains("\"oldest_frame_seq\":1"));
    CHECK(payload.contains("\"newest_frame_seq\":1"));
    CHECK(payload.contains("\"frames\":1"));
}

TEST_CASE("second flush while inflight is a no-op") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    fx.session->on_binary(as_span(frame_of(0x01)));

    const auto now = std::chrono::steady_clock::now();
    fx.session->set_expected_next_flush(now);
    fx.session->on_flush_tick(now);
    CHECK(fx.session->inflight());
    CHECK(fx.inference.requests.size() == 1);

    fx.session->on_binary(as_span(frame_of(0x02)));
    fx.session->on_flush_tick(now + 1000ms);
    CHECK(fx.inference.requests.size() == 1);
    CHECK(fx.session->buffer_size() == 1);
}

TEST_CASE("buffer is bounded while inference is inflight") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    for (std::size_t i = 0; i < stt::MAX_BUFFERED_FRAMES + 20; ++i) {
        fx.session->on_binary(as_span(frame_of(static_cast<unsigned char>(i))));
    }

    CHECK(fx.session->buffer_size() == stt::MAX_BUFFERED_FRAMES);
    CHECK(fx.session->dropped_frames() == 20);
}

TEST_CASE("inference failure surfaces as an error envelope on the wire") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    fx.session->on_binary(as_span(frame_of(0x01)));

    const auto now = std::chrono::steady_clock::now();
    fx.session->set_expected_next_flush(now);
    fx.session->on_flush_tick(now);

    REQUIRE(fx.inference.requests.size() == 1);
    fx.inference.requests.front().callback(std::unexpected(stt::InferenceFailure{
        .stage = stt::ErrorStage::InferenceRequest,
        .kind = stt::ErrorKind::Timeout,
        .detail = "timed out",
        .status = std::nullopt,
        .retryable = true,
    }));

    REQUIRE(fx.sink.sent.size() == 1);
    const auto& payload = fx.sink.sent.front();
    CHECK(payload.contains("\"type\":\"error\""));
    CHECK(payload.contains("\"kind\":\"timeout\""));
    CHECK(payload.contains("\"retryable\":true"));
    CHECK_FALSE(fx.session->inflight());
}

TEST_CASE("text after start closes with 1002") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    fx.session->on_text(R"({"type":"start"})");

    CHECK(fx.sink.close_code == stt::CLOSE_PROTOCOL_ERROR);
    CHECK(fx.sink.close_reason == stt::REASON_TEXT_AFTER_START);
}

TEST_CASE("non-640-byte binary closes with 1003") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    const std::vector<std::byte> tiny(123);
    fx.session->on_binary(as_span(tiny));

    CHECK(fx.sink.close_code == stt::CLOSE_UNSUPPORTED_DATA);
    CHECK(fx.sink.close_reason == stt::REASON_BAD_FRAME_SIZE);
}

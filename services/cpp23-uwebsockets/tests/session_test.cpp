// cert-err33-c: on macOS arm64 doctest's CHECK expands DOCTEST_BREAK_INTO_DEBUGGER
// to an unchecked `raise(SIGTRAP)`; the hit is in the macro, not in this file.
// NOLINTBEGIN(cert-err33-c)
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

    fx.inference.requests.front().complete(stt::InferResponse{
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
    const SessionFixture fx;

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

// Frames that arrive while a request is in flight are never trimmed: the next
// flush covers exactly `prev_newest+1..=newest`, every frame once, in order
// (the harness's continuity + exact-stub checks).
TEST_CASE("backlog behind an inflight request is flushed whole and in order") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    fx.session->on_binary(as_span(frame_of(0)));
    auto now = std::chrono::steady_clock::now();
    fx.session->set_expected_next_flush(now);
    fx.session->on_flush_tick(now);
    REQUIRE(fx.inference.requests.size() == 1);

    // Several seconds of audio pile up while inference is slow.
    constexpr std::size_t backlog = 400;
    for (std::size_t i = 1; i <= backlog; ++i) {
        fx.session->on_binary(as_span(frame_of(static_cast<unsigned char>(i))));
    }
    CHECK(fx.session->buffer_size() == backlog);
    now += 1000ms;
    fx.session->on_flush_tick(now);  // still in flight: no-op
    CHECK(fx.inference.requests.size() == 1);

    fx.inference.requests.front().complete(stt::InferResponse{.transcript = "a"});
    now += 1000ms;
    fx.session->on_flush_tick(now);
    REQUIRE(fx.inference.requests.size() == 2);
    const auto& body = fx.inference.requests.back().body;
    REQUIRE(body.size() == backlog * stt::FRAME_BYTES);
    for (std::size_t f = 0; f < backlog; ++f) {
        const auto expected = std::byte{static_cast<unsigned char>(f + 1)};
        CHECK(body[f * stt::FRAME_BYTES] == expected);
        CHECK(body[((f + 1) * stt::FRAME_BYTES) - 1] == expected);
    }

    fx.inference.requests.back().complete(stt::InferResponse{.transcript = "b"});
    REQUIRE(fx.sink.sent.size() == 2);
    CHECK(fx.sink.sent[0].contains(R"("oldest_frame_seq":1,"newest_frame_seq":1,"frames":1,)"));
    CHECK(fx.sink.sent[1].contains(R"("oldest_frame_seq":2,"newest_frame_seq":401,"frames":400,)"));
}

// Error frames consume their batch; the next partial starts right after it.
TEST_CASE("error frame range tiles with the following partial") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    for (unsigned char i = 0; i < 3; ++i) {
        fx.session->on_binary(as_span(frame_of(i)));
    }
    auto now = std::chrono::steady_clock::now();
    fx.session->set_expected_next_flush(now);
    fx.session->on_flush_tick(now);
    fx.session->on_binary(as_span(frame_of(9)));
    fx.inference.requests.front().complete(std::unexpected(stt::InferenceFailure{
        .stage = stt::ErrorStage::InferenceRequest,
        .kind = stt::ErrorKind::Http5xx,
        .detail = "boom",
        .status = 503,
        .retryable = true,
    }));
    now += 1000ms;
    fx.session->on_flush_tick(now);
    REQUIRE(fx.inference.requests.size() == 2);
    fx.inference.requests.back().complete(stt::InferResponse{.transcript = "a"});

    REQUIRE(fx.sink.sent.size() == 2);
    CHECK(fx.sink.sent[0].contains(R"("type":"error")"));
    CHECK(fx.sink.sent[0].contains(
        R"("oldest_frame_seq":1,"newest_frame_seq":3,"frames":3,"audio_bytes":1920,)"));
    CHECK(fx.sink.sent[0].contains(R"("gateway_buffer_frames":1,)"));
    CHECK(fx.sink.sent[1].contains(R"("oldest_frame_seq":4,"newest_frame_seq":4,"frames":1,)"));
}

TEST_CASE("invalid first message closes with 1002") {
    for (const auto* text : {"not json", R"({"type":"stop"})", R"({"type":"start","x":1})"}) {
        const SessionFixture fx;
        fx.session->on_text(text);
        CHECK(fx.sink.close_code == stt::CLOSE_PROTOCOL_ERROR);
        CHECK(fx.session->closed());
    }
    const SessionFixture fx;
    fx.session->on_binary(as_span(frame_of(0)));
    CHECK(fx.sink.close_code == stt::CLOSE_PROTOCOL_ERROR);
    CHECK(fx.session->closed());
}

TEST_CASE("binary frame sizes 0/10/639/641 close with 1003") {
    for (const std::size_t size : {0UZ, 10UZ, 639UZ, 641UZ}) {
        const SessionFixture fx;
        fx.session->on_text(R"({"type":"start"})");
        const std::vector<std::byte> frame(size);
        fx.session->on_binary(as_span(frame));
        CHECK(fx.sink.close_code == stt::CLOSE_UNSUPPORTED_DATA);
        CHECK(fx.session->buffer_size() == 0);
    }
}

// The conformance harness sends a 64 KiB binary frame; it must get the app's
// 1003, which requires uWS to admit it (MAX_WS_MESSAGE_BYTES) first.
TEST_CASE("oversized 64 KiB binary frame closes with 1003") {
    static_assert(stt::MAX_WS_MESSAGE_BYTES >= 65536UZ);
    const SessionFixture fx;
    fx.session->on_text(R"({"type":"start"})");
    const std::vector<std::byte> frame(65536UZ);
    fx.session->on_binary(as_span(frame));
    CHECK(fx.sink.close_code == stt::CLOSE_UNSUPPORTED_DATA);
    CHECK(fx.session->buffer_size() == 0);
}

TEST_CASE("body buffer capacity is reused across flushes") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    auto now = std::chrono::steady_clock::now();
    fx.session->set_expected_next_flush(now);

    fx.session->on_binary(as_span(frame_of(0x01)));
    fx.session->on_flush_tick(now);
    REQUIRE(fx.inference.requests.size() == 1);
    const std::byte* first = fx.inference.requests.front().body.data();
    fx.inference.requests.front().complete(std::unexpected(stt::InferenceFailure{
        .stage = stt::ErrorStage::InferenceRequest,
        .kind = stt::ErrorKind::Timeout,
        .detail = "timed out",
        .status = std::nullopt,
        .retryable = true,
    }));

    now += 1000ms;
    fx.session->on_binary(as_span(frame_of(0x02)));
    fx.session->on_flush_tick(now);
    REQUIRE(fx.inference.requests.size() == 2);
    // Same allocation: the first body came back with the completion.
    CHECK(fx.inference.requests.back().body.data() == first);
}

TEST_CASE("inference failure surfaces as an error envelope on the wire") {
    SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    fx.session->on_binary(as_span(frame_of(0x01)));

    const auto now = std::chrono::steady_clock::now();
    fx.session->set_expected_next_flush(now);
    fx.session->on_flush_tick(now);

    REQUIRE(fx.inference.requests.size() == 1);
    fx.inference.requests.front().complete(std::unexpected(stt::InferenceFailure{
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
    const SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    fx.session->on_text(R"({"type":"start"})");

    CHECK(fx.sink.close_code == stt::CLOSE_PROTOCOL_ERROR);
    CHECK(fx.sink.close_reason == stt::REASON_TEXT_AFTER_START);
}

TEST_CASE("non-640-byte binary closes with 1003") {
    const SessionFixture fx;

    fx.session->on_text(R"({"type":"start"})");
    const std::vector<std::byte> tiny(123);
    fx.session->on_binary(as_span(tiny));

    CHECK(fx.sink.close_code == stt::CLOSE_UNSUPPORTED_DATA);
    CHECK(fx.sink.close_reason == stt::REASON_BAD_FRAME_SIZE);
}
// NOLINTEND(cert-err33-c)

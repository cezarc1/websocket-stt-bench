// cert-err33-c: on macOS arm64 doctest's CHECK expands DOCTEST_BREAK_INTO_DEBUGGER
// to an unchecked `raise(SIGTRAP)`; the hit is in the macro, not in this file.
// NOLINTBEGIN(cert-err33-c)
#include "inference.hpp"

#include <chrono>
#include <cstddef>
#include <future>
#include <utility>
#include <vector>

#include "config.hpp"
#include "doctest/doctest.h"

TEST_CASE("curl multi tuning preserves connection count and enables HTTP/2 multiplexing") {
    const auto fallback = stt::multi_tuning_for_client_count(0);
    CHECK(fallback.max_host_connections == 1);
    CHECK(fallback.max_total_connections == 1);
    CHECK(fallback.max_concurrent_streams == 200);
    CHECK(fallback.pipelining != 0);

    const auto tuned = stt::multi_tuning_for_client_count(4);
    CHECK(tuned.max_host_connections == 4);
    CHECK(tuned.max_total_connections == 4);
    CHECK(tuned.max_concurrent_streams == fallback.max_concurrent_streams);
    CHECK(tuned.pipelining == fallback.pipelining);
}

TEST_CASE("curl easy handle active limit scales with HTTP/2 connection count") {
    CHECK(stt::max_active_easy_handles_for_client_count(0) == 64);
    CHECK(stt::max_active_easy_handles_for_client_count(1) == 64);
    CHECK(stt::max_active_easy_handles_for_client_count(4) == 256);
}
TEST_CASE("curl client hands the request body back with a failed transfer") {
    // Nothing listens on loopback port 1, so the connect is refused at once and
    // the request completes through harvest_completions, the same call site a
    // successful response uses. Every other completion path shares the
    // `complete()` helper, so this pins the contract for all of them.
    stt::CurlInferenceClient client{"http://127.0.0.1:1", std::chrono::seconds{5}, 1};

    std::vector<std::byte> body(stt::FRAME_BYTES, std::byte{0x2a});
    const std::byte* const original = body.data();

    std::promise<std::pair<bool, std::vector<std::byte>>> done;
    auto returned = done.get_future();
    client.infer_async(std::move(body), 1,
                       [&done](stt::InferenceResult result, std::vector<std::byte> back) {
                           done.set_value({result.has_value(), std::move(back)});
                       });

    REQUIRE(returned.wait_for(std::chrono::seconds{10}) == std::future_status::ready);
    const auto [ok, back] = returned.get();
    CHECK_FALSE(ok);
    CHECK(back.size() == stt::FRAME_BYTES);
    CHECK(back.data() == original);  // same allocation, not a copy
}
// NOLINTEND(cert-err33-c)

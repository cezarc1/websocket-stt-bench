// cert-err33-c: on macOS arm64 doctest's CHECK expands DOCTEST_BREAK_INTO_DEBUGGER
// to an unchecked `raise(SIGTRAP)`; the hit is in the macro, not in this file.
// NOLINTBEGIN(cert-err33-c)
#include "inference.hpp"

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
// NOLINTEND(cert-err33-c)

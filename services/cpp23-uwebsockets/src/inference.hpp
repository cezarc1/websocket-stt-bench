#pragma once

#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <deque>
#include <expected>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "protocol.hpp"

namespace stt {

struct InferenceFailure {
    ErrorStage stage = ErrorStage::InferenceRequest;
    ErrorKind kind = ErrorKind::ConnectionReset;
    std::string detail;
    std::optional<std::uint16_t> status;
    bool retryable = true;
};

using InferenceResult = std::expected<InferResponse, InferenceFailure>;

struct CurlMultiTuning {
    long pipelining;
    long max_host_connections;
    long max_total_connections;
    long max_concurrent_streams;
};

CurlMultiTuning multi_tuning_for_client_count(int client_count);
std::size_t max_active_easy_handles_for_client_count(int client_count);
std::string_view curl_version_string() noexcept;
bool curl_supports_http2() noexcept;

// The completion callback may fire on any thread. Callers post any
// session-touching work back to the owning event loop themselves
// (e.g. `uWS::Loop::defer`).
//
// Queue depth is bounded indirectly: `Session::inflight_` caps each
// WebSocket to one in-flight inference, so worst case is # open sessions.
class InferenceClient {
public:
    InferenceClient() = default;
    InferenceClient(const InferenceClient&) = delete;
    InferenceClient& operator=(const InferenceClient&) = delete;
    InferenceClient(InferenceClient&&) = delete;
    InferenceClient& operator=(InferenceClient&&) = delete;
    virtual ~InferenceClient() = default;

    virtual void infer_async(std::vector<std::byte> body,
                             int cpu_passes,
                             std::function<void(InferenceResult)> on_complete) = 0;
};

// Production implementation. One libcurl multi pump owns all active inference
// requests and multiplexes them over up to `client_count` persistent HTTP/2
// connections to the inference server. `client_count` means connection count,
// not blocking worker count.
class CurlInferenceClient final : public InferenceClient {
public:
    // public only so the anon-namespace pump helpers in inference.cpp can
    // name it; not part of the user-facing API.
    struct Request {
        std::vector<std::byte> body;
        int cpu_passes;
        std::function<void(InferenceResult)> on_complete;
    };

    CurlInferenceClient(std::string base_url, std::chrono::milliseconds timeout, int client_count);
    ~CurlInferenceClient() override;

    void infer_async(std::vector<std::byte> body,
                     int cpu_passes,
                     std::function<void(InferenceResult)> on_complete) override;

private:
    void network_main();
    std::deque<Request> drain_queue(std::size_t max_take);
    bool should_exit() const;
    void wait_for_work(bool has_active);

    std::string url_;
    std::chrono::milliseconds timeout_;
    int client_count_;

    mutable std::mutex queue_mutex_;
    std::condition_variable queue_cv_;
    std::deque<Request> queue_;
    bool shutting_down_ = false;

    // void* to keep `<curl/curl.h>` out of this header.
    void* multi_handle_ = nullptr;

    std::jthread network_thread_;
};

}  // namespace stt

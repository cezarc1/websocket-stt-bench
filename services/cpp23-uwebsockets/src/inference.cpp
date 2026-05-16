#include "inference.hpp"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <deque>
#include <format>
#include <mutex>
#include <stdexcept>
#include <string>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <curl/curl.h>
#include <glaze/glaze.hpp>

#include "protocol.hpp"

namespace stt {

namespace {

constexpr std::size_t kMaxActiveEasyHandlesPerClient = 64;
constexpr int kActivePollTimeoutMs = 10;
constexpr long kMaxConcurrentStreams = 200;

InferenceFailure classify_status(long status) {
    const bool is_429 = status == 429;
    const bool is_5xx = status >= 500 && status < 600;
    return InferenceFailure{
        .stage = ErrorStage::InferenceRequest,
        .kind = is_429 ? ErrorKind::Http429 : ErrorKind::Http5xx,
        .detail = std::format("inference returned status {}", status),
        .status = static_cast<std::uint16_t>(status),
        .retryable = is_429 || is_5xx,
    };
}

InferenceFailure classify_curl(CURLcode code) {
    // curl_easy_strerror is documented to never return null.
    return InferenceFailure{
        .stage = ErrorStage::InferenceRequest,
        .kind = code == CURLE_OPERATION_TIMEDOUT ? ErrorKind::Timeout : ErrorKind::ConnectionReset,
        .detail = curl_easy_strerror(code),
        .status = std::nullopt,
        .retryable = true,
    };
}

InferenceFailure classify_multi(CURLMcode code) {
    return InferenceFailure{
        .stage = ErrorStage::InferenceRequest,
        .kind = ErrorKind::ConnectionReset,
        .detail = curl_multi_strerror(code),
        .status = std::nullopt,
        .retryable = true,
    };
}

std::size_t write_callback(char* data, std::size_t size, std::size_t nmemb, void* user) {
    auto& sink = *static_cast<std::string*>(user);
    const std::size_t bytes = size * nmemb;
    sink.append(data, bytes);
    return bytes;
}

void wake_multi(CURLM* multi) {
    if (multi == nullptr) {
        return;
    }
#if LIBCURL_VERSION_NUM >= 0x074400
    curl_multi_wakeup(multi);
#endif
}

// Caller MUST `curl_multi_remove_handle` before this destructs — libcurl
// asserts otherwise.
class EasyHandle {
public:
    EasyHandle() : handle_(curl_easy_init()) {
        if (handle_ == nullptr) {
            throw std::runtime_error("curl_easy_init failed");
        }
    }

    ~EasyHandle() noexcept {
        if (handle_ != nullptr) {
            curl_easy_cleanup(handle_);
        }
        if (headers_ != nullptr) {
            curl_slist_free_all(headers_);
        }
    }

    EasyHandle(const EasyHandle&) = delete;
    EasyHandle& operator=(const EasyHandle&) = delete;
    EasyHandle(EasyHandle&& other) noexcept
        : handle_(std::exchange(other.handle_, nullptr)),
          headers_(std::exchange(other.headers_, nullptr)) {}
    EasyHandle& operator=(EasyHandle&& other) noexcept {
        if (this != &other) {
            if (handle_ != nullptr) {
                curl_easy_cleanup(handle_);
            }
            if (headers_ != nullptr) {
                curl_slist_free_all(headers_);
            }
            handle_ = std::exchange(other.handle_, nullptr);
            headers_ = std::exchange(other.headers_, nullptr);
        }
        return *this;
    }

    [[nodiscard]] CURL* get() const noexcept { return handle_; }

    // Takes ownership of `hdrs`.
    void set_headers(curl_slist* hdrs) noexcept {
        if (headers_ != nullptr) {
            curl_slist_free_all(headers_);
        }
        headers_ = hdrs;
    }

    void reset_for_reuse() noexcept {
        if (headers_ != nullptr) {
            curl_slist_free_all(headers_);
            headers_ = nullptr;
        }
        curl_easy_reset(handle_);
    }

private:
    CURL* handle_ = nullptr;
    curl_slist* headers_ = nullptr;
};

// Heap-allocated (via unique_ptr) so libcurl's CURLOPT_WRITEDATA /
// CURLOPT_POSTFIELDS pointers stay valid across active-list movement.
// Member order: `easy` last so its dtor runs first and tears down the
// transfer before its write buffer goes away.
struct EasyState {
    CurlInferenceClient::Request request;
    std::string response_body;
    EasyHandle easy;
};

using ActiveList = std::vector<std::pair<CURL*, std::unique_ptr<EasyState>>>;

// Bounded recycle pool for EasyState. Past `cap` we drop the surplus so a
// burst that decays to a smaller steady-state doesn't pin libcurl state per
// idle handle indefinitely.
class IdlePool {
public:
    explicit IdlePool(std::size_t cap) noexcept : cap_(cap) {}

    std::unique_ptr<EasyState> acquire() {
        if (pool_.empty()) {
            return std::make_unique<EasyState>();
        }
        auto state = std::move(pool_.back());
        pool_.pop_back();
        return state;
    }

    void recycle(std::unique_ptr<EasyState> state) {
        if (pool_.size() >= cap_) {
            return;
        }
        state->easy.reset_for_reuse();
        state->request = CurlInferenceClient::Request{};
        state->response_body.clear();
        pool_.push_back(std::move(state));
    }

private:
    std::vector<std::unique_ptr<EasyState>> pool_;
    std::size_t cap_;
};

void configure_easy(CURL* easy,
                    EasyState& state,
                    const std::string& url,
                    std::chrono::milliseconds timeout) {
    curl_slist* headers = nullptr;
    const auto header_cpu = std::format("x-cpu-passes: {}", state.request.cpu_passes);
    headers = curl_slist_append(headers, header_cpu.c_str());
    headers = curl_slist_append(headers, "content-type: application/octet-stream");
    state.easy.set_headers(headers);

    const auto timeout_ms = static_cast<long>(timeout.count());
    curl_easy_setopt(easy, CURLOPT_URL, url.c_str());
    curl_easy_setopt(easy, CURLOPT_POST, 1L);
    curl_easy_setopt(easy, CURLOPT_TIMEOUT_MS, timeout_ms);
    curl_easy_setopt(easy, CURLOPT_CONNECTTIMEOUT_MS, timeout_ms);
    curl_easy_setopt(easy, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(easy, CURLOPT_WRITEFUNCTION, &write_callback);
    curl_easy_setopt(easy, CURLOPT_WRITEDATA, &state.response_body);
    curl_easy_setopt(easy, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE);
    curl_easy_setopt(easy, CURLOPT_POSTFIELDS, state.request.body.data());
    curl_easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE,
                     static_cast<curl_off_t>(state.request.body.size()));
    curl_easy_setopt(easy, CURLOPT_HTTPHEADER, headers);
}

InferenceResult finish_easy(CURL* easy, EasyState& state, CURLcode code) {
    if (code != CURLE_OK) {
        return std::unexpected(classify_curl(code));
    }

    long status_code = 0;
    curl_easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status_code);
    if (status_code < 200 || status_code >= 300) {
        return std::unexpected(classify_status(status_code));
    }

    InferResponse parsed{};
    if (auto err = glz::read<STRICT_JSON>(parsed, state.response_body); err) {
        return std::unexpected(InferenceFailure{
            .stage = ErrorStage::InferenceResponseParse,
            .kind = ErrorKind::ParseError,
            .detail = glz::format_error(err, state.response_body),
            .status = static_cast<std::uint16_t>(status_code),
            .retryable = false,
        });
    }
    return parsed;
}

void submit_one(CURLM* multi,
                const std::string& url,
                std::chrono::milliseconds timeout,
                ActiveList& active,
                IdlePool& idle,
                CurlInferenceClient::Request request) {
    std::unique_ptr<EasyState> state;
    try {
        state = idle.acquire();
    } catch (const std::runtime_error& ex) {
        request.on_complete(std::unexpected(InferenceFailure{
            .stage = ErrorStage::InferenceRequest,
            .kind = ErrorKind::ConnectionReset,
            .detail = ex.what(),
            .status = std::nullopt,
            .retryable = true,
        }));
        return;
    }

    state->request = std::move(request);
    state->response_body.reserve(512);
    CURL* easy = state->easy.get();
    configure_easy(easy, *state, url, timeout);

    const CURLMcode add_code = curl_multi_add_handle(multi, easy);
    if (add_code != CURLM_OK) {
        state->request.on_complete(std::unexpected(classify_multi(add_code)));
        idle.recycle(std::move(state));
        return;
    }
    active.emplace_back(easy, std::move(state));
}

void harvest_completions(CURLM* multi, ActiveList& active, IdlePool& idle) {
    int messages_left = 0;
    while (true) {
        CURLMsg* message = curl_multi_info_read(multi, &messages_left);
        if (message == nullptr) {
            break;
        }
        if (message->msg != CURLMSG_DONE) {
            continue;
        }

        CURL* easy = message->easy_handle;
        auto it = std::ranges::find_if(active, [easy](const auto& entry) { return entry.first == easy; });
        if (it == active.end()) {
            continue;
        }

        auto state = std::move(it->second);
        active.erase(it);
        curl_multi_remove_handle(multi, easy);
        auto result = finish_easy(easy, *state, message->data.result);
        state->request.on_complete(std::move(result));
        idle.recycle(std::move(state));
    }
}

void fail_active(CURLM* multi, ActiveList& active, IdlePool& idle, const InferenceFailure& failure) {
    for (auto& [easy, state] : active) {
        curl_multi_remove_handle(multi, easy);
        state->request.on_complete(std::unexpected(failure));
        idle.recycle(std::move(state));
    }
    active.clear();
}

}  // namespace

CurlMultiTuning multi_tuning_for_client_count(int client_count) {
    const long count = static_cast<long>(std::max(1, client_count));
    return CurlMultiTuning{
        .pipelining = CURLPIPE_MULTIPLEX,
        .max_host_connections = count,
        .max_total_connections = count,
        .max_concurrent_streams = kMaxConcurrentStreams,
    };
}

std::size_t max_active_easy_handles_for_client_count(int client_count) {
    return static_cast<std::size_t>(std::max(1, client_count)) * kMaxActiveEasyHandlesPerClient;
}

std::string_view curl_version_string() noexcept {
    const char* version = curl_version();
    return version == nullptr ? std::string_view{"unknown"} : std::string_view{version};
}

bool curl_supports_http2() noexcept {
    const auto* info = curl_version_info(CURLVERSION_NOW);
    return info != nullptr && (info->features & CURL_VERSION_HTTP2) != 0;
}

CurlInferenceClient::CurlInferenceClient(std::string base_url,
                                         std::chrono::milliseconds timeout,
                                         int client_count)
    : url_(std::move(base_url) + "/infer"), timeout_(timeout), client_count_(std::max(1, client_count)) {
    // Process-global; no paired cleanup — process exit reaps it.
    static std::once_flag curl_init_flag;
    std::call_once(curl_init_flag, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });

    // Init on the constructing thread so `multi_handle_` is non-null from
    // ctor return onwards — keeps `infer_async`'s wake_multi race-free.
    auto* multi = curl_multi_init();
    if (multi == nullptr) {
        throw std::runtime_error("curl_multi_init failed");
    }
    const auto tuning = multi_tuning_for_client_count(client_count_);
    curl_multi_setopt(multi, CURLMOPT_PIPELINING, tuning.pipelining);
    curl_multi_setopt(multi, CURLMOPT_MAX_HOST_CONNECTIONS, tuning.max_host_connections);
    curl_multi_setopt(multi, CURLMOPT_MAX_TOTAL_CONNECTIONS, tuning.max_total_connections);
    curl_multi_setopt(multi, CURLMOPT_MAX_CONCURRENT_STREAMS, tuning.max_concurrent_streams);
    multi_handle_ = multi;

    network_thread_ = std::jthread([this] { network_main(); });
}

CurlInferenceClient::~CurlInferenceClient() {
    {
        const std::lock_guard lock(queue_mutex_);
        shutting_down_ = true;
    }
    queue_cv_.notify_all();
    wake_multi(static_cast<CURLM*>(multi_handle_));
    if (network_thread_.joinable()) {
        network_thread_.join();
    }
    if (multi_handle_ != nullptr) {
        curl_multi_cleanup(static_cast<CURLM*>(multi_handle_));
        multi_handle_ = nullptr;
    }
}

void CurlInferenceClient::infer_async(std::vector<std::byte> body,
                                      int cpu_passes,
                                      std::function<void(InferenceResult)> on_complete) {
    {
        const std::lock_guard lock(queue_mutex_);
        queue_.push_back(Request{
            .body = std::move(body),
            .cpu_passes = cpu_passes,
            .on_complete = std::move(on_complete),
        });
    }
    // notify_one wakes the cv.wait_for branch; wake_multi wakes curl_multi_poll.
    queue_cv_.notify_one();
    wake_multi(static_cast<CURLM*>(multi_handle_));
}

void CurlInferenceClient::network_main() {
    auto* multi = static_cast<CURLM*>(multi_handle_);
    const std::size_t cap = max_active_easy_handles_for_client_count(client_count_);
    ActiveList active;
    active.reserve(cap);
    IdlePool idle{cap};

    while (true) {
        const std::size_t headroom = active.size() < cap ? cap - active.size() : 0;
        auto pending = drain_queue(headroom);
        for (auto& request : pending) {
            submit_one(multi, url_, timeout_, active, idle, std::move(request));
        }

        int running = 0;
        const CURLMcode perform_code = curl_multi_perform(multi, &running);
        if (perform_code != CURLM_OK) {
            // CURLM_OK is effectively the only success in modern libcurl;
            // anything else means the multi state is unusable. Drain.
            fail_active(multi, active, idle, classify_multi(perform_code));
        }

        harvest_completions(multi, active, idle);

        if (should_exit() && active.empty()) {
            break;
        }
        wait_for_work(!active.empty());
    }

    fail_active(multi,
                active,
                idle,
                InferenceFailure{
                    .stage = ErrorStage::InferenceRequest,
                    .kind = ErrorKind::ConnectionReset,
                    .detail = "inference client shutting down",
                    .status = std::nullopt,
                    .retryable = false,
                });
}

std::deque<CurlInferenceClient::Request> CurlInferenceClient::drain_queue(std::size_t max_take) {
    std::deque<Request> pending;
    if (max_take == 0) {
        return pending;
    }
    const std::lock_guard lock(queue_mutex_);
    while (!queue_.empty() && pending.size() < max_take) {
        pending.push_back(std::move(queue_.front()));
        queue_.pop_front();
    }
    return pending;
}

bool CurlInferenceClient::should_exit() const {
    const std::lock_guard lock(queue_mutex_);
    return shutting_down_ && queue_.empty();
}

void CurlInferenceClient::wait_for_work(bool has_active) {
    if (has_active) {
        auto* multi = static_cast<CURLM*>(multi_handle_);
        int num_fds = 0;
        // On the h2c path used in k3s, relying on fd wakeups alone produced
        // ~1s completion cadence under load. Keep the ceiling short so the
        // multi pump drains completed streams promptly even when no wakeup is
        // delivered for an HTTP/2 state transition.
        curl_multi_poll(multi, nullptr, 0, kActivePollTimeoutMs, &num_fds);
        return;
    }
    std::unique_lock lock(queue_mutex_);
    if (!shutting_down_ && queue_.empty()) {
        queue_cv_.wait_for(lock, std::chrono::milliseconds(1000));
    }
}

}  // namespace stt

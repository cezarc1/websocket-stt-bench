#include "server.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <functional>
#include <memory>
#include <random>
#include <set>
#include <span>
#include <string_view>
#include <thread>
#include <utility>
#include <vector>

#include <App.h>
#include <libusockets.h>

#include "config.hpp"
#include "inference.hpp"
#include "session.hpp"

namespace stt {

namespace {

struct PerSocketData;

// Adapts uWS::Loop to the Session's Scheduler interface. `loop_` is a raw
// pointer into uWS-owned state; `alive_` lets `run_one_app` mark the
// scheduler dead once `app.run()` returns, so any late cross-thread post
// from libcurl no-ops instead of dereferencing a torn-down loop.
class UwsScheduler final : public Scheduler {
public:
    explicit UwsScheduler(uWS::Loop* loop) noexcept : loop_(loop) {}

    void post(std::function<void()> task) override {
        if (!alive_.load(std::memory_order_acquire)) {
            return;
        }
        loop_->defer([task = std::move(task)]() mutable { task(); });
    }

    void mark_dead() noexcept { alive_.store(false, std::memory_order_release); }

private:
    uWS::Loop* loop_;
    std::atomic<bool> alive_{true};
};

// Shared min-heap of `(next_fire_time, weak_ptr<Session>)` keyed on time.
// One per loop; a single `us_timer_t` reschedules itself to the next-due fire
// time. Replaces the per-session `us_timer_t` design which consumed one kernel
// fd per connection and capped at ~50k sessions per process.
class FlushTimerWheel {
public:
    FlushTimerWheel(uWS::Loop* loop, std::chrono::milliseconds flush_interval)
        : flush_interval_(flush_interval),
          timer_(us_create_timer(reinterpret_cast<us_loop_t*>(loop), 0, sizeof(FlushTimerWheel*))) {
        *static_cast<FlushTimerWheel**>(us_timer_ext(timer_)) = this;
    }

    ~FlushTimerWheel() {
        if (timer_ != nullptr) {
            us_timer_close(timer_);
        }
    }

    FlushTimerWheel(const FlushTimerWheel&) = delete;
    FlushTimerWheel& operator=(const FlushTimerWheel&) = delete;
    FlushTimerWheel(FlushTimerWheel&&) = delete;
    FlushTimerWheel& operator=(FlushTimerWheel&&) = delete;

    void enroll(std::weak_ptr<Session> session, std::chrono::steady_clock::time_point first_fire) {
        queue_.emplace(first_fire, std::move(session));
        reschedule();
    }

private:
    using Entry = std::pair<std::chrono::steady_clock::time_point, std::weak_ptr<Session>>;
    struct ByTime {
        bool operator()(const Entry& a, const Entry& b) const noexcept { return a.first < b.first; }
    };

    void tick() {
        const auto now = std::chrono::steady_clock::now();
        while (!queue_.empty() && queue_.begin()->first <= now) {
            auto [when, weak] = std::move(queue_.extract(queue_.begin()).value());
            auto session = weak.lock();
            if (!session) {
                continue;  // WS closed; drop the entry.
            }
            session->on_flush_tick(now);
            // Catch up by interval steps if the loop drifted, rather than
            // bunching fires.
            auto next = when + flush_interval_;
            while (next <= now) {
                next += flush_interval_;
            }
            queue_.emplace(next, std::move(weak));
        }
        reschedule();
    }

    void reschedule() {
        if (queue_.empty()) {
            us_timer_set(timer_, &tick_thunk, 0, 0);  // disarm
            return;
        }
        const auto now = std::chrono::steady_clock::now();
        const auto delay = std::chrono::duration_cast<std::chrono::milliseconds>(queue_.begin()->first - now);
        const auto delay_ms = std::max<long>(1, delay.count());
        us_timer_set(timer_, &tick_thunk, static_cast<int>(delay_ms), 0);
    }

    static void tick_thunk(us_timer_t* t) {
        (*static_cast<FlushTimerWheel**>(us_timer_ext(t)))->tick();
    }

    std::chrono::milliseconds flush_interval_;
    us_timer_t* timer_;
    std::multiset<Entry, ByTime> queue_;
};

// What the loop hands to each WS connection. Sink + session live here; the
// timer wheel is per-loop and registers a weak_ptr to `session` on open.
struct PerSocketData {
    std::shared_ptr<OutboundSink> sink;
    std::shared_ptr<Session> session;
};

class WsSink final : public OutboundSink {
public:
    explicit WsSink(uWS::WebSocket<false, true, PerSocketData>* ws) noexcept : ws_(ws) {}

    void send(std::string_view payload) override {
        if (closed_) {
            return;
        }
        ws_->send(payload, uWS::OpCode::TEXT, false);
    }

    void close_with(int code, std::string_view reason) override {
        if (closed_) {
            return;
        }
        closed_ = true;
        ws_->end(code, reason);
    }

private:
    uWS::WebSocket<false, true, PerSocketData>* ws_;
    bool closed_ = false;
};

// Per-loop singletons the WS callbacks reach into. `scheduler` is shared so
// Session can capture it into the inference callback's closure (see
// `Session::submit_inference`).
struct LoopState {
    const Config& config;
    InferenceClient& inference;
    std::shared_ptr<UwsScheduler> scheduler;
    FlushTimerWheel wheel;

    LoopState(const Config& cfg, InferenceClient& inf, uWS::Loop* loop)
        : config(cfg),
          inference(inf),
          scheduler(std::make_shared<UwsScheduler>(loop)),
          wheel(loop, cfg.flush_interval) {}
};

std::chrono::steady_clock::time_point compute_first_fire(const Config& config) {
    auto delay = config.flush_interval;
    if (const auto jitter_ms = config.flush_phase_jitter.count(); jitter_ms > 0) {
        // minstd_rand is 4 bytes of state vs mt19937_64's ~2.5 KiB — plenty
        // good enough for one int per session.
        thread_local std::minstd_rand rng{std::random_device{}()};
        std::uniform_int_distribution<std::int64_t> dist(0, jitter_ms);
        delay += std::chrono::milliseconds(dist(rng));
    }
    return std::chrono::steady_clock::now() + delay;
}

void register_routes(uWS::App& app, LoopState& loop_state) {
    app.get("/health", [](auto* res, auto* /*req*/) {
        res->writeHeader("content-type", "application/json")
            ->end(R"({"status":"ok","runtime":"cpp23-uwebsockets"})");
    });

    uWS::App::WebSocketBehavior<PerSocketData> behavior{};
    behavior.compression = uWS::DISABLED;
    behavior.maxPayloadLength = 16 * 1024;
    behavior.idleTimeout = 0;
    behavior.maxBackpressure = 1024 * 1024;

    behavior.open = [&loop_state](auto* ws) {
        auto* data = static_cast<PerSocketData*>(ws->getUserData());
        auto sink = std::make_shared<WsSink>(ws);
        data->sink = sink;
        data->session = std::make_shared<Session>(loop_state.config, loop_state.inference,
                                                  *sink, loop_state.scheduler);

        const auto first_fire = compute_first_fire(loop_state.config);
        data->session->set_expected_next_flush(first_fire);
        loop_state.wheel.enroll(data->session, first_fire);
    };

    behavior.message = [](auto* ws, std::string_view message, uWS::OpCode op) {
        auto* data = static_cast<PerSocketData*>(ws->getUserData());
        if (!data->session) {
            return;
        }
        if (op == uWS::OpCode::TEXT) {
            data->session->on_text(message);
        } else if (op == uWS::OpCode::BINARY) {
            data->session->on_binary(std::as_bytes(std::span(message.data(), message.size())));
        }
    };

    behavior.close = [](auto* ws, int /*code*/, std::string_view /*reason*/) {
        auto* data = static_cast<PerSocketData*>(ws->getUserData());
        // Drop both shared_ptrs in declaration order (session first, sink last).
        // The wheel's weak_ptr expires here and the next tick drops the entry.
        // Any pending inference callback's weak_ptr<Session> also expires; it
        // resumes on the loop and no-ops via `weak.lock()` returning null.
        data->session.reset();
        data->sink.reset();
    };

    app.ws<PerSocketData>("/ws/stt", std::move(behavior));
}

void run_one_app(const Config& config, InferenceClient& inference, std::atomic<int>& listen_failures) {
    uWS::App app;
    LoopState loop_state{config, inference, uWS::Loop::get()};
    register_routes(app, loop_state);
    app.listen(config.port, [&](auto* listen_socket) {
        if (listen_socket == nullptr) {
            (void)std::fprintf(stderr, "failed to listen on port %u\n", config.port);
            listen_failures.fetch_add(1, std::memory_order_relaxed);
        }
    });
    app.run();
    // `app.run()` only returns once the loop has decided to stop. Mark the
    // scheduler dead before the loop is torn down so any in-flight libcurl
    // callback observes a clean no-op instead of `defer(...)` against a
    // freed loop.
    loop_state.scheduler->mark_dead();
}

}  // namespace

void run_server(const Config& config, InferenceClient& inference) {
    const int threads = std::max(1, config.worker_threads);
    std::atomic<int> listen_failures{0};
    std::vector<std::thread> workers;
    workers.reserve(static_cast<std::size_t>(threads));
    for (int i = 0; i < threads; ++i) {
        workers.emplace_back([&] { run_one_app(config, inference, listen_failures); });
    }
    for (auto& worker : workers) {
        worker.join();
    }
}

}  // namespace stt

#include <cstdio>
#include <cstdlib>
#include <exception>

#include "config.hpp"
#include "inference.hpp"
#include "server.hpp"

int main() {
    try {
        const auto config = stt::load_config_from_process_env();

        // Structured `runtime_versions` startup line — same pattern as the
        // other gateways so the analyzer can identify the gateway under test.
        // fprintf because Ubuntu Noble's libstdc++ (GCC 13) is missing <print>;
        // %.*s with an explicit length keeps the string_view aware of bounds.
        const auto curl_version = stt::curl_version_string();
        (void)std::fprintf(
            stdout,
            R"({"event":"runtime_versions","runtime":"%.*s","port":%u,"workers":%d,"inference_url":"%s","inference_http_clients":%d,"inference_transport":"libcurl_multi_h2","curl":"%.*s","curl_http2":%s})"
            "\n",
            static_cast<int>(stt::RUNTIME_NAME.size()), stt::RUNTIME_NAME.data(), config.port,
            config.worker_threads, config.inference_url.c_str(), config.inference_http_clients,
            static_cast<int>(curl_version.size()), curl_version.data(),
            stt::curl_supports_http2() ? "true" : "false");
        (void)std::fflush(stdout);

        stt::CurlInferenceClient inference(config.inference_url, config.inference_timeout,
                                           config.inference_http_clients);
        stt::run_server(config, inference);
        return 0;
    } catch (const std::exception& ex) {
        (void)std::fprintf(stderr, "fatal: %s\n", ex.what());
        return 1;
    }
}

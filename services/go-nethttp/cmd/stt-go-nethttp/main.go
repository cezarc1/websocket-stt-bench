package main

import (
	"fmt"
	"log"
	"net/http"
	"runtime"
	"time"

	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/config"
	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/inference"
	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/server"
)

func main() {
	cfg := config.Load()
	runner := inference.NewH2CClientPool(
		cfg.InferenceURL,
		cfg.InferenceTimeout,
		cfg.InferenceHTTPClients,
	)

	log.Printf(
		"runtime_versions runtime=%s go=%s coder_websocket=%s goccy_go_json=%s inference_url=%s flush_interval_ms=%d gomaxprocs=%d inference_http_clients=%d",
		config.RuntimeName,
		runtime.Version(),
		config.CoderWebsocketVersion,
		config.GoJSONVersion,
		cfg.InferenceURL,
		cfg.FlushInterval.Milliseconds(),
		runtime.GOMAXPROCS(0),
		cfg.InferenceHTTPClients,
	)

	addr := fmt.Sprintf(":%d", cfg.Port)
	log.Printf("listening addr=0.0.0.0%s", addr)
	httpServer := &http.Server{
		Addr:              addr,
		Handler:           server.New(cfg, runner).Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Fatal(httpServer.ListenAndServe())
}

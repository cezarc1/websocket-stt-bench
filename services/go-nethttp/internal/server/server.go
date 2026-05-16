package server

import (
	"context"
	"log"
	"net/http"

	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/config"
	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/session"
	"github.com/coder/websocket"
	json "github.com/goccy/go-json"
)

type Server struct {
	config config.Config
	runner session.Runner
}

func New(config config.Config, runner session.Runner) *Server {
	return &Server{
		config: config,
		runner: runner,
	}
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.health)
	mux.HandleFunc("/ws/stt", s.websocket)
	return mux
}

func (s *Server) health(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":      true,
		"runtime": config.RuntimeName,
	})
}

func (s *Server) websocket(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode:    websocket.CompressionDisabled,
		InsecureSkipVerify: true,
	})
	if err != nil {
		log.Printf("websocket accept: %v", err)
		return
	}
	conn.SetReadLimit(8 * 1024)

	core := session.NewCore(session.Config{
		CPUPasses:    s.config.CPUPasses,
		ModelDelayMS: s.config.ModelDelayMS,
	}, s.runner, s.config.PartialChannelDepth)
	core.Run(context.Background(), conn, s.config.FlushInterval, s.config.FlushPhaseJitter)
}

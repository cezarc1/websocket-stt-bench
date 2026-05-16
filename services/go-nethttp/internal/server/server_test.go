package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/config"
	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/protocol"
)

type fakeRunner struct{}

func (fakeRunner) Infer(context.Context, []byte, uint32) (protocol.Prediction, error) {
	return protocol.Prediction{}, nil
}

func TestHealthResponse(t *testing.T) {
	t.Parallel()

	request := httptest.NewRequest(http.MethodGet, "/health", nil)
	response := httptest.NewRecorder()
	New(config.Config{Port: 6000}, fakeRunner{}).Handler().ServeHTTP(response, request)

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200", response.Code)
	}
	if got := response.Body.String(); got != `{"ok":true,"runtime":"go-nethttp"}`+"\n" {
		t.Fatalf("body = %q", got)
	}
}

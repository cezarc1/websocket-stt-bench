package config

import (
	"testing"
	"time"
)

func TestLoadReadsBenchmarkEnvironment(t *testing.T) {
	t.Setenv("PORT", "6000")
	t.Setenv("INFERENCE_URL", "http://inference-server:9000/")
	t.Setenv("INFERENCE_TIMEOUT_MS", "1500")
	t.Setenv("INFERENCE_HTTP_CLIENTS", "8")
	t.Setenv("CPU_PASSES", "4")
	t.Setenv("MODEL_DELAY_MS", "75")
	t.Setenv("FLUSH_INTERVAL_MS", "1000")
	t.Setenv("FLUSH_PHASE_JITTER_MS", "1000")

	cfg := Load()

	if cfg.Port != 6000 {
		t.Fatalf("port = %d, want 6000", cfg.Port)
	}
	if cfg.InferenceURL != "http://inference-server:9000" {
		t.Fatalf("inference URL = %q", cfg.InferenceURL)
	}
	if cfg.InferenceTimeout != 1500*time.Millisecond {
		t.Fatalf("timeout = %s, want 1500ms", cfg.InferenceTimeout)
	}
	if cfg.InferenceHTTPClients != 8 {
		t.Fatalf("inference clients = %d, want 8", cfg.InferenceHTTPClients)
	}
	if cfg.FlushInterval != time.Second || cfg.FlushPhaseJitter != time.Second {
		t.Fatalf("flush timing = %s/%s, want 1s/1s", cfg.FlushInterval, cfg.FlushPhaseJitter)
	}
}

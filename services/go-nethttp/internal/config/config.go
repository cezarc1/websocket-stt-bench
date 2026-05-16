package config

import (
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	DefaultPort                 = 6000
	DefaultInferenceURL         = "http://inference-server:9000"
	DefaultInferenceTimeoutMS   = 2000
	DefaultInferenceHTTPClients = 4
	DefaultCPUPasses            = 4
	DefaultModelDelayMS         = 75
	DefaultFlushIntervalMS      = 1000
	DefaultFlushPhaseJitterMS   = 0
	DefaultPartialChannelDepth  = 4
	CoderWebsocketVersion       = "1.8.14"
	GoJSONVersion               = "0.10.6"
	RuntimeName                 = "go-nethttp"
)

type Config struct {
	Port                 int
	InferenceURL         string
	InferenceTimeout     time.Duration
	InferenceHTTPClients int
	CPUPasses            uint32
	ModelDelayMS         uint64
	FlushInterval        time.Duration
	FlushPhaseJitter     time.Duration
	PartialChannelDepth  int
}

func Load() Config {
	return Config{
		Port:                 envInt("PORT", DefaultPort),
		InferenceURL:         strings.TrimRight(envString("INFERENCE_URL", DefaultInferenceURL), "/"),
		InferenceTimeout:     time.Duration(envInt("INFERENCE_TIMEOUT_MS", DefaultInferenceTimeoutMS)) * time.Millisecond,
		InferenceHTTPClients: maxInt(1, envInt("INFERENCE_HTTP_CLIENTS", DefaultInferenceHTTPClients)),
		CPUPasses:            uint32(maxInt(1, envInt("CPU_PASSES", DefaultCPUPasses))),
		ModelDelayMS:         uint64(maxInt(0, envInt("MODEL_DELAY_MS", DefaultModelDelayMS))),
		FlushInterval:        time.Duration(maxInt(1, envInt("FLUSH_INTERVAL_MS", DefaultFlushIntervalMS))) * time.Millisecond,
		FlushPhaseJitter:     time.Duration(maxInt(0, envInt("FLUSH_PHASE_JITTER_MS", DefaultFlushPhaseJitterMS))) * time.Millisecond,
		PartialChannelDepth:  maxInt(1, envInt("PARTIAL_CHANNEL_DEPTH", DefaultPartialChannelDepth)),
	}
}

func envString(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func envInt(name string, fallback int) int {
	raw := os.Getenv(name)
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return fallback
	}
	return value
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

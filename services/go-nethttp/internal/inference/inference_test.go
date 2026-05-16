package inference

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestClientPostsInferenceRequestAndDecodesPrediction(t *testing.T) {
	t.Parallel()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/infer" {
			t.Fatalf("path = %q, want /infer", r.URL.Path)
		}
		if got := r.Header.Get("x-cpu-passes"); got != "4" {
			t.Fatalf("x-cpu-passes = %q, want 4", got)
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":640}`))
	}))
	t.Cleanup(server.Close)

	client := NewHTTP1Client(server.URL, 2*time.Second)
	prediction, err := client.Infer(context.Background(), []byte{1, 2, 3}, 4)
	if err != nil {
		t.Fatalf("infer: %v", err)
	}
	if prediction.Transcript != "now" || prediction.AudioBytes != 640 {
		t.Fatalf("prediction = %#v", prediction)
	}
}

func TestClassifiesHTTPStatusAndParseErrors(t *testing.T) {
	t.Parallel()

	statusErr := ClassifyStatus(http.StatusTooManyRequests)
	if statusErr.Kind != "http_429" || !statusErr.Retryable || statusErr.Status == nil || *statusErr.Status != http.StatusTooManyRequests {
		t.Fatalf("429 classification = %#v", statusErr)
	}

	parseErr := ClassifyParse(errors.New("bad json"))
	if parseErr.Kind != "parse_error" || parseErr.Retryable || parseErr.Status != nil {
		t.Fatalf("parse classification = %#v", parseErr)
	}
}

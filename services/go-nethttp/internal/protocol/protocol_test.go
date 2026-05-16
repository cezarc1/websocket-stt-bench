package protocol

import (
	"math"
	"slices"
	"testing"
)

func TestParseStartMessageStrict(t *testing.T) {
	t.Parallel()

	if err := ParseStartMessage([]byte(`{"type":"start"}`)); err != nil {
		t.Fatalf("expected exact start to parse: %v", err)
	}

	cases := [][]byte{
		[]byte(`not-json`),
		[]byte(`{"type":"start","extra":true}`),
		[]byte(`{"type":"partial"}`),
		[]byte(`{"type":"start"} trailing`),
	}
	for _, input := range cases {
		if err := ParseStartMessage(input); err == nil {
			t.Fatalf("expected %q to fail strict start parsing", input)
		}
	}
}

func TestPCMFrameSize(t *testing.T) {
	t.Parallel()

	if !IsPCMFrame(make([]byte, FrameBytes)) {
		t.Fatal("640 byte payload should be a PCM frame")
	}
	if IsPCMFrame(make([]byte, FrameBytes-1)) {
		t.Fatal("short payload should not be a PCM frame")
	}
}

func TestPartialMessageSerializesExactLoadgenSchema(t *testing.T) {
	t.Parallel()

	payload, err := MarshalPartialMessage(PartialMessage{
		Type:              PartialType,
		OldestFrameSeq:    1,
		NewestFrameSeq:    2,
		Frames:            2,
		RMS:               2425.5,
		ZeroCrossings:     7,
		Checksum:          1745339397,
		Samples:           1280,
		Transcript:        "now",
		AudioBytes:        1280,
		CPUPasses:         4,
		ModelDelayMS:      75,
		FlushLatenessMS:   1.23456,
		InflightModelJobs: 0,
	})
	if err != nil {
		t.Fatalf("marshal partial: %v", err)
	}

	object := DecodeObjectForTest(t, payload)
	assertKeys(t, object, []string{
		"type",
		"oldest_frame_seq",
		"newest_frame_seq",
		"frames",
		"rms",
		"zero_crossings",
		"checksum",
		"samples",
		"transcript",
		"audio_bytes",
		"cpu_passes",
		"model_delay_ms",
		"flush_lateness_ms",
		"inflight_model_jobs",
	})
	if object["flush_lateness_ms"] != 1.235 {
		t.Fatalf("flush_lateness_ms = %#v, want 1.235", object["flush_lateness_ms"])
	}
}

func TestErrorMessageSerializesExactDiagnosticSchema(t *testing.T) {
	t.Parallel()

	payload, err := MarshalErrorMessage(ErrorMessage{
		Type:                   ErrorType,
		Stage:                  StageInferenceRequest,
		Kind:                   KindTimeout,
		Message:                "timed out",
		OldestFrameSeq:         1,
		NewestFrameSeq:         2,
		Frames:                 2,
		AudioBytes:             1280,
		OldestAgeMS:            1200.12345,
		NewestAgeMS:            200.12345,
		FlushLatenessMS:        4.4444,
		InferenceElapsedMS:     Float64Ptr(2000.12345),
		InflightGatewayBatches: 1,
		GatewayBufferFrames:    3,
		InferenceStatus:        nil,
		Retryable:              true,
	})
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}

	object := DecodeObjectForTest(t, payload)
	assertKeys(t, object, []string{
		"type",
		"stage",
		"kind",
		"message",
		"oldest_frame_seq",
		"newest_frame_seq",
		"frames",
		"audio_bytes",
		"oldest_age_ms",
		"newest_age_ms",
		"flush_lateness_ms",
		"inference_elapsed_ms",
		"inflight_gateway_batches",
		"gateway_buffer_frames",
		"inference_status",
		"retryable",
	})
	if object["oldest_age_ms"] != 1200.123 {
		t.Fatalf("oldest_age_ms = %#v, want 1200.123", object["oldest_age_ms"])
	}
	if object["inference_status"] != nil {
		t.Fatalf("inference_status = %#v, want nil", object["inference_status"])
	}
}

func TestDecodePredictionStrictAndValidated(t *testing.T) {
	t.Parallel()

	if _, err := DecodePrediction([]byte(`{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":640}`)); err != nil {
		t.Fatalf("decode valid prediction: %v", err)
	}

	for _, input := range [][]byte{
		[]byte(`{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":640,"extra":true}`),
		[]byte(`{"rms":NaN,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":640}`),
		[]byte(`{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":0,"transcript":"now","audio_bytes":640}`),
		[]byte(`{"rms":1.5,"zero_crossings":2,"checksum":3,"samples":1280,"transcript":"now","audio_bytes":0}`),
	} {
		if _, err := DecodePrediction(input); err == nil {
			t.Fatalf("expected invalid prediction to fail: %s", input)
		}
	}

	if err := (Prediction{RMS: math.NaN(), Samples: 1, AudioBytes: 1}).Validate(); err == nil {
		t.Fatal("NaN rms should fail prediction validation")
	}
}

func assertKeys(t *testing.T, object map[string]any, expected []string) {
	t.Helper()

	actual := make([]string, 0, len(object))
	for key := range object {
		actual = append(actual, key)
	}
	slices.Sort(actual)
	slices.Sort(expected)
	if !slices.Equal(actual, expected) {
		t.Fatalf("keys = %#v, want %#v", actual, expected)
	}
}

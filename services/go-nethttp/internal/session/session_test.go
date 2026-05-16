package session

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/inference"
	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/protocol"
	json "github.com/goccy/go-json"
)

type fakeRunner struct {
	calls atomic.Int32
	gate  chan struct{}
	err   error
}

func (r *fakeRunner) Infer(ctx context.Context, _ []byte, _ uint32) (protocol.Prediction, error) {
	r.calls.Add(1)
	if r.gate != nil {
		select {
		case <-r.gate:
		case <-ctx.Done():
			return protocol.Prediction{}, ctx.Err()
		}
	}
	if r.err != nil {
		return protocol.Prediction{}, r.err
	}
	return protocol.Prediction{
		RMS:           1.5,
		ZeroCrossings: 2,
		Checksum:      3,
		Samples:       1280,
		Transcript:    "now",
		AudioBytes:    1280,
	}, nil
}

func TestSessionRejectsInvalidStartAndFrameShape(t *testing.T) {
	t.Parallel()

	s := NewCore(Config{CPUPasses: 4, ModelDelayMS: 75}, &fakeRunner{}, 4)

	closeCode, closeReason, ok := s.handleMessage(MessageText, []byte("not-json"), time.Now())
	if !ok || closeCode != CloseProtocolError || closeReason != ReasonNeedStart {
		t.Fatalf("invalid start close = (%d, %q, %v)", closeCode, closeReason, ok)
	}

	s = NewCore(Config{CPUPasses: 4, ModelDelayMS: 75}, &fakeRunner{}, 4)
	if _, _, ok := s.handleMessage(MessageText, []byte(`{"type":"start"}`), time.Now()); ok {
		t.Fatal("valid start should not close")
	}
	closeCode, closeReason, ok = s.handleMessage(MessageBinary, make([]byte, 10), time.Now())
	if !ok || closeCode != CloseUnsupportedData || closeReason != ReasonBadFrameSize {
		t.Fatalf("bad binary close = (%d, %q, %v)", closeCode, closeReason, ok)
	}
}

func TestFlushBuildsPartialAndPreservesFramesWhileInflight(t *testing.T) {
	t.Parallel()

	gate := make(chan struct{})
	runner := &fakeRunner{gate: gate}
	s := NewCore(Config{CPUPasses: 4, ModelDelayMS: 75}, runner, 4)
	if _, _, ok := s.handleMessage(MessageText, []byte(`{"type":"start"}`), time.Now()); ok {
		t.Fatal("valid start should not close")
	}
	if _, _, ok := s.handleMessage(MessageBinary, frame(1), time.Now()); ok {
		t.Fatal("valid binary should not close")
	}

	firstOutbox := make(chan string, 1)
	firstDone := s.flushToOutbox(context.Background(), firstOutbox, 2.34567)
	if _, _, ok := s.handleMessage(MessageBinary, frame(2), time.Now()); ok {
		t.Fatal("second valid binary should not close")
	}
	secondOutbox := make(chan string, 1)
	secondDone := s.flushToOutbox(context.Background(), secondOutbox, 0)

	select {
	case <-secondDone:
	case <-time.After(time.Second):
		t.Fatal("second flush should skip while first is inflight")
	}
	if got := s.bufferedFrames(); got != 1 {
		t.Fatalf("buffered frames = %d, want 1", got)
	}

	close(gate)
	select {
	case payload := <-firstOutbox:
		object := decodeObject(t, []byte(payload))
		if object["type"] != "partial" || object["frames"] != float64(1) || object["flush_lateness_ms"] != 2.346 {
			t.Fatalf("partial object = %#v", object)
		}
	case <-time.After(time.Second):
		t.Fatal("first flush did not finish")
	}
	<-firstDone
	if calls := runner.calls.Load(); calls != 1 {
		t.Fatalf("runner calls = %d, want 1", calls)
	}
}

func TestFlushHoldsInflightPermitWhileOutboxIsFull(t *testing.T) {
	t.Parallel()

	runner := &fakeRunner{}
	s := NewCore(Config{CPUPasses: 4, ModelDelayMS: 75}, runner, 4)
	outbox := make(chan string)
	_, _, _ = s.handleMessage(MessageText, []byte(`{"type":"start"}`), time.Now())
	_, _, _ = s.handleMessage(MessageBinary, frame(1), time.Now())

	first := s.flushToOutbox(context.Background(), outbox, 0)
	select {
	case <-first:
		t.Fatal("first flush should block while the outbox is full")
	case <-time.After(50 * time.Millisecond):
	}

	_, _, _ = s.handleMessage(MessageBinary, frame(2), time.Now())
	second := s.flushToOutbox(context.Background(), outbox, 0)
	select {
	case <-second:
	case <-time.After(time.Second):
		t.Fatal("second flush should skip while first is blocked on outbox")
	}
	if got := s.bufferedFrames(); got != 1 {
		t.Fatalf("buffered frames = %d, want 1", got)
	}
	if calls := runner.calls.Load(); calls != 1 {
		t.Fatalf("runner calls = %d, want 1 while outbox is blocked", calls)
	}

	select {
	case <-outbox:
	case <-time.After(time.Second):
		t.Fatal("first payload was not waiting on outbox")
	}
	select {
	case <-first:
	case <-time.After(time.Second):
		t.Fatal("first flush did not finish after outbox drained")
	}
}

func TestFlushRelaysInferenceError(t *testing.T) {
	t.Parallel()

	runner := &fakeRunner{err: inference.Details{
		Stage:     protocol.StageInferenceRequest,
		Kind:      protocol.KindTimeout,
		Message:   "timed out",
		Retryable: true,
	}}
	s := NewCore(Config{CPUPasses: 4, ModelDelayMS: 75}, runner, 4)
	_, _, _ = s.handleMessage(MessageText, []byte(`{"type":"start"}`), time.Now())
	_, _, _ = s.handleMessage(MessageBinary, frame(1), time.Now())

	outbox := make(chan string, 1)
	done := s.flushToOutbox(context.Background(), outbox, 0)
	select {
	case payload := <-outbox:
		object := decodeObject(t, []byte(payload))
		if object["type"] != "error" || object["kind"] != string(protocol.KindTimeout) || object["retryable"] != true {
			t.Fatalf("error object = %#v", object)
		}
	case <-time.After(time.Second):
		t.Fatal("flush did not return error payload")
	}
	<-done
}

func frame(fill byte) []byte {
	payload := make([]byte, protocol.FrameBytes)
	for i := range payload {
		payload[i] = fill
	}
	return payload
}

func decodeObject(t *testing.T, payload []byte) map[string]any {
	t.Helper()

	var object map[string]any
	if err := json.Unmarshal(payload, &object); err != nil {
		t.Fatalf("decode object: %v", err)
	}
	return object
}

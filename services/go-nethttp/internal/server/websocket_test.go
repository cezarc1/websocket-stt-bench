package server

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"hash/fnv"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/config"
	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/protocol"
	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/session"
	"github.com/coder/websocket"
	json "github.com/goccy/go-json"
)

// hashRunner answers with an FNV-1a checksum of the exact body it received,
// so a partial's checksum pins which bytes (and in which order) were sent.
type hashRunner struct{}

func (hashRunner) Infer(_ context.Context, body []byte, _ uint32) (protocol.Prediction, error) {
	return protocol.Prediction{
		RMS:        1,
		Checksum:   fnv32(body),
		Samples:    uint64(len(body)) / 2 * 4,
		Transcript: "now",
		AudioBytes: uint64(len(body)),
	}, nil
}

func fnv32(body []byte) uint32 {
	h := fnv.New32a()
	_, _ = h.Write(body)
	return h.Sum32()
}

// seqFrame is a 640-byte frame whose content is unique per (session, seq).
func seqFrame(sessionID, seq uint64) []byte {
	frame := make([]byte, protocol.FrameBytes)
	for i := 0; i < len(frame); i += 16 {
		binary.LittleEndian.PutUint64(frame[i:], sessionID)
		binary.LittleEndian.PutUint64(frame[i+8:], seq*1_000_003+uint64(i))
	}
	return frame
}

func startServer(t *testing.T) string {
	t.Helper()
	cfg := config.Config{
		CPUPasses:           4,
		ModelDelayMS:        75,
		FlushInterval:       100 * time.Millisecond,
		PartialChannelDepth: 4,
	}
	srv := httptest.NewServer(New(cfg, hashRunner{}).Handler())
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws/stt"
}

func dial(t *testing.T, url string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	conn, resp, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	if resp.Body != nil {
		_ = resp.Body.Close()
	}
	conn.SetReadLimit(-1)
	t.Cleanup(func() { _ = conn.CloseNow() })
	return conn
}

func write(t *testing.T, conn *websocket.Conn, typ websocket.MessageType, payload []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 2*time.Second)
	defer cancel()
	if err := conn.Write(ctx, typ, payload); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func expectClose(t *testing.T, conn *websocket.Conn, want websocket.StatusCode) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	_, payload, err := conn.Read(ctx)
	if err == nil {
		t.Fatalf("expected close %d, got message %q", want, payload)
	}
	if got := websocket.CloseStatus(err); got != want {
		t.Fatalf("close status = %d, want %d (err %v)", got, want, err)
	}
}

func TestInvalidFirstMessageClosesWith1002(t *testing.T) {
	t.Parallel()
	url := startServer(t)
	cases := map[string]struct {
		typ     websocket.MessageType
		payload []byte
	}{
		"non-JSON":     {websocket.MessageText, []byte("not-json")},
		"wrong type":   {websocket.MessageText, []byte(`{"type":"stop"}`)},
		"binary first": {websocket.MessageBinary, seqFrame(0, 1)},
		// Above the read limit: must still be 1002, not the library's 1009.
		"oversized text": {websocket.MessageText, bytes.Repeat([]byte(" "), 4*session.MaxMessageBytes)},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			conn := dial(t, url)
			write(t, conn, tc.typ, tc.payload)
			expectClose(t, conn, websocket.StatusProtocolError)
		})
	}
}

func TestInvalidFrameSizeClosesWith1003(t *testing.T) {
	t.Parallel()
	url := startServer(t)
	sizes := []int{
		0, 10, protocol.FrameBytes - 1, protocol.FrameBytes + 1,
		// At, just past, and far past the read limit: must be 1003, not 1009.
		session.MaxMessageBytes, session.MaxMessageBytes + 1, session.MaxMessageBytes + 2, 1 << 20,
	}
	for _, size := range sizes {
		t.Run(itoa(size), func(t *testing.T) {
			t.Parallel()
			conn := dial(t, url)
			write(t, conn, websocket.MessageText, []byte(`{"type":"start"}`))
			write(t, conn, websocket.MessageBinary, make([]byte, size))
			expectClose(t, conn, websocket.StatusUnsupportedData)
		})
	}
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

// Streams paced frames on two concurrent sessions and checks every partial
// tiles the sequence and carries the checksum of exactly its own frames,
// concatenated in seq order (catches buffer aliasing, drops, reordering,
// cross-session mixing).
func TestPartialsTileSequenceWithExactBodies(t *testing.T) {
	t.Parallel()
	url := startServer(t)
	var wg sync.WaitGroup
	for _, sessionID := range []uint64{101, 202} {
		wg.Go(func() {
			streamAndVerify(t, url, sessionID)
		})
	}
	wg.Wait()
}

func streamAndVerify(t *testing.T, url string, sessionID uint64) {
	t.Helper()
	const total = 60
	conn := dial(t, url)
	write(t, conn, websocket.MessageText, []byte(`{"type":"start"}`))

	go func() {
		for seq := uint64(1); seq <= total; seq++ {
			if err := conn.Write(t.Context(), websocket.MessageBinary, seqFrame(sessionID, seq)); err != nil {
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()

	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	var lastNewest uint64
	partials := 0
	for lastNewest < total {
		_, raw, err := conn.Read(ctx)
		if err != nil {
			t.Errorf("session %d: read after %d frames: %v", sessionID, lastNewest, err)
			return
		}
		var p protocol.PartialMessage
		if err := json.Unmarshal(raw, &p); err != nil || p.Type != protocol.PartialType {
			t.Errorf("session %d: not a partial: %s", sessionID, raw)
			return
		}
		if p.OldestFrameSeq != lastNewest+1 || p.NewestFrameSeq < p.OldestFrameSeq {
			t.Errorf("session %d: range %d..=%d after %d", sessionID, p.OldestFrameSeq, p.NewestFrameSeq, lastNewest)
			return
		}
		frames := p.NewestFrameSeq - p.OldestFrameSeq + 1
		var body []byte
		for seq := p.OldestFrameSeq; seq <= p.NewestFrameSeq; seq++ {
			body = append(body, seqFrame(sessionID, seq)...)
		}
		if uint64(p.Frames) != frames || p.AudioBytes != frames*protocol.FrameBytes ||
			p.Checksum != fnv32(body) || p.CPUPasses != 4 || p.ModelDelayMS != 75 {
			t.Errorf("session %d: partial %s does not match frames %d..=%d", sessionID, raw, p.OldestFrameSeq, p.NewestFrameSeq)
			return
		}
		lastNewest = p.NewestFrameSeq
		partials++
	}
	if partials < 2 {
		t.Errorf("session %d: %d partials, want several flushes", sessionID, partials)
	}
	_ = conn.Close(websocket.StatusNormalClosure, "")
}

func TestNormalCloseIsPrompt(t *testing.T) {
	t.Parallel()
	url := startServer(t)
	conn := dial(t, url)
	write(t, conn, websocket.MessageText, []byte(`{"type":"start"}`))
	write(t, conn, websocket.MessageBinary, seqFrame(0, 1))

	started := time.Now()
	err := conn.Close(websocket.StatusNormalClosure, "")
	if err != nil && !errors.Is(err, context.Canceled) {
		t.Fatalf("close: %v", err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("normal close took %v", elapsed)
	}
}

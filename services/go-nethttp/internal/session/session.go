package session

import (
	"context"
	"errors"
	"math/rand/v2"
	"sync"
	"time"

	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/inference"
	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/protocol"
	"github.com/coder/websocket"
)

const (
	CloseProtocolError   uint16 = 1002
	CloseUnsupportedData uint16 = 1003
	ReasonNeedStart             = "first message must be start"
	ReasonTextAfterStart        = "expected binary PCM frames after start"
	ReasonBadFrameSize          = "expected 640 byte PCM frame"
	typicalBatch                = 50
)

type MessageType int

const (
	MessageText MessageType = iota + 1
	MessageBinary
)

type Config struct {
	CPUPasses    uint32
	ModelDelayMS uint64
}

type Runner interface {
	Infer(ctx context.Context, body []byte, cpuPasses uint32) (protocol.Prediction, error)
}

type Core struct {
	config      Config
	runner      Runner
	outboxDepth int
	inflight    chan struct{}

	mu      sync.Mutex
	started bool
	seq     uint64
	buffer  []protocol.Frame
}

func NewCore(config Config, runner Runner, outboxDepth int) *Core {
	if outboxDepth < 1 {
		outboxDepth = 1
	}
	inflight := make(chan struct{}, 1)
	inflight <- struct{}{}
	return &Core{
		config:      config,
		runner:      runner,
		outboxDepth: outboxDepth,
		inflight:    inflight,
		buffer:      make([]protocol.Frame, 0, typicalBatch),
	}
}

func (c *Core) bufferedFrames() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.buffer)
}

func (c *Core) Run(ctx context.Context, conn *websocket.Conn, flushInterval, flushPhaseJitter time.Duration) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	defer func() {
		_ = conn.CloseNow()
	}()

	if !c.readStart(ctx, conn) {
		return
	}

	outbox := make(chan string, c.outboxDepth)
	go c.writeLoop(ctx, cancel, conn, outbox)
	go c.flushLoop(ctx, outbox, flushInterval, flushPhaseJitter)

	for {
		messageType, payload, err := conn.Read(ctx)
		if err != nil {
			if status := websocket.CloseStatus(err); status == websocket.StatusNormalClosure || status == websocket.StatusGoingAway {
				_ = conn.Close(websocket.StatusNormalClosure, "")
			}
			return
		}

		code, reason, shouldClose := c.handleMessage(fromWebsocketType(messageType), payload, time.Now())
		if shouldClose {
			_ = conn.Close(websocket.StatusCode(code), reason)
			return
		}
	}
}

func (c *Core) readStart(ctx context.Context, conn *websocket.Conn) bool {
	messageType, payload, err := conn.Read(ctx)
	if err != nil {
		return false
	}
	code, reason, shouldClose := c.handleMessage(fromWebsocketType(messageType), payload, time.Now())
	if shouldClose {
		_ = conn.Close(websocket.StatusCode(code), reason)
		return false
	}
	return true
}

func (c *Core) handleMessage(messageType MessageType, payload []byte, receivedAt time.Time) (uint16, string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if !c.started {
		if messageType != MessageText || protocol.ParseStartMessage(payload) != nil {
			return CloseProtocolError, ReasonNeedStart, true
		}
		c.started = true
		return 0, "", false
	}

	if messageType == MessageText {
		return CloseProtocolError, ReasonTextAfterStart, true
	}
	if messageType != MessageBinary || !protocol.IsPCMFrame(payload) {
		return CloseUnsupportedData, ReasonBadFrameSize, true
	}

	c.seq++
	copied := make([]byte, len(payload))
	copy(copied, payload)
	c.buffer = append(c.buffer, protocol.Frame{
		Seq:        c.seq,
		Payload:    copied,
		ReceivedAt: receivedAt,
	})
	return 0, "", false
}

func (c *Core) flushLoop(ctx context.Context, outbox chan<- string, flushInterval, flushPhaseJitter time.Duration) {
	if flushInterval <= 0 {
		flushInterval = time.Second
	}

	jitter := time.Duration(rand.Float64() * float64(flushPhaseJitter))
	expected := time.Now().Add(flushInterval + jitter)
	timer := time.NewTimer(time.Until(expected))
	defer timer.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
			now := time.Now()
			flushLatenessMS := durationMS(now, expected)
			_ = c.flushToOutbox(ctx, outbox, flushLatenessMS)

			expected = expected.Add(flushInterval)
			timer.Reset(maxDuration(0, time.Until(expected)))
		}
	}
}

func (c *Core) flushToOutbox(ctx context.Context, outbox chan<- string, flushLatenessMS float64) <-chan struct{} {
	done := make(chan struct{})
	if !c.tryAcquireInflight() {
		close(done)
		return done
	}

	batch := c.drainBuffer()
	if len(batch) == 0 {
		c.releaseInflight()
		close(done)
		return done
	}

	go func() {
		defer close(done)
		defer c.releaseInflight()

		payload, ok := c.processBatch(ctx, batch, flushLatenessMS)
		if !ok {
			return
		}
		select {
		case outbox <- string(payload):
		case <-ctx.Done():
		}
	}()
	return done
}

func (c *Core) writeLoop(ctx context.Context, cancel context.CancelFunc, conn *websocket.Conn, outbox <-chan string) {
	for {
		select {
		case <-ctx.Done():
			return
		case payload := <-outbox:
			writeCtx, writeCancel := context.WithTimeout(ctx, 2*time.Second)
			err := conn.Write(writeCtx, websocket.MessageText, []byte(payload))
			writeCancel()
			if err != nil {
				cancel()
				return
			}
		}
	}
}

func (c *Core) processBatch(ctx context.Context, batch []protocol.Frame, flushLatenessMS float64) ([]byte, bool) {
	oldest := batch[0]
	newest := batch[len(batch)-1]
	body := concatFrames(batch)
	startedAt := time.Now()

	prediction, err := c.runner.Infer(ctx, body, c.config.CPUPasses)
	if err != nil {
		if errors.Is(ctx.Err(), context.Canceled) || errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, false
		}
		details := inference.AsDetails(err)
		elapsedMS := durationMS(time.Now(), startedAt)
		payload, marshalErr := protocol.MarshalErrorMessage(protocol.ErrorMessage{
			Type:                   protocol.ErrorType,
			Stage:                  details.Stage,
			Kind:                   details.Kind,
			Message:                details.Message,
			OldestFrameSeq:         oldest.Seq,
			NewestFrameSeq:         newest.Seq,
			Frames:                 len(batch),
			AudioBytes:             uint64(len(body)),
			OldestAgeMS:            durationMS(time.Now(), oldest.ReceivedAt),
			NewestAgeMS:            durationMS(time.Now(), newest.ReceivedAt),
			FlushLatenessMS:        flushLatenessMS,
			InferenceElapsedMS:     &elapsedMS,
			InflightGatewayBatches: 1,
			GatewayBufferFrames:    c.bufferedFrames(),
			InferenceStatus:        details.Status,
			Retryable:              details.Retryable,
		})
		return payload, marshalErr == nil
	}

	payload, err := protocol.MarshalPartialMessage(protocol.NewPartialMessage(
		prediction,
		oldest.Seq,
		newest.Seq,
		len(batch),
		c.config.CPUPasses,
		c.config.ModelDelayMS,
		flushLatenessMS,
	))
	return payload, err == nil
}

func (c *Core) tryAcquireInflight() bool {
	select {
	case <-c.inflight:
		return true
	default:
		return false
	}
}

func (c *Core) releaseInflight() {
	select {
	case c.inflight <- struct{}{}:
	default:
	}
}

func (c *Core) drainBuffer() []protocol.Frame {
	c.mu.Lock()
	defer c.mu.Unlock()

	if len(c.buffer) == 0 {
		return nil
	}
	batch := c.buffer
	c.buffer = make([]protocol.Frame, 0, typicalBatch)
	return batch
}

func concatFrames(batch []protocol.Frame) []byte {
	body := make([]byte, 0, len(batch)*protocol.FrameBytes)
	for _, frame := range batch {
		body = append(body, frame.Payload...)
	}
	return body
}

func fromWebsocketType(messageType websocket.MessageType) MessageType {
	if messageType == websocket.MessageText {
		return MessageText
	}
	if messageType == websocket.MessageBinary {
		return MessageBinary
	}
	return 0
}

func durationMS(now, earlier time.Time) float64 {
	if now.Before(earlier) {
		return 0
	}
	return now.Sub(earlier).Seconds() * 1000
}

func maxDuration(a, b time.Duration) time.Duration {
	if a > b {
		return a
	}
	return b
}

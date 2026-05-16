package protocol

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"math"
	"time"

	json "github.com/goccy/go-json"
)

const (
	FrameBytes  = 640
	PartialType = "partial"
	ErrorType   = "error"
)

type ErrorStage string

const (
	StageWebsocketReceive       ErrorStage = "websocket_receive"
	StageBatchFlush             ErrorStage = "batch_flush"
	StageInferenceRequest       ErrorStage = "inference_request"
	StageInferenceResponseParse ErrorStage = "inference_response_parse"
	StageWebsocketSend          ErrorStage = "websocket_send"
)

type ErrorKind string

const (
	KindTimeout         ErrorKind = "timeout"
	KindPoolTimeout     ErrorKind = "pool_timeout"
	KindHTTP5xx         ErrorKind = "http_5xx"
	KindHTTP429         ErrorKind = "http_429"
	KindConnectionReset ErrorKind = "connection_reset"
	KindParseError      ErrorKind = "parse_error"
	KindSendError       ErrorKind = "send_error"
)

type Frame struct {
	Seq        uint64
	Payload    []byte
	ReceivedAt time.Time
}

type Prediction struct {
	RMS           float64 `json:"rms"`
	ZeroCrossings uint64  `json:"zero_crossings"`
	Checksum      uint32  `json:"checksum"`
	Samples       uint64  `json:"samples"`
	Transcript    string  `json:"transcript"`
	AudioBytes    uint64  `json:"audio_bytes"`
}

type PartialMessage struct {
	Type              string  `json:"type"`
	OldestFrameSeq    uint64  `json:"oldest_frame_seq"`
	NewestFrameSeq    uint64  `json:"newest_frame_seq"`
	Frames            int     `json:"frames"`
	RMS               float64 `json:"rms"`
	ZeroCrossings     uint64  `json:"zero_crossings"`
	Checksum          uint32  `json:"checksum"`
	Samples           uint64  `json:"samples"`
	Transcript        string  `json:"transcript"`
	AudioBytes        uint64  `json:"audio_bytes"`
	CPUPasses         uint32  `json:"cpu_passes"`
	ModelDelayMS      uint64  `json:"model_delay_ms"`
	FlushLatenessMS   float64 `json:"flush_lateness_ms"`
	InflightModelJobs int     `json:"inflight_model_jobs"`
}

type ErrorMessage struct {
	Type                   string     `json:"type"`
	Stage                  ErrorStage `json:"stage"`
	Kind                   ErrorKind  `json:"kind"`
	Message                string     `json:"message"`
	OldestFrameSeq         uint64     `json:"oldest_frame_seq"`
	NewestFrameSeq         uint64     `json:"newest_frame_seq"`
	Frames                 int        `json:"frames"`
	AudioBytes             uint64     `json:"audio_bytes"`
	OldestAgeMS            float64    `json:"oldest_age_ms"`
	NewestAgeMS            float64    `json:"newest_age_ms"`
	FlushLatenessMS        float64    `json:"flush_lateness_ms"`
	InferenceElapsedMS     *float64   `json:"inference_elapsed_ms"`
	InflightGatewayBatches int        `json:"inflight_gateway_batches"`
	GatewayBufferFrames    int        `json:"gateway_buffer_frames"`
	InferenceStatus        *int       `json:"inference_status"`
	Retryable              bool       `json:"retryable"`
}

type startMessage struct {
	Type string `json:"type"`
}

func ParseStartMessage(data []byte) error {
	var msg startMessage
	if err := strictDecode(data, &msg); err != nil {
		return err
	}
	if msg.Type != "start" {
		return fmt.Errorf("expected start message, got type %q", msg.Type)
	}
	return nil
}

func IsPCMFrame(payload []byte) bool {
	return len(payload) == FrameBytes
}

func DecodePrediction(data []byte) (Prediction, error) {
	var prediction Prediction
	if err := strictDecode(data, &prediction); err != nil {
		return Prediction{}, err
	}
	if err := prediction.Validate(); err != nil {
		return Prediction{}, err
	}
	return prediction, nil
}

func (p Prediction) Validate() error {
	if math.IsNaN(p.RMS) || math.IsInf(p.RMS, 0) {
		return errors.New("rms must be finite")
	}
	if p.Samples == 0 {
		return errors.New("samples must be positive")
	}
	if p.AudioBytes == 0 {
		return errors.New("audio_bytes must be positive")
	}
	return nil
}

func NewPartialMessage(
	prediction Prediction,
	oldestSeq uint64,
	newestSeq uint64,
	frames int,
	cpuPasses uint32,
	modelDelayMS uint64,
	flushLatenessMS float64,
) PartialMessage {
	return PartialMessage{
		Type:              PartialType,
		OldestFrameSeq:    oldestSeq,
		NewestFrameSeq:    newestSeq,
		Frames:            frames,
		RMS:               prediction.RMS,
		ZeroCrossings:     prediction.ZeroCrossings,
		Checksum:          prediction.Checksum,
		Samples:           prediction.Samples,
		Transcript:        prediction.Transcript,
		AudioBytes:        prediction.AudioBytes,
		CPUPasses:         cpuPasses,
		ModelDelayMS:      modelDelayMS,
		FlushLatenessMS:   flushLatenessMS,
		InflightModelJobs: 0,
	}
}

func MarshalPartialMessage(message PartialMessage) ([]byte, error) {
	message.FlushLatenessMS = RoundMillis(message.FlushLatenessMS)
	return json.Marshal(message)
}

func MarshalErrorMessage(message ErrorMessage) ([]byte, error) {
	message.OldestAgeMS = RoundMillis(message.OldestAgeMS)
	message.NewestAgeMS = RoundMillis(message.NewestAgeMS)
	message.FlushLatenessMS = RoundMillis(message.FlushLatenessMS)
	if message.InferenceElapsedMS != nil {
		rounded := RoundMillis(*message.InferenceElapsedMS)
		message.InferenceElapsedMS = &rounded
	}
	return json.Marshal(message)
}

func RoundMillis(value float64) float64 {
	return math.Round(value*1000) / 1000
}

func Float64Ptr(value float64) *float64 {
	return &value
}

func strictDecode(data []byte, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("unexpected trailing JSON value")
		}
		return err
	}
	return nil
}

package inference

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/cezarc1/websocket-stt-bench/services/go-nethttp/internal/protocol"
	"golang.org/x/net/http2"
)

const CPUPassesHeader = "x-cpu-passes"

type Details struct {
	Stage     protocol.ErrorStage
	Kind      protocol.ErrorKind
	Message   string
	Status    *int
	Retryable bool
}

func (d Details) Error() string {
	return d.Message
}

type Client struct {
	endpoint string
	timeout  time.Duration
	clients  []*http.Client
	next     atomic.Uint64
}

func NewHTTP1Client(baseURL string, timeout time.Duration) *Client {
	return &Client{
		endpoint: endpoint(baseURL),
		timeout:  timeout,
		clients:  []*http.Client{{}},
	}
}

func NewH2CClientPool(baseURL string, timeout time.Duration, clients int) *Client {
	if clients < 1 {
		clients = 1
	}
	pool := make([]*http.Client, 0, clients)
	for range clients {
		pool = append(pool, &http.Client{
			Transport: &http2.Transport{
				AllowHTTP: true,
				DialTLSContext: func(ctx context.Context, network, addr string, _ *tls.Config) (net.Conn, error) {
					var dialer net.Dialer
					return dialer.DialContext(ctx, network, addr)
				},
			},
		})
	}
	return &Client{
		endpoint: endpoint(baseURL),
		timeout:  timeout,
		clients:  pool,
	}
}

func (c *Client) Infer(ctx context.Context, body []byte, cpuPasses uint32) (protocol.Prediction, error) {
	ctx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()

	request, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return protocol.Prediction{}, ClassifyRequest(err)
	}
	request.Header.Set(CPUPassesHeader, strconv.FormatUint(uint64(cpuPasses), 10))

	response, err := c.client().Do(request)
	if err != nil {
		return protocol.Prediction{}, ClassifyRequest(err)
	}
	defer func() {
		_ = response.Body.Close()
	}()

	if response.StatusCode < 200 || response.StatusCode >= 300 {
		_, _ = io.Copy(io.Discard, response.Body)
		return protocol.Prediction{}, ClassifyStatus(response.StatusCode)
	}

	payload, err := io.ReadAll(response.Body)
	if err != nil {
		return protocol.Prediction{}, ClassifyRequest(err)
	}
	prediction, err := protocol.DecodePrediction(payload)
	if err != nil {
		return protocol.Prediction{}, ClassifyParse(err)
	}
	return prediction, nil
}

func ClassifyStatus(status int) Details {
	if status == http.StatusTooManyRequests {
		return Details{
			Stage:     protocol.StageInferenceRequest,
			Kind:      protocol.KindHTTP429,
			Message:   fmt.Sprintf("inference returned status %d", status),
			Status:    &status,
			Retryable: true,
		}
	}
	return Details{
		Stage:     protocol.StageInferenceRequest,
		Kind:      protocol.KindHTTP5xx,
		Message:   fmt.Sprintf("inference returned status %d", status),
		Status:    &status,
		Retryable: status >= 500,
	}
}

func ClassifyParse(err error) Details {
	return Details{
		Stage:     protocol.StageInferenceResponseParse,
		Kind:      protocol.KindParseError,
		Message:   err.Error(),
		Status:    nil,
		Retryable: false,
	}
}

func ClassifyRequest(err error) Details {
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return Details{
			Stage:     protocol.StageInferenceRequest,
			Kind:      protocol.KindTimeout,
			Message:   err.Error(),
			Retryable: true,
		}
	}

	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return Details{
			Stage:     protocol.StageInferenceRequest,
			Kind:      protocol.KindTimeout,
			Message:   err.Error(),
			Retryable: true,
		}
	}

	var urlErr *url.Error
	if errors.As(err, &urlErr) {
		if errors.Is(urlErr.Err, context.DeadlineExceeded) || errors.Is(urlErr.Err, context.Canceled) {
			return Details{
				Stage:     protocol.StageInferenceRequest,
				Kind:      protocol.KindTimeout,
				Message:   err.Error(),
				Retryable: true,
			}
		}
	}

	return Details{
		Stage:     protocol.StageInferenceRequest,
		Kind:      protocol.KindConnectionReset,
		Message:   err.Error(),
		Retryable: true,
	}
}

func AsDetails(err error) Details {
	var details Details
	if errors.As(err, &details) {
		return details
	}
	return ClassifyRequest(err)
}

func endpoint(baseURL string) string {
	return strings.TrimRight(baseURL, "/") + "/infer"
}

func (c *Client) client() *http.Client {
	index := c.next.Add(1) - 1
	return c.clients[int(index%uint64(len(c.clients)))]
}

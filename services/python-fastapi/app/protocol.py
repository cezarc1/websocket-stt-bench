from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from pydantic import BaseModel, ConfigDict

FRAME_BYTES = 640


class ErrorStage(StrEnum):
    WEBSOCKET_RECEIVE = "websocket_receive"
    BATCH_FLUSH = "batch_flush"
    INFERENCE_REQUEST = "inference_request"
    INFERENCE_RESPONSE_PARSE = "inference_response_parse"
    WEBSOCKET_SEND = "websocket_send"


class ErrorKind(StrEnum):
    TIMEOUT = "timeout"
    POOL_TIMEOUT = "pool_timeout"
    HTTP_5XX = "http_5xx"
    HTTP_429 = "http_429"
    CONNECTION_RESET = "connection_reset"
    PARSE_ERROR = "parse_error"
    SEND_ERROR = "send_error"


@dataclass(slots=True, frozen=True)
class Frame:
    seq: int
    payload: bytes
    # time.perf_counter() at WS receipt; default 0.0 for tests that construct
    # Frames synthetically and don't measure age.
    received_at: float = 0.0


class MessageType(StrEnum):
    START = "start"
    PARTIAL = "partial"
    ERROR = "error"


class StartMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: MessageType = MessageType.START


class Prediction(BaseModel):
    model_config = ConfigDict(extra="forbid")

    rms: float
    zero_crossings: int
    checksum: int
    samples: int
    transcript: str
    audio_bytes: int


class PartialMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: MessageType = MessageType.PARTIAL
    oldest_frame_seq: int
    newest_frame_seq: int
    frames: int
    rms: float
    zero_crossings: int
    checksum: int
    samples: int
    transcript: str
    audio_bytes: int
    cpu_passes: int
    model_delay_ms: int
    flush_lateness_ms: float
    inflight_model_jobs: int


class ErrorMessage(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: MessageType = MessageType.ERROR
    stage: ErrorStage
    kind: ErrorKind
    message: str
    # Batch identity
    oldest_frame_seq: int
    newest_frame_seq: int
    frames: int
    audio_bytes: int
    # Timing (ms)
    oldest_age_ms: float
    newest_age_ms: float
    flush_lateness_ms: float
    inference_elapsed_ms: float | None
    # Gateway pressure at the moment the error was emitted
    inflight_gateway_batches: int
    gateway_buffer_frames: int
    # Inference response info (None if no response was received)
    inference_status: int | None
    # Whether the client should expect more partials on this connection
    retryable: bool


Message = StartMessage | PartialMessage | ErrorMessage

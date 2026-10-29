"""Gateway protocol behavior against a real Starlette WebSocket (no server needed).

The gateway gets a genuine ``starlette.websockets.WebSocket`` driven by fake ASGI
receive/send callables, so every Starlette helper (receive_json, iter_bytes,
close, ...) runs for real. Messages mimic Granian: a binary frame carries only
"bytes", a text frame only "text" (the missing key is what made Starlette's
receive_json/iter_bytes raise KeyError and drop the socket without a close code).
"""

from __future__ import annotations

import asyncio
import json
from typing import Any, cast

import pytest
from fastapi import WebSocket
from starlette.types import Message
from starlette.websockets import WebSocketDisconnect

import app.session as session_mod
from app.inference import InferenceError
from app.main import stt_socket
from app.protocol import FRAME_BYTES, ErrorKind, ErrorStage, Prediction
from app.session import SttSession


def text(data: str) -> Message:
    return {"type": "websocket.receive", "text": data}


def binary(data: bytes) -> Message:
    return {"type": "websocket.receive", "bytes": data}


START = text('{"type":"start"}')
DISCONNECT: Message = {"type": "websocket.disconnect", "code": 1000}


def frame(seq: int) -> bytes:
    return seq.to_bytes(4, "little") * (FRAME_BYTES // 4)


class FakeClient:
    """ASGI peer: feeds ``inbox`` to a real WebSocket and records what it sends."""

    def __init__(self, *messages: Message) -> None:
        self.inbox: asyncio.Queue[Message] = asyncio.Queue()
        self.inbox.put_nowait({"type": "websocket.connect"})
        for message in messages:
            self.inbox.put_nowait(message)
        self.outbox: list[Message] = []
        # Set when the handler raised, i.e. the ASGI server would drop the
        # socket without a close frame (client sees 1006).
        self.error: BaseException | None = None
        scope = {"type": "websocket", "path": "/ws/stt", "headers": [], "query_string": b""}
        self.websocket = WebSocket(scope, self._receive, self._send)

    async def _receive(self) -> Message:
        return await self.inbox.get()

    async def _send(self, message: Message) -> None:
        self.outbox.append(message)

    @property
    def close_code(self) -> int | None:
        codes = [m["code"] for m in self.outbox if m["type"] == "websocket.close"]
        return codes[0] if codes else None

    @property
    def sent(self) -> list[dict[str, Any]]:
        return [json.loads(m["text"]) for m in self.outbox if m["type"] == "websocket.send"]


def run_socket(*messages: Message) -> FakeClient:
    async def scenario() -> FakeClient:
        client = FakeClient(*messages)
        try:
            await asyncio.wait_for(stt_socket(client.websocket, cast(Any, None)), 2)
        except Exception as exc:  # recorded; asserted via close_code
            client.error = exc
        return client

    return asyncio.run(scenario())


async def started_session(client: FakeClient, flush_interval_ms: int) -> SttSession:
    """Accept + consume start (stt_socket does this in prod), then build a session."""
    await client.websocket.accept()
    await client.websocket.receive()
    return SttSession(
        client.websocket,
        cast(Any, None),
        cpu_passes=4,
        model_delay_ms=75,
        flush_interval_ms=flush_interval_ms,
        flush_phase_jitter_ms=0,
    )


@pytest.mark.parametrize(
    "first",
    [
        text("not-json"),
        text('{"type":"stop"}'),
        text("{}"),
        text("[]"),
        binary(frame(1)),
    ],
    ids=["non-json", "wrong-type", "empty-object", "array", "binary-first"],
)
def test_invalid_first_message_closes_1002(first: dict[str, Any]) -> None:
    client = run_socket(first)
    assert client.close_code == 1002, client.error


@pytest.mark.parametrize("size", [0, 10, FRAME_BYTES - 1, FRAME_BYTES + 1])
def test_invalid_frame_size_closes_1003(size: int) -> None:
    client = run_socket(START, binary(b"\0" * size))
    assert client.close_code == 1003, client.error


def test_text_after_start_closes_1002() -> None:
    client = run_socket(START, binary(frame(1)), text("hello"))
    assert client.close_code == 1002, client.error


def test_disconnect_returns_without_close() -> None:
    for client in (run_socket(DISCONNECT), run_socket(START, binary(frame(1)), DISCONNECT)):
        # Starlette may surface the peer's close as WebSocketDisconnect; anything
        # else escaping the handler is a bug.
        assert client.error is None or isinstance(client.error, WebSocketDisconnect)
        assert client.close_code is None


def fake_prediction(body: bytes) -> Prediction:
    return Prediction(
        rms=0.0,
        zero_crossings=0,
        checksum=hash(body) & 0xFFFFFFFF,
        samples=len(body) // 2,
        transcript="x",
        audio_bytes=len(body),
    )


def stream(
    monkeypatch: pytest.MonkeyPatch, inference_delay_s: float, fail_every: int = 0
) -> tuple[list[dict[str, Any]], list[bytes]]:
    """Stream 60 frames at 5 ms into a session flushing every 20 ms, with an
    inference call slower than the flush interval so flushes are skipped while
    one is in flight (back-pressure). Returns emitted messages and the bodies
    the gateway posted."""
    bodies: list[bytes] = []

    async def fake_run_inference(_client: object, cpu_passes: int, body: bytes) -> Prediction:
        assert cpu_passes == 4
        bodies.append(body)
        await asyncio.sleep(inference_delay_s)
        if fail_every and len(bodies) % fail_every == 0:
            raise InferenceError(
                stage=ErrorStage.INFERENCE_REQUEST,
                kind=ErrorKind.HTTP_5XX,
                message="boom",
                inference_status=503,
                retryable=True,
            )
        return fake_prediction(body)

    monkeypatch.setattr(session_mod, "run_inference", fake_run_inference)

    async def scenario() -> list[dict[str, Any]]:
        ws = FakeClient(START)
        session = await started_session(ws, flush_interval_ms=20)
        task = asyncio.create_task(session.run())
        for seq in range(1, 61):
            ws.inbox.put_nowait(binary(frame(seq)))
            await asyncio.sleep(0.005)
        # Let every buffered frame flush before disconnecting.
        await asyncio.sleep(inference_delay_s * 4 + 0.2)
        ws.inbox.put_nowait(DISCONNECT)
        await asyncio.wait_for(task, 2)
        return ws.sent

    return asyncio.run(scenario()), bodies


def assert_tiles_all_frames(sent: list[dict[str, Any]], bodies: list[bytes]) -> None:
    """Partials and error frames tile 1..=60 with no gap/overlap, and each
    posted body is exactly its frames concatenated in seq order."""
    assert len(sent) == len(bodies)
    prev_newest = 0
    for message, body in zip(sent, bodies, strict=True):
        oldest, newest = message["oldest_frame_seq"], message["newest_frame_seq"]
        assert oldest == prev_newest + 1
        assert message["frames"] == newest - oldest + 1
        assert message["audio_bytes"] == message["frames"] * FRAME_BYTES
        assert body == b"".join(frame(seq) for seq in range(oldest, newest + 1))
        prev_newest = newest
    assert prev_newest == 60


def test_partials_cover_every_frame_in_order_under_backpressure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sent, bodies = stream(monkeypatch, inference_delay_s=0.05)
    assert all(m["type"] == "partial" for m in sent)
    # Slower-than-flush inference forces multi-tick batches (one in flight).
    assert any(m["frames"] > 4 for m in sent)
    assert_tiles_all_frames(sent, bodies)
    for message in sent:
        assert message["cpu_passes"] == 4
        assert message["model_delay_ms"] == 75
        assert set(message) >= {
            "oldest_frame_seq",
            "newest_frame_seq",
            "flush_lateness_ms",
            "inflight_model_jobs",
        }


def test_error_frames_consume_their_range(monkeypatch: pytest.MonkeyPatch) -> None:
    sent, bodies = stream(monkeypatch, inference_delay_s=0.01, fail_every=2)
    assert {m["type"] for m in sent} == {"partial", "error"}
    assert_tiles_all_frames(sent, bodies)


def test_one_inflight_inference_per_connection(monkeypatch: pytest.MonkeyPatch) -> None:
    active = 0
    peak = 0

    async def fake_run_inference(_client: object, _passes: int, body: bytes) -> Prediction:
        nonlocal active, peak
        active += 1
        peak = max(peak, active)
        await asyncio.sleep(0.05)
        active -= 1
        return fake_prediction(body)

    monkeypatch.setattr(session_mod, "run_inference", fake_run_inference)

    async def scenario() -> None:
        ws = FakeClient(START, *(binary(frame(seq)) for seq in range(1, 11)))
        session = await started_session(ws, flush_interval_ms=5)
        task = asyncio.create_task(session.run())
        for seq in range(11, 41):
            await asyncio.sleep(0.003)
            ws.inbox.put_nowait(binary(frame(seq)))
        await asyncio.sleep(0.3)
        ws.inbox.put_nowait(DISCONNECT)
        await asyncio.wait_for(task, 2)

    asyncio.run(scenario())
    assert peak == 1

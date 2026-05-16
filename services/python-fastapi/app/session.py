from __future__ import annotations

import asyncio
import logging
import random
import time
from dataclasses import dataclass, field

import aiohttp
from fastapi import WebSocket

from app.config import PARTIAL_CHANNEL_DEPTH
from app.inference import InferenceError, run_inference
from app.protocol import (
    FRAME_BYTES,
    ErrorMessage,
    Frame,
    PartialMessage,
    Prediction,
)

logger = logging.getLogger(__name__)


@dataclass(slots=True, frozen=True)
class BatchContext:
    batch: list[Frame]
    body: bytes
    flush_lateness_ms: float
    started_at: float

    @property
    def oldest(self) -> Frame:
        return self.batch[0]

    @property
    def newest(self) -> Frame:
        return self.batch[-1]

    @property
    def inference_elapsed_ms(self) -> float:
        return (time.perf_counter() - self.started_at) * 1000


@dataclass(slots=True)
class SttSession:
    websocket: WebSocket
    inference_client: aiohttp.ClientSession
    cpu_passes: int
    model_delay_ms: int
    flush_interval_ms: int
    flush_phase_jitter_ms: int
    buffer: list[Frame] = field(default_factory=list, init=False)
    outbox: asyncio.Queue[str] = field(
        default_factory=lambda: asyncio.Queue(maxsize=PARTIAL_CHANNEL_DEPTH), init=False
    )
    inflight: asyncio.Task[None] | None = field(default=None, init=False)
    seq: int = field(default=0, init=False)

    async def run(self) -> None:
        async with asyncio.TaskGroup() as tg:
            flusher = tg.create_task(self._flush_loop())
            writer = tg.create_task(self._writer_loop())
            try:
                async for payload in self.websocket.iter_bytes():
                    if len(payload) != FRAME_BYTES:
                        await self.websocket.close(code=1003, reason="expected 640 byte PCM frame")
                        return
                    self.seq += 1
                    self.buffer.append(
                        Frame(seq=self.seq, payload=payload, received_at=time.perf_counter())
                    )
            finally:
                flusher.cancel()
                writer.cancel()
                if self.inflight is not None and self.inflight.cancel():
                    try:
                        async with asyncio.timeout(5.0):
                            await self.inflight
                    except TimeoutError:
                        logger.warning("inflight inference did not cancel within 5s; abandoning")
                    except asyncio.CancelledError:
                        pass
                self.inflight = None

    async def _flush_loop(self) -> None:
        # One-time phase jitter de-syncs sessions that connect in a burst.
        flush_interval_s = self.flush_interval_ms / 1000.0
        initial_jitter_s = random.uniform(0, self.flush_phase_jitter_ms / 1000.0)
        next_due = time.perf_counter() + flush_interval_s + initial_jitter_s
        while True:
            await asyncio.sleep(max(0.0, next_due - time.perf_counter()))
            flush_lateness_ms = max(0.0, (time.perf_counter() - next_due) * 1000)
            next_due += flush_interval_s
            if (
                has_inflight := self.inflight is not None and not self.inflight.done()
            ) or not self.buffer:
                logger.warning(
                    "flush loop skipped: inflight=%s buffer=len(%s)",
                    has_inflight,
                    len(self.buffer),
                )
                continue

            ctx = BatchContext(
                batch=self.buffer,
                body=b"".join(frame.payload for frame in self.buffer),
                flush_lateness_ms=flush_lateness_ms,
                started_at=time.perf_counter(),
            )
            self.buffer = []
            self.inflight = asyncio.create_task(self._process_batch(ctx))

    async def _writer_loop(self) -> None:
        # Decouples websocket writes from the inflight slot so the slot's lifetime
        # tracks inference, not send_text under loop saturation. Mirrors the Rust
        # gateway's mpsc writer in services/rust-axum/src/session.rs.
        while True:
            text = await self.outbox.get()
            await self.websocket.send_text(text)

    async def _process_batch(self, ctx: BatchContext) -> None:
        try:
            pred = await run_inference(self.inference_client, self.cpu_passes, ctx.body)
        except InferenceError as err:
            logger.exception(
                "inference request failed stage=%s kind=%s: %s", err.stage, err.kind, err.message
            )
            await self.outbox.put(self._build_error_text(ctx, err))
            return
        await self.outbox.put(self._build_partial_text(ctx, pred))

    def _build_partial_text(self, ctx: BatchContext, pred: Prediction) -> str:
        return PartialMessage(
            oldest_frame_seq=ctx.oldest.seq,
            newest_frame_seq=ctx.newest.seq,
            frames=len(ctx.batch),
            cpu_passes=self.cpu_passes,
            model_delay_ms=self.model_delay_ms,
            flush_lateness_ms=round(ctx.flush_lateness_ms, 3),
            inflight_model_jobs=0,
            **pred.model_dump(),
        ).model_dump_json()

    def _build_error_text(self, ctx: BatchContext, err: InferenceError) -> str:
        now = time.perf_counter()
        return ErrorMessage(
            stage=err.stage,
            kind=err.kind,
            message=err.message,
            oldest_frame_seq=ctx.oldest.seq,
            newest_frame_seq=ctx.newest.seq,
            frames=len(ctx.batch),
            audio_bytes=len(ctx.body),
            oldest_age_ms=round((now - ctx.oldest.received_at) * 1000, 3),
            newest_age_ms=round((now - ctx.newest.received_at) * 1000, 3),
            flush_lateness_ms=round(ctx.flush_lateness_ms, 3),
            inference_elapsed_ms=round(ctx.inference_elapsed_ms, 3),
            # Always 1: one-inflight-per-connection invariant from CLAUDE.md.
            inflight_gateway_batches=1,
            gateway_buffer_frames=len(self.buffer),
            inference_status=err.inference_status,
            retryable=err.retryable,
        ).model_dump_json()

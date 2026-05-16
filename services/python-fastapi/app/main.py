from __future__ import annotations

import asyncio
import logging
import sys
from collections.abc import AsyncGenerator
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, WebSocket
from pydantic import ValidationError

from app.config import (
    DEFAULT_CPU_PASSES,
    DEFAULT_FLUSH_INTERVAL_MS,
    DEFAULT_FLUSH_PHASE_JITTER_MS,
    DEFAULT_MODEL_DELAY_MS,
    settings_int,
)
from app.dependencies import InferenceClientDep, close_inference_client
from app.protocol import StartMessage
from app.runtime import assert_runtime, log_runtime_versions
from app.session import SttSession


def configure_logging() -> None:
    package_logger = logging.getLogger("app")
    package_logger.setLevel(logging.INFO)
    package_logger.propagate = False
    if not package_logger.handlers:
        _handler = logging.StreamHandler(sys.stderr)
        _handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
        package_logger.addHandler(_handler)


logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app_: FastAPI) -> AsyncGenerator[None]:
    configure_logging()
    logger.info("Server starting...")
    assert_runtime()
    log_runtime_versions(logger)

    # Bound the per-loop default ThreadPoolExecutor to WORKER_THREADS. asyncio's
    # default executor (when not set) sizes itself to min(32, os.cpu_count()+4) per
    # loop, which under Granian mt mode (N loops) becomes N*32 threads -- too noisy
    # for a benchmark comparing runtimes by configured worker count. The gateway's
    # hot path is pure async I/O (aiohttp + Pydantic), so nothing currently submits
    # work to this executor; it is bounded scaffolding for predictability and for
    # parity with the Rust services, which use WORKER_THREADS to size their Tokio
    # runtime.
    workers = settings_int("WORKER_THREADS", 1)
    executor = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="app-worker-")
    asyncio.get_running_loop().set_default_executor(executor)
    logger.info("Server started w/ %d workers", workers)

    yield

    logger.warning("Server stopping...")
    await close_inference_client()
    executor.shutdown(wait=False, cancel_futures=True)


app = FastAPI(title="websocket-stt-bench FastAPI", lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, Any]:
    return {"ok": True, "runtime": "python-fastapi"}


@app.websocket("/ws/stt")
async def stt_socket(websocket: WebSocket, inference_client: InferenceClientDep) -> None:
    await websocket.accept()
    try:
        StartMessage.model_validate(await websocket.receive_json())
    except TypeError, ValueError, ValidationError:
        logger.exception("invalid start message")
        await websocket.close(code=1002, reason="first message must be start")
        return
    await SttSession(
        websocket,
        inference_client,
        cpu_passes=settings_int("CPU_PASSES", DEFAULT_CPU_PASSES),
        model_delay_ms=settings_int("MODEL_DELAY_MS", DEFAULT_MODEL_DELAY_MS),
        flush_interval_ms=max(1, settings_int("FLUSH_INTERVAL_MS", DEFAULT_FLUSH_INTERVAL_MS)),
        flush_phase_jitter_ms=settings_int("FLUSH_PHASE_JITTER_MS", DEFAULT_FLUSH_PHASE_JITTER_MS),
    ).run()

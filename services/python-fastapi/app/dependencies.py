from __future__ import annotations

import asyncio
import os
import threading
import weakref
from typing import Annotated

import aiohttp
from fastapi import Depends

from app.config import DEFAULT_INFERENCE_URL

_clients: weakref.WeakKeyDictionary[asyncio.AbstractEventLoop, aiohttp.ClientSession] = (
    weakref.WeakKeyDictionary()
)
_clients_lock = threading.Lock()


def _new_inference_client() -> aiohttp.ClientSession:
    timeout = aiohttp.ClientTimeout(
        total=None,
        connect=1.0,
        sock_connect=1.0,
        sock_read=2.0,
    )
    connector = aiohttp.TCPConnector(limit=1024, limit_per_host=1024, keepalive_timeout=60.0)
    return aiohttp.ClientSession(
        base_url=os.getenv("INFERENCE_URL", DEFAULT_INFERENCE_URL).rstrip("/"),
        connector=connector,
        timeout=timeout,
    )


async def get_inference_client() -> aiohttp.ClientSession:
    loop = asyncio.get_running_loop()
    with _clients_lock:
        client = _clients.get(loop)
        if client is None or client.closed:
            client = _new_inference_client()
            _clients[loop] = client
        return client


async def close_inference_client() -> None:
    loop = asyncio.get_running_loop()
    with _clients_lock:
        client = _clients.pop(loop, None)
    if client is not None:
        await client.close()


type InferenceClientDep = Annotated[aiohttp.ClientSession, Depends(get_inference_client)]

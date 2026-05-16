from __future__ import annotations

import asyncio

from aiohttp import ClientSession

from app.dependencies import close_inference_client, get_inference_client


def test_inference_client_is_reused_within_event_loop() -> None:
    async def scenario() -> None:
        first = await get_inference_client()
        second = await get_inference_client()

        assert first is second
        assert isinstance(first, ClientSession)
        assert not first.closed

        await close_inference_client()
        assert first.closed

        third = await get_inference_client()
        assert third is not first
        await close_inference_client()

    asyncio.run(scenario())

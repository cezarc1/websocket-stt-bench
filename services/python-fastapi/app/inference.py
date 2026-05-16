import json
from dataclasses import dataclass
from typing import NamedTuple

import aiohttp
from pydantic import ValidationError

from app.protocol import ErrorKind, ErrorStage, Prediction


@dataclass(slots=True, frozen=True)
class InferenceError(Exception):
    stage: ErrorStage
    kind: ErrorKind
    message: str
    inference_status: int | None
    retryable: bool

    def __post_init__(self) -> None:
        super().__init__(self.message)


class InferenceErrorDetails(NamedTuple):
    stage: ErrorStage
    kind: ErrorKind
    inference_status: int | None
    retryable: bool


def _classify_client_error(exc: Exception) -> InferenceErrorDetails:
    if isinstance(exc, TimeoutError):
        return InferenceErrorDetails(
            stage=ErrorStage.INFERENCE_REQUEST,
            kind=ErrorKind.TIMEOUT,
            inference_status=None,
            retryable=True,
        )
    if isinstance(exc, aiohttp.ClientResponseError):
        status = exc.status
        if status == 429:
            return InferenceErrorDetails(
                stage=ErrorStage.INFERENCE_REQUEST,
                kind=ErrorKind.HTTP_429,
                inference_status=status,
                retryable=True,
            )
        if 500 <= status < 600:
            return InferenceErrorDetails(
                stage=ErrorStage.INFERENCE_REQUEST,
                kind=ErrorKind.HTTP_5XX,
                inference_status=status,
                retryable=True,
            )
        return InferenceErrorDetails(
            stage=ErrorStage.INFERENCE_REQUEST,
            kind=ErrorKind.HTTP_5XX,
            inference_status=status,
            retryable=False,
        )
    if isinstance(exc, aiohttp.ClientError):
        return InferenceErrorDetails(
            stage=ErrorStage.INFERENCE_REQUEST,
            kind=ErrorKind.CONNECTION_RESET,
            inference_status=None,
            retryable=True,
        )
    if isinstance(exc, json.JSONDecodeError | ValidationError):
        return InferenceErrorDetails(
            stage=ErrorStage.INFERENCE_RESPONSE_PARSE,
            kind=ErrorKind.PARSE_ERROR,
            inference_status=None,
            retryable=False,
        )
    return InferenceErrorDetails(
        stage=ErrorStage.INFERENCE_REQUEST,
        kind=ErrorKind.CONNECTION_RESET,
        inference_status=None,
        retryable=True,
    )


def _classify_status(status: int) -> InferenceErrorDetails | None:
    if 200 <= status < 300:
        return None
    if status == 429:
        return InferenceErrorDetails(
            stage=ErrorStage.INFERENCE_REQUEST,
            kind=ErrorKind.HTTP_429,
            inference_status=status,
            retryable=True,
        )
    if 500 <= status < 600:
        return InferenceErrorDetails(
            stage=ErrorStage.INFERENCE_REQUEST,
            kind=ErrorKind.HTTP_5XX,
            inference_status=status,
            retryable=True,
        )
    return InferenceErrorDetails(
        stage=ErrorStage.INFERENCE_REQUEST,
        kind=ErrorKind.HTTP_5XX,
        inference_status=status,
        retryable=False,
    )


def _raise_inference_error(details: InferenceErrorDetails, message: str) -> None:
    raise InferenceError(
        stage=details.stage,
        kind=details.kind,
        message=message,
        inference_status=details.inference_status,
        retryable=details.retryable,
    )


async def run_inference(
    inference_client: aiohttp.ClientSession, cpu_passes: int, body: bytes
) -> Prediction:
    try:
        async with inference_client.post(
            "/infer",
            data=body,
            headers={"x-cpu-passes": str(cpu_passes)},
        ) as response:
            if details := _classify_status(response.status):
                _raise_inference_error(details, f"HTTP {response.status}")
            payload = await response.read()
        return Prediction.model_validate_json(payload)
    except InferenceError:
        raise
    except json.JSONDecodeError as exc:
        stage, kind, status, retryable = _classify_client_error(exc)
        raise InferenceError(
            stage=stage,
            kind=kind,
            message=str(exc) or exc.__class__.__name__,
            inference_status=status,
            retryable=retryable,
        ) from exc
    except Exception as exc:
        stage, kind, status, retryable = _classify_client_error(exc)
        raise InferenceError(
            stage=stage,
            kind=kind,
            message=str(exc) or exc.__class__.__name__,
            inference_status=status,
            retryable=retryable,
        ) from exc

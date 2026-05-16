package stt.inference;

import stt.protocol.InferResponse;

/** Strategy for posting batched PCM to the inference server. */
@FunctionalInterface
public interface Inference {

    /**
     * Posts one PCM batch and returns the parsed inference response.
     *
     * @throws InferenceException on any classified failure (timeout, HTTP 4xx/5xx, parse, transport).
     */
    InferResponse infer(byte[] body, int cpuPasses);
}

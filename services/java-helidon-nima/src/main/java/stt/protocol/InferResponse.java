package stt.protocol;

import com.fasterxml.jackson.annotation.JsonProperty;

/** Response from the shared inference server. Wire shape is snake_case. */
public record InferResponse(
        double rms,
        @JsonProperty("zero_crossings") long zeroCrossings,
        long checksum,
        long samples,
        String transcript,
        @JsonProperty("audio_bytes") long audioBytes) {}

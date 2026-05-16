package stt.protocol;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import org.jspecify.annotations.Nullable;

/**
 * {@code error} message emitted whenever the gateway fails to produce a partial for a batch
 * (inference timeout, HTTP 5xx, parse failure, etc.). Field order mirrors the Rust / Go gateways.
 */
@JsonPropertyOrder({
    "type",
    "stage",
    "kind",
    "message",
    "oldest_frame_seq",
    "newest_frame_seq",
    "frames",
    "audio_bytes",
    "oldest_age_ms",
    "newest_age_ms",
    "flush_lateness_ms",
    "inference_elapsed_ms",
    "inflight_gateway_batches",
    "gateway_buffer_frames",
    "inference_status",
    "retryable"
})
public record ErrorMessage(
        String type,
        ErrorStage stage,
        ErrorKind kind,
        String message,
        @JsonProperty("oldest_frame_seq") long oldestFrameSeq,
        @JsonProperty("newest_frame_seq") long newestFrameSeq,
        int frames,
        @JsonProperty("audio_bytes") long audioBytes,
        @JsonProperty("oldest_age_ms") double oldestAgeMs,
        @JsonProperty("newest_age_ms") double newestAgeMs,
        @JsonProperty("flush_lateness_ms") double flushLatenessMs,
        @JsonProperty("inference_elapsed_ms") @Nullable Double inferenceElapsedMs,
        @JsonProperty("inflight_gateway_batches") int inflightGatewayBatches,
        @JsonProperty("gateway_buffer_frames") int gatewayBufferFrames,
        @JsonProperty("inference_status") @Nullable Integer inferenceStatus,
        boolean retryable)
        implements OutboundMessage {}

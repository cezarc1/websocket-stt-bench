package stt.protocol;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.annotation.JsonPropertyOrder;

/**
 * {@code partial} message sent back to the load generator on each successful flush. Field order
 * matches the Rust / Go gateways for line-by-line diff-ability.
 */
@JsonPropertyOrder({
    "type",
    "oldest_frame_seq",
    "newest_frame_seq",
    "frames",
    "rms",
    "zero_crossings",
    "checksum",
    "samples",
    "transcript",
    "audio_bytes",
    "cpu_passes",
    "model_delay_ms",
    "flush_lateness_ms",
    "inflight_model_jobs"
})
public record PartialMessage(
        String type,
        @JsonProperty("oldest_frame_seq") long oldestFrameSeq,
        @JsonProperty("newest_frame_seq") long newestFrameSeq,
        int frames,
        double rms,
        @JsonProperty("zero_crossings") long zeroCrossings,
        long checksum,
        long samples,
        String transcript,
        @JsonProperty("audio_bytes") long audioBytes,
        @JsonProperty("cpu_passes") int cpuPasses,
        @JsonProperty("model_delay_ms") long modelDelayMs,
        @JsonProperty("flush_lateness_ms") double flushLatenessMs,
        @JsonProperty("inflight_model_jobs") int inflightModelJobs)
        implements OutboundMessage {

    public static PartialMessage of(
            InferResponse infer,
            long oldestSeq,
            long newestSeq,
            int frames,
            int cpuPasses,
            long modelDelayMs,
            double flushLatenessMs) {
        return new PartialMessage(
                Protocol.PARTIAL_TYPE,
                oldestSeq,
                newestSeq,
                frames,
                infer.rms(),
                infer.zeroCrossings(),
                infer.checksum(),
                infer.samples(),
                infer.transcript(),
                infer.audioBytes(),
                cpuPasses,
                modelDelayMs,
                flushLatenessMs,
                0);
    }
}

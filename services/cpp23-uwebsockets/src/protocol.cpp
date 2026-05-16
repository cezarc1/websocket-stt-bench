#include "protocol.hpp"

namespace stt {

PartialMessage partial_from(const InferResponse& infer, const PartialContext& ctx) {
    return PartialMessage{
        .type = PARTIAL_TYPE,
        .oldest_frame_seq = ctx.oldest_frame_seq,
        .newest_frame_seq = ctx.newest_frame_seq,
        .frames = ctx.frames,
        .rms = infer.rms,
        .zero_crossings = infer.zero_crossings,
        .checksum = infer.checksum,
        .samples = infer.samples,
        .transcript = infer.transcript,
        .audio_bytes = infer.audio_bytes,
        .cpu_passes = ctx.cpu_passes,
        .model_delay_ms = ctx.model_delay_ms,
        .flush_lateness_ms = ctx.flush_lateness_ms,
        // inflight_model_jobs left at its in-class default of 0.
    };
}

}  // namespace stt

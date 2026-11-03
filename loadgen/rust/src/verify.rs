//! Client-side correctness checks for gateway responses.
//!
//! The load generator sends deterministic PCM (`frame_payload(session_id,
//! seq)`), so the exact stub output for any partial covering
//! `oldest..=newest` is computable on the client with the same `stt-stub`
//! implementation the inference server runs. A gateway that drops, reorders,
//! duplicates or misattributes frames, or forwards a stale/wrong inference
//! result, produces a partial whose numbers no longer match.
//!
//! Two independent checks:
//! - [`verify_partial`]: per-partial expected values (needs the PCM, so it
//!   costs one `compute_stub` over the batch — see the `verify_cost` bench).
//! - [`Continuity`]: per-session range bookkeeping. Successive partials *and*
//!   error frames must tile the frame sequence: `oldest == prev_newest + 1`.
//!   Error frames consume their range (gateways drain the batch and do not
//!   retry it), so they advance the tracker like a partial does.
//! - [`check_tail`]: continuity only fires on the *next* response, so a
//!   session whose last response(s) never arrive would pass. At session end
//!   the highest reported frame must be within [`TAIL_TOLERANCE_FRAMES`] of
//!   the last frame sent.

use std::{fmt, time::Duration};

use stt_stub::{StubResult, compute_stub};

use crate::protocol::{FLUSH_INTERVAL, FRAME_BYTES, FRAME_INTERVAL, PartialMessage, frame_payload};

/// Gateway default `INFERENCE_TIMEOUT_MS` (every gateway uses 2000 ms; the
/// charts and compose files do not override it). Bounds how long one
/// in-flight inference request can hold a session's next flush back.
pub const GATEWAY_INFERENCE_TIMEOUT: Duration = Duration::from_millis(2_000);

/// Audio a *correct* gateway may legitimately still owe when the client
/// closes (gateways need not drain on close). With flush interval `F` and
/// inference timeout `T`, the last delivered response for batch `k` (flushed
/// at `t_k`) arrived by `t_k + T`; the next tick fires within `F` of that;
/// its response takes up to `T`. So at close, frames sent after
/// `t_k` -- at most `F + 2T` of audio -- may be unreported. One more `F`
/// absorbs flush-tick lateness on a saturated gateway and client/network lag.
pub const TAIL_TOLERANCE: Duration = Duration::from_millis(
    2 * FLUSH_INTERVAL.as_millis() as u64 + 2 * GATEWAY_INFERENCE_TIMEOUT.as_millis() as u64,
);

/// [`TAIL_TOLERANCE`] in frames (300 at 20 ms frames).
pub const TAIL_TOLERANCE_FRAMES: u64 =
    (TAIL_TOLERANCE.as_millis() / FRAME_INTERVAL.as_millis()) as u64;

/// Absolute-or-relative tolerance for `rms` (an `f64` that crosses a JSON
/// round-trip in every gateway runtime).
pub const RMS_TOLERANCE: f64 = 1e-6;

/// Partials claiming more frames than this are not recomputed (10 minutes of
/// audio — far beyond any real flush). Guards the client against a gateway
/// bug that reports an absurd range.
pub const MAX_VERIFY_FRAMES: u64 = 30_000;

/// Configuration every gateway in a run is expected to echo back.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ExpectedConfig {
    pub cpu_passes: u32,
    pub model_delay_ms: u64,
}

impl Default for ExpectedConfig {
    /// Matches `CPU_PASSES` / `MODEL_DELAY_MS` in `docker-compose.yml` and
    /// `charts/stt-bench/values.yaml`.
    fn default() -> Self {
        Self {
            cpu_passes: 4,
            model_delay_ms: 75,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum MismatchKind {
    /// `oldest > prev_newest + 1`: frames were skipped.
    ContinuityGap,
    /// `oldest <= prev_newest`: frames repeated, or the range went backwards.
    ContinuityOverlap,
    /// `oldest == 0` or `newest < oldest`.
    InvalidRange,
    /// `newest` refers to a frame the client has not sent yet.
    UnsentFrame,
    /// Range is larger than [`MAX_VERIFY_FRAMES`]; values were not recomputed.
    RangeTooLarge,
    /// At session end, more than [`TAIL_TOLERANCE_FRAMES`] sent frames were
    /// never covered by any partial or error frame.
    MissingTail,
    Frames,
    AudioBytes,
    CpuPasses,
    ModelDelayMs,
    Checksum,
    ZeroCrossings,
    Samples,
    Rms,
    Transcript,
}

impl MismatchKind {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ContinuityGap => "continuity_gap",
            Self::ContinuityOverlap => "continuity_overlap",
            Self::InvalidRange => "invalid_range",
            Self::UnsentFrame => "unsent_frame",
            Self::RangeTooLarge => "range_too_large",
            Self::MissingTail => "missing_tail",
            Self::Frames => "frames",
            Self::AudioBytes => "audio_bytes",
            Self::CpuPasses => "cpu_passes",
            Self::ModelDelayMs => "model_delay_ms",
            Self::Checksum => "checksum",
            Self::ZeroCrossings => "zero_crossings",
            Self::Samples => "samples",
            Self::Rms => "rms",
            Self::Transcript => "transcript",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Mismatch {
    pub kind: MismatchKind,
    pub detail: String,
}

impl Mismatch {
    fn new(kind: MismatchKind, detail: String) -> Self {
        Self { kind, detail }
    }
}

impl fmt::Display for Mismatch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.kind.as_str(), self.detail)
    }
}

/// Rebuild the concatenated PCM a gateway should have sent to `/infer` for
/// frames `oldest..=newest` of `session_id`. Reuses `out`'s allocation.
pub fn concat_payload(session_id: usize, oldest: u64, newest: u64, out: &mut Vec<u8>) {
    out.clear();
    if newest < oldest {
        return;
    }
    out.reserve(((newest - oldest + 1) as usize).saturating_mul(FRAME_BYTES));
    for seq in oldest..=newest {
        out.extend_from_slice(&frame_payload(session_id, seq));
    }
}

/// Stub output for frames `oldest..=newest` of `session_id`.
pub fn expected_stub(
    session_id: usize,
    oldest: u64,
    newest: u64,
    cpu_passes: u32,
    scratch: &mut Vec<u8>,
) -> StubResult {
    concat_payload(session_id, oldest, newest, scratch);
    compute_stub(scratch, cpu_passes)
}

pub fn rms_matches(actual: f64, expected: f64) -> bool {
    let diff = (actual - expected).abs();
    diff <= RMS_TOLERANCE || diff <= RMS_TOLERANCE * expected.abs()
}

/// Check every value in `partial` against what the shared stub produces for
/// the frames it claims to cover. Returns all mismatches (empty == correct).
/// Does not check continuity; pair with [`Continuity::observe`].
pub fn verify_partial(
    session_id: usize,
    partial: &PartialMessage,
    expected: ExpectedConfig,
    scratch: &mut Vec<u8>,
) -> Vec<Mismatch> {
    let mut out = Vec::new();
    let (oldest, newest) = (partial.oldest_frame_seq, partial.newest_frame_seq);
    if oldest == 0 || newest < oldest {
        out.push(Mismatch::new(
            MismatchKind::InvalidRange,
            format!("oldest={oldest} newest={newest}"),
        ));
        return out;
    }
    let range = newest - oldest + 1;
    if partial.frames != range {
        out.push(Mismatch::new(
            MismatchKind::Frames,
            format!(
                "frames={} but range {oldest}..={newest} is {range}",
                partial.frames
            ),
        ));
    }
    let range_bytes = range.saturating_mul(FRAME_BYTES as u64);
    if partial.audio_bytes != range_bytes {
        out.push(Mismatch::new(
            MismatchKind::AudioBytes,
            format!("audio_bytes={} expected {range_bytes}", partial.audio_bytes),
        ));
    }
    if partial.cpu_passes != expected.cpu_passes {
        out.push(Mismatch::new(
            MismatchKind::CpuPasses,
            format!(
                "cpu_passes={} expected {}",
                partial.cpu_passes, expected.cpu_passes
            ),
        ));
    }
    if partial.model_delay_ms != expected.model_delay_ms {
        out.push(Mismatch::new(
            MismatchKind::ModelDelayMs,
            format!(
                "model_delay_ms={} expected {}",
                partial.model_delay_ms, expected.model_delay_ms
            ),
        ));
    }
    if range > MAX_VERIFY_FRAMES {
        out.push(Mismatch::new(
            MismatchKind::RangeTooLarge,
            format!("range of {range} frames exceeds {MAX_VERIFY_FRAMES}"),
        ));
        return out;
    }

    let want = expected_stub(session_id, oldest, newest, expected.cpu_passes, scratch);
    if partial.checksum != want.checksum {
        out.push(Mismatch::new(
            MismatchKind::Checksum,
            format!("checksum={} expected {}", partial.checksum, want.checksum),
        ));
    }
    if partial.zero_crossings != want.zero_crossings {
        out.push(Mismatch::new(
            MismatchKind::ZeroCrossings,
            format!(
                "zero_crossings={} expected {}",
                partial.zero_crossings, want.zero_crossings
            ),
        ));
    }
    if partial.samples != want.samples {
        out.push(Mismatch::new(
            MismatchKind::Samples,
            format!("samples={} expected {}", partial.samples, want.samples),
        ));
    }
    if !rms_matches(partial.rms, want.rms) {
        out.push(Mismatch::new(
            MismatchKind::Rms,
            format!("rms={} expected {}", partial.rms, want.rms),
        ));
    }
    if partial.transcript != want.transcript {
        out.push(Mismatch::new(
            MismatchKind::Transcript,
            format!(
                "transcript={:?} expected {:?}",
                partial.transcript, want.transcript
            ),
        ));
    }
    out
}

/// Per-session frame-range bookkeeping. Feed it every partial and error frame
/// in arrival order.
#[derive(Debug, Default, Clone, Copy)]
pub struct Continuity {
    last_newest: u64,
}

impl Continuity {
    /// Highest frame seq covered so far (0 before the first response).
    pub const fn last_newest(&self) -> u64 {
        self.last_newest
    }

    /// Record a response covering `oldest..=newest`. Returns a mismatch if
    /// the range does not start right after the previous one. For a
    /// well-formed range the tracker advances to `max(prev, newest)` either
    /// way, so one stale/duplicate response is reported once rather than
    /// poisoning every later check. A malformed range (`oldest == 0` or
    /// `newest < oldest`) is reported and does not move the tracker.
    pub fn observe(&mut self, oldest: u64, newest: u64) -> Option<Mismatch> {
        if oldest == 0 || newest < oldest {
            return Some(Mismatch::new(
                MismatchKind::InvalidRange,
                format!("oldest={oldest} newest={newest}"),
            ));
        }
        let expected = self.last_newest + 1;
        let mismatch = if oldest > expected {
            Some(Mismatch::new(
                MismatchKind::ContinuityGap,
                format!(
                    "oldest={oldest} expected {expected}: frames {expected}..={} never reported",
                    oldest - 1
                ),
            ))
        } else if oldest < expected {
            Some(Mismatch::new(
                MismatchKind::ContinuityOverlap,
                format!(
                    "range {oldest}..={newest} overlaps already-reported ..={}",
                    self.last_newest
                ),
            ))
        } else {
            None
        };
        self.last_newest = self.last_newest.max(newest);
        mismatch
    }
}

/// End-of-session check: `frames_sent` frames went out and responses covered
/// `..=last_reported`. Flags a tail longer than [`TAIL_TOLERANCE_FRAMES`]
/// that no partial or error frame ever reported.
pub fn check_tail(frames_sent: u64, last_reported: u64) -> Option<Mismatch> {
    let unreported = frames_sent.saturating_sub(last_reported);
    (unreported > TAIL_TOLERANCE_FRAMES).then(|| {
        Mismatch::new(
            MismatchKind::MissingTail,
            format!(
                "frames {}..={frames_sent} never reported ({unreported} frames; \
                 tolerance {TAIL_TOLERANCE_FRAMES})",
                last_reported + 1
            ),
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::GOLDEN_ONE_FRAME;

    const CFG: ExpectedConfig = ExpectedConfig {
        cpu_passes: 4,
        model_delay_ms: 75,
    };

    /// Partial whose values were computed from `payload_frames` (possibly
    /// corrupted) but that *claims* to cover `oldest..=newest`.
    fn partial_from(oldest: u64, newest: u64, frames: &[(usize, u64)]) -> PartialMessage {
        let payload: Vec<u8> = frames
            .iter()
            .flat_map(|&(session, seq)| frame_payload(session, seq))
            .collect();
        let stub = compute_stub(&payload, CFG.cpu_passes);
        PartialMessage {
            oldest_frame_seq: oldest,
            newest_frame_seq: newest,
            frames: frames.len() as u64,
            rms: stub.rms,
            zero_crossings: stub.zero_crossings,
            checksum: stub.checksum,
            samples: stub.samples,
            transcript: stub.transcript.to_string(),
            audio_bytes: stub.audio_bytes,
            cpu_passes: CFG.cpu_passes,
            model_delay_ms: CFG.model_delay_ms,
            flush_lateness_ms: 0.0,
            inflight_model_jobs: 1,
        }
    }

    fn honest(session: usize, oldest: u64, newest: u64) -> PartialMessage {
        let frames: Vec<_> = (oldest..=newest).map(|seq| (session, seq)).collect();
        partial_from(oldest, newest, &frames)
    }

    fn kinds(mismatches: &[Mismatch]) -> Vec<MismatchKind> {
        mismatches.iter().map(|m| m.kind).collect()
    }

    fn check(session: usize, partial: &PartialMessage) -> Vec<MismatchKind> {
        kinds(&verify_partial(session, partial, CFG, &mut Vec::new()))
    }

    #[test]
    fn matches_one_frame_golden() {
        let want = expected_stub(0, 1, 1, 4, &mut Vec::new());
        assert_eq!(want.checksum, GOLDEN_ONE_FRAME.checksum);
        assert_eq!(want.zero_crossings, GOLDEN_ONE_FRAME.zero_crossings);
        assert_eq!(want.samples, GOLDEN_ONE_FRAME.samples);
        assert_eq!(want.transcript, GOLDEN_ONE_FRAME.transcript);
        assert_eq!(want.audio_bytes, GOLDEN_ONE_FRAME.audio_bytes);
        assert!(rms_matches(want.rms, GOLDEN_ONE_FRAME.rms));
    }

    /// Pins a full 1 s flush (50 frames, non-zero session) so a change to the
    /// shared stub or `frame_payload` cannot silently stay self-consistent.
    #[test]
    fn matches_fifty_frame_golden() {
        let want = expected_stub(7_919, 1, 50, 4, &mut Vec::new());
        assert_eq!(want.samples, 64_000);
        assert_eq!(want.audio_bytes, 32_000);
        assert_eq!(want.checksum, GOLDEN_FIFTY_CHECKSUM);
        assert_eq!(want.zero_crossings, GOLDEN_FIFTY_ZERO_CROSSINGS);
        assert_eq!(want.transcript, GOLDEN_FIFTY_TRANSCRIPT);
        assert!(rms_matches(want.rms, GOLDEN_FIFTY_RMS), "rms {}", want.rms);
    }

    // Independently cross-checked against the Python reference impl
    // (`services/python-fastapi/app/stub.py::compute_stub` over the Python
    // port of `frame_payload`, see `test_loadgen_frame_payload_goldens`) on
    // frames 1..=50 of session 7919, 4 passes.
    const GOLDEN_FIFTY_CHECKSUM: u32 = 3_451_184_229;
    const GOLDEN_FIFTY_ZERO_CROSSINGS: u64 = 736;
    const GOLDEN_FIFTY_TRANSCRIPT: &str = "now";
    const GOLDEN_FIFTY_RMS: f64 = 5_956.275_069_978_719;

    #[test]
    fn honest_partials_pass() {
        assert!(check(0, &honest(0, 1, 1)).is_empty());
        assert!(check(7_919, &honest(7_919, 1, 50)).is_empty());
        assert!(check(3, &honest(3, 51, 137)).is_empty());
    }

    #[test]
    fn dropped_frame_is_detected() {
        // Gateway lost frame 25 but still reports 1..=50 and frames=49.
        let frames: Vec<_> = (1..=50).filter(|&s| s != 25).map(|s| (5, s)).collect();
        let got = check(5, &partial_from(1, 50, &frames));
        assert!(got.contains(&MismatchKind::Frames));
        assert!(got.contains(&MismatchKind::AudioBytes));
        assert!(got.contains(&MismatchKind::Checksum));
        assert!(got.contains(&MismatchKind::Samples));
    }

    #[test]
    fn dropped_frame_with_consistent_counts_is_detected() {
        // Worse bug: the gateway keeps counts consistent with the range by
        // duplicating a neighbour, so only the content gives it away.
        let frames: Vec<_> = (1..=50)
            .map(|s| (5, if s == 25 { 24 } else { s }))
            .collect();
        let got = check(5, &partial_from(1, 50, &frames));
        assert!(got.contains(&MismatchKind::Checksum));
        assert!(!got.contains(&MismatchKind::Frames));
    }

    #[test]
    fn reordered_frames_are_detected() {
        let mut frames: Vec<_> = (1..=50).map(|s| (5, s)).collect();
        frames.swap(10, 11);
        assert!(check(5, &partial_from(1, 50, &frames)).contains(&MismatchKind::Checksum));
    }

    #[test]
    fn swapped_session_is_detected() {
        // Result for session 202 delivered on session 101's socket.
        let got = check(101, &honest(202, 1, 50));
        assert!(got.contains(&MismatchKind::Checksum));
    }

    #[test]
    fn off_by_one_seq_is_detected() {
        // Stats are for 2..=51 but partial claims 1..=50.
        let frames: Vec<_> = (2..=51).map(|s| (5, s)).collect();
        assert!(check(5, &partial_from(1, 50, &frames)).contains(&MismatchKind::Checksum));
    }

    #[test]
    fn stale_result_is_detected() {
        // Previous batch's result re-sent with the new batch's range.
        let frames: Vec<_> = (1..=50).map(|s| (5, s)).collect();
        assert!(check(5, &partial_from(51, 100, &frames)).contains(&MismatchKind::Checksum));
    }

    // Aliasing cases the old linear `frame_payload` (period 125 frames, and
    // session s == s+160 shifted by one frame) let through undetected.

    #[test]
    fn stale_result_from_250_frames_back_is_detected() {
        let frames: Vec<_> = (1..=50).map(|s| (5, s)).collect();
        assert!(check(5, &partial_from(251, 300, &frames)).contains(&MismatchKind::Checksum));
    }

    #[test]
    fn frame_replaced_by_one_125_back_is_detected() {
        let frames: Vec<_> = (126..=175)
            .map(|s| (5, if s == 150 { s - 125 } else { s }))
            .collect();
        assert!(check(5, &partial_from(126, 175, &frames)).contains(&MismatchKind::Checksum));
    }

    #[test]
    fn session_aliased_by_160_is_detected() {
        // Old generator: frame (s+160, q) was byte-identical to (s, q+63), so
        // session s+160's result for 1..=50 passed as session s's 64..=113.
        for s in [0_usize, 5, 7_919] {
            let other: Vec<_> = (1..=50).map(|q| (s + 160, q)).collect();
            let got = check(s, &partial_from(64, 113, &other));
            assert!(got.contains(&MismatchKind::Checksum), "session {s}");
        }
    }

    #[test]
    fn config_and_field_tampering_is_detected() {
        let mut p = honest(5, 1, 50);
        p.cpu_passes = 3;
        p.model_delay_ms = 0;
        p.transcript = "nope".to_string();
        p.zero_crossings += 1;
        let got = check(5, &p);
        for kind in [
            MismatchKind::CpuPasses,
            MismatchKind::ModelDelayMs,
            MismatchKind::Transcript,
            MismatchKind::ZeroCrossings,
        ] {
            assert!(got.contains(&kind), "missing {kind:?} in {got:?}");
        }
    }

    #[test]
    fn computing_with_wrong_passes_is_detected() {
        // Gateway echoes the expected cpu_passes but forwarded a different
        // x-cpu-passes header to the inference server.
        let payload: Vec<u8> = (1..=50).flat_map(|s| frame_payload(5, s)).collect();
        let stub = compute_stub(&payload, 1);
        let mut p = honest(5, 1, 50);
        p.checksum = stub.checksum;
        p.samples = stub.samples;
        let got = check(5, &p);
        assert!(got.contains(&MismatchKind::Checksum));
        assert!(got.contains(&MismatchKind::Samples));
    }

    #[test]
    fn rms_tolerance() {
        let mut p = honest(5, 1, 50);
        p.rms *= 1.0 + 1e-9;
        assert!(check(5, &p).is_empty());
        // rms is ~6k, so the relative bound (~0.006) governs.
        p.rms += 0.1;
        assert_eq!(check(5, &p), vec![MismatchKind::Rms]);
        assert!(rms_matches(0.0, 5e-7));
        assert!(!rms_matches(0.0, 5e-6));
    }

    #[test]
    fn invalid_and_huge_ranges_short_circuit() {
        let mut p = honest(5, 1, 1);
        p.oldest_frame_seq = 0;
        assert_eq!(check(5, &p), vec![MismatchKind::InvalidRange]);
        p.oldest_frame_seq = 3;
        p.newest_frame_seq = 2;
        assert_eq!(check(5, &p), vec![MismatchKind::InvalidRange]);
        p.oldest_frame_seq = 1;
        p.newest_frame_seq = MAX_VERIFY_FRAMES + 1;
        assert!(check(5, &p).contains(&MismatchKind::RangeTooLarge));
    }

    #[test]
    fn continuity_accepts_tiling_ranges() {
        let mut c = Continuity::default();
        assert_eq!(c.observe(1, 50), None);
        assert_eq!(c.observe(51, 51), None);
        assert_eq!(c.observe(52, 120), None);
        assert_eq!(c.last_newest(), 120);
    }

    #[test]
    fn continuity_detects_gap_overlap_and_backwards() {
        let mut c = Continuity::default();
        // First response must start at frame 1.
        assert_eq!(
            c.observe(2, 50).map(|m| m.kind),
            Some(MismatchKind::ContinuityGap)
        );
        // Dropped frame 51.
        assert_eq!(
            c.observe(52, 100).map(|m| m.kind),
            Some(MismatchKind::ContinuityGap)
        );
        // Duplicate of the last frame.
        assert_eq!(
            c.observe(100, 150).map(|m| m.kind),
            Some(MismatchKind::ContinuityOverlap)
        );
        // Stale earlier batch re-delivered: reported once, does not poison.
        assert_eq!(
            c.observe(1, 50).map(|m| m.kind),
            Some(MismatchKind::ContinuityOverlap)
        );
        assert_eq!(c.observe(151, 200), None);
        assert_eq!(
            c.observe(202, 201).map(|m| m.kind),
            Some(MismatchKind::InvalidRange)
        );
        // A malformed range must not move the tracker (e.g. oldest=0 with a
        // huge newest would otherwise flag every later partial as overlap).
        assert_eq!(
            c.observe(0, 1_000_000).map(|m| m.kind),
            Some(MismatchKind::InvalidRange)
        );
        assert_eq!(c.last_newest(), 200);
        assert_eq!(c.observe(201, 250), None);
    }

    #[test]
    fn tail_tolerance_covers_flush_plus_two_inference_timeouts() {
        assert_eq!(TAIL_TOLERANCE, Duration::from_secs(6));
        assert_eq!(TAIL_TOLERANCE_FRAMES, 300);
        // Worst case for a correct gateway (F + 2T) fits with slack.
        let worst = FLUSH_INTERVAL + 2 * GATEWAY_INFERENCE_TIMEOUT;
        assert!(worst < TAIL_TOLERANCE);
    }

    #[test]
    fn tail_within_tolerance_passes() {
        // Nothing sent, nothing reported.
        assert_eq!(check_tail(0, 0), None);
        // Typical close: the last ~1-2 flushes still buffered or in flight.
        assert_eq!(check_tail(750, 650), None);
        // Exactly at the bound.
        assert_eq!(check_tail(750, 750 - TAIL_TOLERANCE_FRAMES), None);
        // Short session that never got a response inside the tolerance.
        assert_eq!(check_tail(TAIL_TOLERANCE_FRAMES, 0), None);
        // Reported beyond sent is `unsent_frame`'s job, not this check's.
        assert_eq!(check_tail(100, 150), None);
    }

    #[test]
    fn tail_drop_beyond_tolerance_is_detected() {
        let m = check_tail(750, 750 - TAIL_TOLERANCE_FRAMES - 1).expect("missing tail");
        assert_eq!(m.kind, MismatchKind::MissingTail);
        assert!(m.detail.contains("frames 450..=750"), "{}", m.detail);
        // Gateway that never answered at all.
        assert_eq!(
            check_tail(750, 0).map(|m| m.kind),
            Some(MismatchKind::MissingTail)
        );
    }

    /// Microbench for loadgen overhead: `cargo test --release -p stt-loadgen
    /// verify_cost -- --ignored --nocapture`.
    #[test]
    #[ignore = "microbenchmark; run explicitly in --release"]
    fn verify_cost() {
        let partial = honest(1_234, 1_001, 1_050);
        let mut scratch = Vec::new();
        let iterations = 2_000_u32;
        for _ in 0..50 {
            assert!(verify_partial(1_234, &partial, CFG, &mut scratch).is_empty());
        }
        let started = std::time::Instant::now();
        for _ in 0..iterations {
            let result = verify_partial(1_234, std::hint::black_box(&partial), CFG, &mut scratch);
            assert!(std::hint::black_box(result).is_empty());
        }
        let per = started.elapsed() / iterations;
        let started = std::time::Instant::now();
        for _ in 0..iterations {
            concat_payload(1_234, std::hint::black_box(1_001), 1_050, &mut scratch);
            std::hint::black_box(&scratch);
        }
        let rebuild = started.elapsed() / iterations;
        println!(
            "verify_partial (50 frames, {} passes): {per:?}/partial \
             (PCM rebuild {rebuild:?}); at 4000 sessions x 1 partial/s = \
             {:.1}% of one core",
            CFG.cpu_passes,
            per.as_secs_f64() * 4000.0 * 100.0
        );
    }
}

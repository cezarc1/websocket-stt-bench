//! Deterministic STT stub shared by the inference server (runtime path) and
//! the load generator / conformance harness (client-side verification).
//!
//! This is the single Rust implementation of the algorithm. The Python copy in
//! `services/python-fastapi/app/stub.py` exists only for cross-language parity
//! tests; numeric divergence between the two is a bug.

pub const FNV_OFFSET: u32 = 2_166_136_261;
pub const FNV_PRIME: u32 = 16_777_619;

// Placeholder STT vocabulary. The transcript for any input is selected by
// indexing this pool with the final FNV checksum, so identical PCM in always
// yields the same word.
pub const TRANSCRIPT_POOL: &[&str] = &[
    "the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "hello", "world", "yes", "no",
    "okay", "right", "left", "stop", "go", "wait", "ready", "done", "again", "now", "later",
    "never",
];

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct StubResult {
    pub rms: f64,
    pub zero_crossings: u64,
    pub checksum: u32,
    pub samples: u64,
    pub transcript: &'static str,
    pub audio_bytes: u64,
}

pub fn compute_stub(payload: &[u8], passes: u32) -> StubResult {
    let mut checksum = FNV_OFFSET;
    let mut zero_crossings = 0_u64;
    let mut sum_squares = 0_i128;
    let mut sample_count = 0_u64;
    let mut previous = 0_i16;

    for pass_index in 0..passes {
        for chunk in payload.chunks_exact(2) {
            let sample = i16::from_le_bytes([chunk[0], chunk[1]]);
            if sample_count > 0 && ((sample < 0 && previous >= 0) || (previous < 0 && sample >= 0))
            {
                zero_crossings += 1;
            }
            let adjusted = (sample as i32 + 32_768 + pass_index as i32) as u32;
            checksum ^= adjusted & 0xFFFF;
            checksum = checksum.wrapping_mul(FNV_PRIME);
            sum_squares += i128::from(sample) * i128::from(sample);
            sample_count += 1;
            previous = sample;
        }
    }

    let rms = if sample_count == 0 {
        0.0
    } else {
        ((sum_squares as f64) / (sample_count as f64)).sqrt()
    };

    let transcript = TRANSCRIPT_POOL[(checksum as usize) % TRANSCRIPT_POOL.len()];

    StubResult {
        rms,
        zero_crossings,
        checksum,
        samples: sample_count,
        transcript,
        audio_bytes: payload.len() as u64,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stub_is_deterministic() {
        let payload: Vec<u8> = [0_i16, 100, -100, 200]
            .into_iter()
            .flat_map(i16::to_le_bytes)
            .collect();
        let left = compute_stub(&payload, 4);
        let right = compute_stub(&payload, 4);

        assert_eq!(left, right);
        assert_eq!(left.samples, 16);
        assert_eq!(left.audio_bytes, payload.len() as u64);
        assert!(TRANSCRIPT_POOL.contains(&left.transcript));
    }

    #[test]
    fn empty_payload_is_zeroed() {
        let result = compute_stub(&[], 4);
        assert_eq!(result.samples, 0);
        assert_eq!(result.checksum, FNV_OFFSET);
        assert_eq!(result.rms, 0.0);
        assert_eq!(result.audio_bytes, 0);
    }

    #[test]
    fn odd_trailing_byte_is_ignored() {
        let even = compute_stub(&[1, 0, 2, 0], 1);
        let odd = compute_stub(&[1, 0, 2, 0, 9], 1);
        assert_eq!(even.checksum, odd.checksum);
        assert_eq!(even.samples, odd.samples);
        assert_eq!(odd.audio_bytes, 5);
    }
}

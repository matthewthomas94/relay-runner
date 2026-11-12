//! Silence trim, ported from kokoro-onnx 0.5.0's `trim` (itself librosa's
//! `effects.trim`) so both stacks cut a sentence at the same points.

const FRAME: usize = 2048;
const HOP: usize = 512;
/// A frame is silent when its RMS is 60 dB or more below the loudest frame.
const TOP_DB: f64 = 60.0;
/// librosa's `amin` of 1e-5, squared because this works on power.
const MIN_POWER: f64 = 1e-10;

pub fn trim(samples: &[f32]) -> &[f32] {
    // Frames are centred: frame `i` covers `i * HOP ± FRAME / 2`, zero padded.
    let mut squares = Vec::with_capacity(samples.len() + 1);
    let mut sum = 0.0_f64;
    squares.push(sum);
    for sample in samples {
        sum += f64::from(*sample) * f64::from(*sample);
        squares.push(sum);
    }
    let power: Vec<f64> = (0..=samples.len() / HOP)
        .map(|frame| {
            let centre = frame * HOP;
            let start = centre.saturating_sub(FRAME / 2);
            let end = (centre + FRAME / 2).min(samples.len());
            (squares[end] - squares[start]) / FRAME as f64
        })
        .collect();
    let decibels = |power: f64| 10.0 * power.max(MIN_POWER).log10();
    let loudest = decibels(power.iter().copied().fold(0.0, f64::max));
    let audible = |power: &f64| decibels(*power) - loudest > -TOP_DB;
    match (
        power.iter().position(audible),
        power.iter().rposition(audible),
    ) {
        (Some(first), Some(last)) => &samples[first * HOP..((last + 1) * HOP).min(samples.len())],
        _ => &[],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_to_the_hop_grid_around_the_sound() {
        let mut samples = vec![0.0_f32; 24_000];
        for sample in &mut samples[8_000..16_000] {
            *sample = 0.5;
        }
        let trimmed = trim(&samples);
        // The first frame whose window reaches sample 8000 is frame 14
        // (14 * 512 + 1024 > 8000); the last is frame 33 (33 * 512 - 1024 < 16000).
        assert_eq!(trimmed.len(), (33 + 1) * HOP - 14 * HOP);
        assert_eq!(trimmed.as_ptr(), samples[14 * HOP..].as_ptr());
    }

    #[test]
    fn digital_silence_is_kept_whole_as_librosa_keeps_it() {
        // Every frame is as loud as the loudest, so none is 60 dB below it.
        assert_eq!(trim(&[0.0; 4_096]).len(), 4_096);
    }
}

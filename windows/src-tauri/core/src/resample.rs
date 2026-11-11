//! Converts microphone samples (any rate, any channel count, f32) into the mono PCM16 STT providers expect.

/// Averages interleaved frames into one channel.
pub fn downmix(interleaved: &[f32], channels: usize) -> Vec<f32> {
    if channels <= 1 {
        return interleaved.to_vec();
    }
    interleaved.chunks_exact(channels).map(|frame| frame.iter().sum::<f32>() / channels as f32).collect()
}

/// A streaming sample-rate converter for speech. Downsampling averages the input samples that fall into each output
/// sample (a box filter, which keeps most aliasing out); upsampling interpolates linearly.
pub struct Resampler {
    /// Input samples per output sample.
    step: f64,
    /// Downsampling: input samples consumed into the current output sample.
    /// Upsampling: position of the next output sample between `last` and the next input sample.
    phase: f64,
    sum: f32,
    count: u32,
    last: f32,
}

impl Resampler {
    pub fn new(input_rate: u32, output_rate: u32) -> Self {
        Resampler { step: input_rate as f64 / output_rate as f64, phase: 0.0, sum: 0.0, count: 0, last: 0.0 }
    }

    pub fn process(&mut self, input: &[f32], output: &mut Vec<i16>) {
        if self.step >= 1.0 {
            for &sample in input {
                self.sum += sample;
                self.count += 1;
                self.phase += 1.0;
                if self.phase >= self.step {
                    output.push(to_pcm16(self.sum / self.count as f32));
                    self.sum = 0.0;
                    self.count = 0;
                    self.phase -= self.step;
                }
            }
        } else {
            for &sample in input {
                while self.phase < 1.0 {
                    output.push(to_pcm16(self.last + (sample - self.last) * self.phase as f32));
                    self.phase += self.step;
                }
                self.phase -= 1.0;
                self.last = sample;
            }
        }
    }
}

pub fn to_pcm16(sample: f32) -> i16 {
    (sample.clamp(-1.0, 1.0) * i16::MAX as f32).round() as i16
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn downmix_averages_channels() {
        assert_eq!(downmix(&[0.2, 0.4, -1.0, 1.0], 2), vec![0.3, 0.0]);
        assert_eq!(downmix(&[0.5, 0.25], 1), vec![0.5, 0.25]);
    }

    #[test]
    fn downsampling_48k_to_16k_keeps_duration_across_chunks() {
        let mut sut = Resampler::new(48_000, 16_000);
        let mut out = Vec::new();
        for _ in 0..10 {
            sut.process(&[0.5; 480], &mut out); // 10 ms per chunk
        }
        assert_eq!(out.len(), 1_600);
        assert!(out.iter().all(|&s| s == to_pcm16(0.5)));
    }

    #[test]
    fn downsampling_44_1k_to_16k_keeps_duration() {
        let mut sut = Resampler::new(44_100, 16_000);
        let mut out = Vec::new();
        for _ in 0..100 {
            sut.process(&[0.0; 441], &mut out);
        }
        assert!((15_999..=16_001).contains(&out.len()), "{}", out.len());
    }

    #[test]
    fn downsampling_averages_away_the_highest_frequencies() {
        let mut sut = Resampler::new(48_000, 16_000);
        let mut out = Vec::new();
        // A 24 kHz tone (alternating samples) can't be represented at 16 kHz; it must not alias into the output.
        let tone: Vec<f32> = (0..4_800).map(|i| if i % 2 == 0 { 0.9 } else { -0.9 }).collect();
        sut.process(&tone, &mut out);
        assert!(out.iter().all(|s| s.abs() <= to_pcm16(0.31)), "{:?}", &out[..6]);
    }

    #[test]
    fn upsampling_interpolates() {
        let mut sut = Resampler::new(8_000, 16_000);
        let mut out = Vec::new();
        sut.process(&[0.5, 0.5, 0.5, 0.5], &mut out);
        assert_eq!(out.len(), 8);
        assert_eq!(out[1], to_pcm16(0.25)); // Ramping up from silence.
        assert_eq!(out[7], to_pcm16(0.5));
    }

    #[test]
    fn pcm16_clamps() {
        assert_eq!(to_pcm16(2.0), i16::MAX);
        assert_eq!(to_pcm16(-2.0), -i16::MAX);
        assert_eq!(to_pcm16(0.0), 0);
    }
}

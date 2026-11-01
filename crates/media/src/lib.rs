use std::path::PathBuf;
use std::process::Stdio;
use thiserror::Error;
use tokio::io::AsyncReadExt;
use tokio::process::{Child, Command};

pub const SAMPLE_RATE: u32 = 16_000;
pub const CHANNELS: u16 = 1;
pub const BYTES_PER_SAMPLE: usize = 2;

#[derive(Debug, Error)]
pub enum MediaError {
    #[error("ffmpeg failed to start: {0}")]
    Spawn(#[from] std::io::Error),
    #[error("ffmpeg exited with status {0}")]
    Exit(i32),
    #[error("ffmpeg not found on PATH")]
    Missing,
}

pub struct PcmFrame {
    pub pts_ms: u64,
    pub samples: Vec<i16>,
}

/// Independent 16 kHz mono s16le decode, starting at `start_ms`.
pub struct AudioDecoder {
    child: Child,
    buf: Vec<u8>,
    bytes_read: u64,
    start_ms: u64,
}

impl AudioDecoder {
    pub async fn open(url: &str, start_ms: u64, audio_stream: Option<i32>) -> Result<Self, MediaError> {
        let ffmpeg = which_ffmpeg()?;
        let start_sec = format!("{:.3}", start_ms as f64 / 1000.0);
        let mut args = vec![
            "-hide_banner".into(),
            "-loglevel".into(),
            "error".into(),
            "-ss".into(),
            start_sec,
            "-i".into(),
            url.to_string(),
        ];
        if let Some(idx) = audio_stream {
            args.push("-map".into());
            args.push(format!("0:a:{}", idx));
        } else {
            args.push("-map".into());
            args.push("0:a:0?".into());
        }
        args.extend([
            "-vn".into(),
            "-ac".into(),
            "1".into(),
            "-ar".into(),
            SAMPLE_RATE.to_string(),
            "-f".into(),
            "s16le".into(),
            "pipe:1".into(),
        ]);

        let child = Command::new(ffmpeg)
            .args(&args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()?;

        Ok(Self {
            child,
            buf: Vec::new(),
            bytes_read: 0,
            start_ms,
        })
    }

    /// Read up to `duration_ms` of audio. Returns None on EOF.
    pub async fn read_window(&mut self, duration_ms: u64) -> Result<Option<PcmFrame>, MediaError> {
        let want = ((SAMPLE_RATE as u64 * duration_ms) / 1000) as usize * BYTES_PER_SAMPLE;
        let stdout = self.child.stdout.as_mut().expect("stdout piped");
        self.buf.clear();
        self.buf.resize(want, 0);
        let mut filled = 0;
        while filled < want {
            let n = stdout.read(&mut self.buf[filled..]).await?;
            if n == 0 {
                break;
            }
            filled += n;
        }
        if filled < BYTES_PER_SAMPLE * 400 {
            // < 25ms of audio: treat as EOF
            return Ok(None);
        }
        self.buf.truncate(filled);
        if filled % 2 == 1 {
            self.buf.pop();
        }
        let pts_ms = self.start_ms + (self.bytes_read * 1000) / (SAMPLE_RATE as u64 * BYTES_PER_SAMPLE as u64);
        self.bytes_read += self.buf.len() as u64;
        let samples = self
            .buf
            .chunks_exact(2)
            .map(|c| i16::from_le_bytes([c[0], c[1]]))
            .collect();
        Ok(Some(PcmFrame { pts_ms, samples }))
    }

    pub async fn kill(&mut self) {
        let _ = self.child.kill().await;
    }
}

fn which_ffmpeg() -> Result<PathBuf, MediaError> {
    if let Ok(explicit) = std::env::var("GLOSSA_FFMPEG") {
        let p = PathBuf::from(explicit);
        if p.is_file() {
            return Ok(p);
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let bundled = dir.join("ffmpeg");
            if bundled.is_file() {
                return Ok(bundled);
            }
        }
    }
    let candidates = [
        "ffmpeg",
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
    ];
    for c in candidates {
        let p = PathBuf::from(c);
        if c == "ffmpeg" {
            if which_on_path("ffmpeg") {
                return Ok(p);
            }
        } else if p.exists() {
            return Ok(p);
        }
    }
    Err(MediaError::Missing)
}

fn which_on_path(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| {
            std::env::split_paths(&paths).any(|dir| dir.join(name).is_file())
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn decode_fixture_if_present() {
        let p = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/hello.mp4");
        if !p.is_file() {
            return;
        }
        let mut d = AudioDecoder::open(p.to_str().unwrap(), 0, None)
            .await
            .expect("open fixture");
        let frame = d.read_window(1000).await.expect("read window");
        let frame = frame.expect("expected pcm");
        assert!(!frame.samples.is_empty());
        assert_eq!(frame.pts_ms, 0);
        d.kill().await;
    }
}

mod bailian;
mod gemini;
mod qwen3;
mod whisper;

use glossa_media::PcmFrame;
use glossa_protocol::Cue;
use serde_json::Value;
use thiserror::Error;

pub use bailian::BailianSession;
pub use gemini::GeminiSession;
pub use qwen3::Qwen3Session;
pub use whisper::WhisperSession;

#[derive(Debug, Error)]
pub enum AsrError {
    #[error("{0}")]
    Msg(String),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Http(#[from] reqwest::Error),
}

impl From<&str> for AsrError {
    fn from(s: &str) -> Self {
        Self::Msg(s.to_string())
    }
}

impl From<String> for AsrError {
    fn from(s: String) -> Self {
        Self::Msg(s)
    }
}

pub enum AsrKind {
    LocalBurst,
    CloudRealtime,
}

pub enum AsrSession {
    Whisper(WhisperSession),
    Qwen3(Qwen3Session),
    Bailian(BailianSession),
    Gemini(GeminiSession),
}

impl AsrSession {
    pub fn kind(&self) -> AsrKind {
        match self {
            Self::Whisper(_) | Self::Qwen3(_) => AsrKind::LocalBurst,
            Self::Bailian(_) | Self::Gemini(_) => AsrKind::CloudRealtime,
        }
    }

    pub async fn start(engine: &str, options: &Value) -> Result<Self, AsrError> {
        match engine {
            "whisper" => Ok(Self::Whisper(WhisperSession::new(options)?)),
            "qwen3-asr" => Ok(Self::Qwen3(Qwen3Session::start(options).await?)),
            "fun-asr-realtime" | "qwen-audio-3.1-asr-flash-streaming" | "qwen3-asr-flash-realtime" => {
                Ok(Self::Bailian(BailianSession::connect(engine, options).await?))
            }
            "gemini-3.5-transcribe-live" | "gemini" => {
                Ok(Self::Gemini(GeminiSession::connect(options).await?))
            }
            other => Err(AsrError::Msg(format!("unknown ASR engine: {other}"))),
        }
    }

    pub async fn feed(&mut self, frame: &PcmFrame) -> Result<Vec<Cue>, AsrError> {
        match self {
            Self::Whisper(s) => s.feed(frame),
            Self::Qwen3(s) => s.feed(frame).await,
            Self::Bailian(s) => s.feed(frame).await,
            Self::Gemini(s) => s.feed(frame).await,
        }
    }

    pub async fn finish(&mut self) -> Result<Vec<Cue>, AsrError> {
        match self {
            Self::Whisper(s) => s.finish(),
            Self::Qwen3(s) => s.finish().await,
            Self::Bailian(s) => s.finish().await,
            Self::Gemini(s) => s.finish().await,
        }
    }
}

pub fn s16_to_f32(samples: &[i16]) -> Vec<f32> {
    samples.iter().map(|s| *s as f32 / 32768.0).collect()
}

pub fn rms(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }
    let sum: f64 = samples.iter().map(|s| {
        let x = *s as f64;
        x * x
    }).sum();
    ((sum / samples.len() as f64).sqrt() / 32768.0) as f32
}

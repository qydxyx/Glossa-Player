use glossa_media::PcmFrame;
use glossa_protocol::Cue;
use serde_json::Value;
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};

use crate::{s16_to_f32, AsrError};

pub struct WhisperSession {
    ctx: WhisperContext,
    language: Option<String>,
}

impl WhisperSession {
    pub fn new(options: &Value) -> Result<Self, AsrError> {
        let path = options
            .get("model_path")
            .and_then(|v| v.as_str())
            .ok_or("whisper options.model_path is required")?;
        if !std::path::Path::new(path).is_file() {
            return Err(AsrError::Msg(format!(
                "whisper model not found: {path}. Download one in Settings."
            )));
        }
        let language = options
            .get("language")
            .and_then(|v| v.as_str())
            .filter(|s| *s != "auto")
            .map(|s| s.to_string());

        let mut params = WhisperContextParameters::default();
        params.use_gpu(true);
        let ctx = WhisperContext::new_with_params(path, params)
            .map_err(|e| AsrError::Msg(format!("whisper load: {e}")))?;
        Ok(Self { ctx, language })
    }

    pub fn feed(&mut self, frame: &PcmFrame) -> Result<Vec<Cue>, AsrError> {
        if crate::rms(&frame.samples) < 0.008 {
            return Ok(vec![]);
        }
        let audio = s16_to_f32(&frame.samples);
        if audio.len() < 16000 / 4 {
            return Ok(vec![]);
        }

        let mut state = self
            .ctx
            .create_state()
            .map_err(|e| AsrError::Msg(format!("whisper state: {e}")))?;

        let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
        params.set_n_threads(num_threads());
        params.set_translate(false);
        params.set_print_special(false);
        params.set_print_progress(false);
        params.set_print_realtime(false);
        params.set_print_timestamps(false);
        params.set_suppress_blank(true);
        params.set_no_speech_thold(0.4);
        if let Some(lang) = &self.language {
            params.set_language(Some(lang.as_str()));
        } else {
            params.set_language(Some("auto"));
        }

        state
            .full(params, &audio)
            .map_err(|e| AsrError::Msg(format!("whisper infer: {e}")))?;

        let n = state.full_n_segments();
        let mut cues = Vec::new();
        for i in 0..n {
            let Some(seg) = state.get_segment(i) else { continue };
            let text = match seg.to_str() {
                Ok(t) => t.trim().to_string(),
                Err(_) => continue,
            };
            if text.is_empty() {
                continue;
            }
            let t0 = seg.start_timestamp();
            let t1 = seg.end_timestamp();
            let start_ms = frame.pts_ms + (t0.max(0) as u64) * 10;
            let end_ms = frame.pts_ms + (t1.max(t0) as u64) * 10;
            let mut cue = Cue::new(start_ms, end_ms.max(start_ms + 200), text);
            cue.engine = Some("whisper".into());
            cues.push(cue);
        }
        Ok(cues)
    }

    pub fn finish(&mut self) -> Result<Vec<Cue>, AsrError> {
        Ok(vec![])
    }
}

fn num_threads() -> i32 {
    std::thread::available_parallelism()
        .map(|n| n.get().clamp(2, 8) as i32)
        .unwrap_or(4)
}

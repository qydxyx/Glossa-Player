use std::path::{Path, PathBuf};
use std::process::Stdio;

use glossa_media::{PcmFrame, SAMPLE_RATE};
use glossa_protocol::Cue;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};

use crate::{rms, AsrError};

pub struct Qwen3Session {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    wav_n: u32,
}

impl Qwen3Session {
    pub async fn start(options: &Value) -> Result<Self, AsrError> {
        let sidecar = sidecar_path(options)?;
        let python = python_path(options, &sidecar);
        let model = options
            .get("model")
            .and_then(|v| v.as_str())
            .unwrap_or("0.6b");
        let language = options.get("language").and_then(|v| v.as_str()).unwrap_or("auto");

        let mut child = Command::new(&python)
            .arg(&sidecar)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| {
                AsrError::Msg(format!(
                    "failed to start Qwen3 sidecar ({python} {}): {e}",
                    sidecar.display()
                ))
            })?;

        if let Some(mut err) = child.stderr.take() {
            tokio::spawn(async move {
                let mut buf = vec![0u8; 4096];
                loop {
                    match tokio::io::AsyncReadExt::read(&mut err, &mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(_) => {}
                    }
                }
            });
        }

        let stdin = child.stdin.take().ok_or("qwen3 sidecar missing stdin")?;
        let stdout = BufReader::new(child.stdout.take().ok_or("qwen3 sidecar missing stdout")?);
        let mut session = Self {
            child,
            stdin,
            stdout,
            wav_n: 0,
        };

        session
            .send(&json!({
                "type": "start",
                "model": model,
                "language": language,
            }))
            .await?;

        loop {
            let msg = session.read_msg().await?;
            match msg.get("type").and_then(|t| t.as_str()) {
                Some("ready") => break,
                Some("hello") | Some("status") => continue,
                Some("error") => {
                    let m = msg.get("message").and_then(|v| v.as_str()).unwrap_or("qwen3 error");
                    return Err(AsrError::Msg(m.to_string()));
                }
                other => {
                    return Err(AsrError::Msg(format!("qwen3 unexpected start reply: {other:?}")));
                }
            }
        }
        Ok(session)
    }

    pub async fn feed(&mut self, frame: &PcmFrame) -> Result<Vec<Cue>, AsrError> {
        if rms(&frame.samples) < 0.008 {
            return Ok(vec![]);
        }
        if frame.samples.len() < (SAMPLE_RATE as usize) / 4 {
            return Ok(vec![]);
        }
        self.wav_n += 1;
        let path = std::env::temp_dir().join(format!(
            "glossa-qwen3-{}-{}.wav",
            std::process::id(),
            self.wav_n
        ));
        write_wav(&path, &frame.samples, SAMPLE_RATE)?;
        let id = format!("{}-{}", frame.pts_ms, self.wav_n);
        let duration_ms = (frame.samples.len() as u64 * 1000) / SAMPLE_RATE as u64;
        self.send(&json!({
            "type": "transcribe",
            "id": id,
            "path": path.to_string_lossy(),
            "pts_ms": frame.pts_ms,
            "duration_ms": duration_ms,
        }))
        .await?;

        let msg = self.read_msg().await?;
        let _ = std::fs::remove_file(&path);
        match msg.get("type").and_then(|t| t.as_str()) {
            Some("result") => {
                let raw = msg.get("text").and_then(|v| v.as_str()).unwrap_or("");
                let Some(text) = glossa_protocol::sanitize_caption(raw) else {
                    return Ok(vec![]);
                };
                let start_ms = msg.get("start_ms").and_then(|v| v.as_u64()).unwrap_or(frame.pts_ms);
                let end_ms = msg
                    .get("end_ms")
                    .and_then(|v| v.as_u64())
                    .unwrap_or(start_ms + duration_ms.max(200));
                let mut cue = Cue::new(start_ms, end_ms.max(start_ms + 200), text);
                cue.language = msg
                    .get("language")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string());
                cue.engine = Some("qwen3-asr".into());
                Ok(vec![cue])
            }
            Some("error") => {
                let m = msg.get("message").and_then(|v| v.as_str()).unwrap_or("qwen3 transcribe error");
                Err(AsrError::Msg(m.to_string()))
            }
            other => Err(AsrError::Msg(format!("qwen3 unexpected reply: {other:?}"))),
        }
    }

    pub async fn finish(&mut self) -> Result<Vec<Cue>, AsrError> {
        let _ = self.send(&json!({"type": "stop"})).await;
        let _ = self.child.kill().await;
        Ok(vec![])
    }

    async fn send(&mut self, v: &Value) -> Result<(), AsrError> {
        let mut line = serde_json::to_string(v)?;
        line.push('\n');
        self.stdin.write_all(line.as_bytes()).await?;
        self.stdin.flush().await?;
        Ok(())
    }

    async fn read_msg(&mut self) -> Result<Value, AsrError> {
        loop {
            let mut line = String::new();
            let n = self.stdout.read_line(&mut line).await?;
            if n == 0 {
                return Err(AsrError::Msg("qwen3 sidecar closed stdout".into()));
            }
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            return Ok(serde_json::from_str(line)?);
        }
    }
}

pub fn write_wav(path: &Path, samples: &[i16], sample_rate: u32) -> Result<(), AsrError> {
    use std::io::Write;
    let mut f = std::fs::File::create(path)?;
    let data_len = (samples.len() * 2) as u32;
    let file_len = 36 + data_len;
    f.write_all(b"RIFF")?;
    f.write_all(&file_len.to_le_bytes())?;
    f.write_all(b"WAVEfmt ")?;
    f.write_all(&16u32.to_le_bytes())?;
    f.write_all(&1u16.to_le_bytes())?;
    f.write_all(&1u16.to_le_bytes())?;
    f.write_all(&sample_rate.to_le_bytes())?;
    f.write_all(&(sample_rate * 2).to_le_bytes())?;
    f.write_all(&2u16.to_le_bytes())?;
    f.write_all(&16u16.to_le_bytes())?;
    f.write_all(b"data")?;
    f.write_all(&data_len.to_le_bytes())?;
    for s in samples {
        f.write_all(&s.to_le_bytes())?;
    }
    Ok(())
}

fn python_path(options: &Value, sidecar: &Path) -> String {
    if let Some(p) = options.get("python").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
        return p.to_string();
    }
    if let Ok(p) = std::env::var("GLOSSA_PYTHON") {
        if !p.is_empty() {
            return p;
        }
    }
    let mut venvs = Vec::new();
    if let Some(dir) = sidecar.parent() {
        venvs.push(dir.join(".venv/bin/python3"));
    }
    venvs.push(support_dir().join("qwen3-asr/.venv/bin/python3"));
    venvs.push(repo_sidecar().parent().unwrap_or(Path::new(".")).join(".venv/bin/python3"));
    for venv in venvs {
        if venv.is_file() {
            return venv.to_string_lossy().into_owned();
        }
    }
    for bin in ["python3.13", "python3.12", "python3.11", "python3"] {
        if which_on_path(bin) {
            return bin.into();
        }
    }
    "python3".into()
}

fn which_on_path(name: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(name).is_file()))
        .unwrap_or(false)
}

fn sidecar_path(options: &Value) -> Result<PathBuf, AsrError> {
    if let Some(p) = options.get("sidecar").and_then(|v| v.as_str()).filter(|s| !s.is_empty()) {
        let path = PathBuf::from(p);
        if path.is_file() {
            return Ok(path);
        }
        return Err(AsrError::Msg(format!("qwen3 sidecar not found: {p}")));
    }
    if let Ok(p) = std::env::var("GLOSSA_QWEN3_SIDECAR") {
        let path = PathBuf::from(&p);
        if path.is_file() {
            return Ok(path);
        }
    }
    let mut candidates = vec![
        PathBuf::from("sidecar/qwen3-asr/qwen3_asr_sidecar.py"),
        PathBuf::from("../sidecar/qwen3-asr/qwen3_asr_sidecar.py"),
        repo_sidecar(),
        support_dir().join("qwen3_asr_sidecar.py"),
    ];
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            candidates.push(dir.join("qwen3_asr_sidecar.py"));
            candidates.push(dir.join("../Resources/qwen3_asr_sidecar.py"));
        }
    }
    for c in candidates {
        if c.is_file() {
            return Ok(c);
        }
    }
    Err(AsrError::Msg(
        "Qwen3-ASR sidecar script not found. See sidecar/qwen3-asr/README.md".into(),
    ))
}

fn repo_sidecar() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../sidecar/qwen3-asr/qwen3_asr_sidecar.py")
}

fn support_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join("Library/Application Support/Glossa")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wav_header_is_44_bytes_plus_pcm() {
        let dir = std::env::temp_dir().join("glossa-wav-test.wav");
        let samples = vec![0i16, 1, -1, 32767];
        write_wav(&dir, &samples, 16_000).unwrap();
        let bytes = std::fs::read(&dir).unwrap();
        assert_eq!(&bytes[0..4], b"RIFF");
        assert_eq!(&bytes[8..12], b"WAVE");
        assert_eq!(bytes.len(), 44 + samples.len() * 2);
        let _ = std::fs::remove_file(&dir);
    }

    #[tokio::test]
    async fn mock_sidecar_transcribes() {
        let sidecar = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../sidecar/qwen3-asr/mock_sidecar.py");
        if !sidecar.is_file() {
            return;
        }
        let options = json!({
            "sidecar": sidecar.to_string_lossy(),
            "python": "python3",
            "model": "0.6b",
        });
        let mut session = Qwen3Session::start(&options).await.unwrap();
        let frame = PcmFrame {
            pts_ms: 1200,
            samples: vec![1000i16; 16_000],
        };
        let cues = session.feed(&frame).await.unwrap();
        assert_eq!(cues.len(), 1);
        assert_eq!(cues[0].text, "hello from mock");
        assert_eq!(cues[0].start_ms, 1200);
        session.finish().await.unwrap();
    }
}

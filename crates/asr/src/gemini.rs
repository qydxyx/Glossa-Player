use base64::Engine as _;
use futures_util::{SinkExt, StreamExt};
use glossa_media::PcmFrame;
use glossa_protocol::Cue;
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use crate::AsrError;

pub struct GeminiSession {
    tx: mpsc::Sender<Vec<u8>>,
    events: mpsc::Receiver<Cue>,
}

impl GeminiSession {
    pub async fn connect(options: &Value) -> Result<Self, AsrError> {
        let api_key = options
            .get("api_key")
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .ok_or("gemini api_key required")?;
        let model = options
            .get("model")
            .and_then(|v| v.as_str())
            .unwrap_or("gemini-3.5-transcribe-live");

        let url = format!(
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={api_key}"
        );
        let (ws, _) = connect_async(&url)
            .await
            .map_err(|e| AsrError::Msg(e.to_string()))?;
        let (mut sink, mut stream) = ws.split();

        let setup = json!({
            "setup": {
                "model": format!("models/{model}"),
                "generationConfig": { "responseModalities": ["TEXT"] },
                "inputAudioTranscription": serde_json::Map::new()
            }
        });
        sink.send(Message::Text(setup.to_string().into()))
            .await
            .map_err(|e| AsrError::Msg(e.to_string()))?;

        let (pcm_tx, mut pcm_rx) = mpsc::channel::<Vec<u8>>(32);
        let (cue_tx, cue_rx) = mpsc::channel::<Cue>(64);

        tokio::spawn(async move {
            let b64 = base64::engine::general_purpose::STANDARD;
            while let Some(bytes) = pcm_rx.recv().await {
                let msg = json!({
                    "realtimeInput": {
                        "audio": {
                            "mimeType": "audio/pcm;rate=16000",
                            "data": b64.encode(&bytes)
                        }
                    }
                });
                if sink.send(Message::Text(msg.to_string().into())).await.is_err() {
                    break;
                }
            }
        });

        tokio::spawn(async move {
            while let Some(msg) = stream.next().await {
                let Ok(Message::Text(text)) = msg else { continue };
                if let Ok(v) = serde_json::from_str::<Value>(&text) {
                    for cue in parse_gemini(&v) {
                        let _ = cue_tx.send(cue).await;
                    }
                }
            }
        });

        Ok(Self {
            tx: pcm_tx,
            events: cue_rx,
        })
    }

    pub async fn feed(&mut self, frame: &PcmFrame) -> Result<Vec<Cue>, AsrError> {
        let bytes: Vec<u8> = frame
            .samples
            .iter()
            .flat_map(|s| s.to_le_bytes())
            .collect();
        self.tx
            .send(bytes)
            .await
            .map_err(|_| AsrError::Msg("gemini pcm channel closed".into()))?;
        Ok(drain(&mut self.events))
    }

    pub async fn finish(&mut self) -> Result<Vec<Cue>, AsrError> {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        Ok(drain(&mut self.events))
    }
}

fn parse_gemini(v: &Value) -> Vec<Cue> {
    let mut out = Vec::new();
    let text = v
        .pointer("/serverContent/inputTranscription/text")
        .or_else(|| v.pointer("/inputTranscription/text"))
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .trim();
    if text.is_empty() {
        return out;
    }
    let finished = v
        .pointer("/serverContent/inputTranscription/finished")
        .and_then(|b| b.as_bool())
        .unwrap_or(false);
    let mut cue = Cue::new(0, 800, text);
    cue.partial = !finished;
    cue.engine = Some("gemini-3.5-transcribe-live".into());
    out.push(cue);
    out
}

fn drain(rx: &mut mpsc::Receiver<Cue>) -> Vec<Cue> {
    let mut out = Vec::new();
    while let Ok(c) = rx.try_recv() {
        out.push(c);
    }
    out
}

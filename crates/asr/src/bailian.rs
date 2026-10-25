use futures_util::{SinkExt, StreamExt};
use glossa_media::{PcmFrame, SAMPLE_RATE};
use glossa_protocol::Cue;
use serde_json::{json, Value};
use tokio::sync::mpsc;
use tokio_tungstenite::{connect_async, tungstenite::Message};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use crate::AsrError;

/// DashScope inference WebSocket: Fun-ASR-Realtime and Qwen-Audio-3.1 streaming.
pub struct BailianSession {
    tx: mpsc::Sender<Vec<u8>>,
    events: mpsc::Receiver<Cue>,
}

impl BailianSession {
    pub async fn connect(engine: &str, options: &Value) -> Result<Self, AsrError> {
        let api_key = opt_str(options, "api_key").ok_or("bailian api_key required")?;
        let workspace = opt_str(options, "workspace_id").ok_or("bailian workspace_id required")?;
        let region = opt_str(options, "region").unwrap_or_else(|| "cn-beijing".into());
        let host = format!("wss://{workspace}.{region}.maas.aliyuncs.com/api-ws/v1/inference");

        let mut req = host.into_client_request().map_err(|e| AsrError::Msg(e.to_string()))?;
        req.headers_mut().insert(
            "Authorization",
            format!("Bearer {api_key}").parse().map_err(|e: http::header::InvalidHeaderValue| {
                AsrError::Msg(e.to_string())
            })?,
        );

        let (ws, _) = connect_async(req).await.map_err(|e| AsrError::Msg(e.to_string()))?;
        let (mut sink, mut stream) = ws.split();

        let task_id = uuid_simple();
        let run_task = json!({
            "header": {
                "action": "run-task",
                "task_id": task_id,
                "streaming": "duplex"
            },
            "payload": {
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": engine,
                "parameters": {
                    "format": "pcm",
                    "sample_rate": SAMPLE_RATE
                },
                "input": {}
            }
        });
        sink.send(Message::Text(run_task.to_string().into()))
            .await
            .map_err(|e| AsrError::Msg(e.to_string()))?;

        let (pcm_tx, mut pcm_rx) = mpsc::channel::<Vec<u8>>(32);
        let (cue_tx, cue_rx) = mpsc::channel::<Cue>(64);
        let engine_name = engine.to_string();

        tokio::spawn(async move {
            while let Some(bytes) = pcm_rx.recv().await {
                if sink.send(Message::Binary(bytes.into())).await.is_err() {
                    break;
                }
            }
            let finish = json!({
                "header": {
                    "action": "finish-task",
                    "task_id": task_id,
                    "streaming": "duplex"
                },
                "payload": { "input": {} }
            });
            let _ = sink.send(Message::Text(finish.to_string().into())).await;
        });

        tokio::spawn(async move {
            while let Some(msg) = stream.next().await {
                let Ok(Message::Text(text)) = msg else { continue };
                if let Ok(v) = serde_json::from_str::<Value>(&text) {
                    if let Some(cue) = parse_result(&v, &engine_name) {
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
        self.tx.send(bytes).await.map_err(|_| AsrError::Msg("bailian pcm channel closed".into()))?;
        Ok(drain(&mut self.events))
    }

    pub async fn finish(&mut self) -> Result<Vec<Cue>, AsrError> {
        drop(self.tx.clone());
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        Ok(drain(&mut self.events))
    }
}

fn parse_result(v: &Value, engine: &str) -> Option<Cue> {
    let event = v.pointer("/header/event")?.as_str()?;
    if event != "result-generated" {
        return None;
    }
    let text = v
        .pointer("/payload/output/sentence/text")
        .or_else(|| v.pointer("/payload/sentence/text"))
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .trim();
    if text.is_empty() {
        return None;
    }
    let begin = v
        .pointer("/payload/output/sentence/begin_time")
        .or_else(|| v.pointer("/payload/sentence/begin_time"))
        .and_then(|n| n.as_u64())
        .unwrap_or(0);
    let end = v
        .pointer("/payload/output/sentence/end_time")
        .or_else(|| v.pointer("/payload/sentence/end_time"))
        .and_then(|n| n.as_u64())
        .unwrap_or(begin + 800);
    let sentence_end = v
        .pointer("/payload/output/sentence/sentence_end")
        .and_then(|b| b.as_bool())
        .unwrap_or(true);
    let mut cue = Cue::new(begin, end.max(begin + 200), text);
    cue.partial = !sentence_end;
    cue.engine = Some(engine.into());
    Some(cue)
}

fn drain(rx: &mut mpsc::Receiver<Cue>) -> Vec<Cue> {
    let mut out = Vec::new();
    while let Ok(c) = rx.try_recv() {
        out.push(c);
    }
    out
}

fn opt_str(v: &Value, key: &str) -> Option<String> {
    v.get(key)?.as_str().filter(|s| !s.is_empty()).map(|s| s.to_string())
}

fn uuid_simple() -> String {
    format!("{:x}", std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos())
}

use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const PROTOCOL_VERSION: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetranslateItem {
    pub cue_id: String,
    pub text: String,
    #[serde(default)]
    pub language: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Cue {
    pub id: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub text: String,
    #[serde(default)]
    pub translated_text: Option<String>,
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default)]
    pub partial: bool,
    #[serde(default)]
    pub engine: Option<String>,
}

impl Cue {
    pub fn new(start_ms: u64, end_ms: u64, text: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            start_ms,
            end_ms,
            text: text.into(),
            translated_text: None,
            language: None,
            partial: false,
            engine: None,
        }
    }
}

/// Strip ASS/SSA override tags and drop debug dumps from ASR backends.
pub fn sanitize_caption(s: &str) -> Option<String> {
    let stripped = strip_ass(s);
    let t = stripped
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .collect::<Vec<_>>()
        .join(" ");
    let t = t.trim();
    if t.is_empty() {
        return None;
    }
    if t.contains("TranscriptionResult(") || t.contains("TranscriptResult") {
        return None;
    }
    if t.contains("language=") && t.contains("duration=") {
        return None;
    }
    Some(t.to_string())
}

fn strip_ass(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '{' && chars.peek() == Some(&'\\') {
            for x in chars.by_ref() {
                if x == '}' {
                    break;
                }
            }
            continue;
        }
        out.push(c);
    }
    out.replace("\\N", " ").replace("\\n", " ")
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    Open {
        url: String,
        start_ms: u64,
        #[serde(default)]
        audio_stream: Option<i32>,
    },
    Seek {
        time_ms: u64,
    },
    Pause {
        paused: bool,
    },
    Retranslate {
        items: Vec<RetranslateItem>,
    },
    SetAsr {
        engine: String,
        #[serde(default)]
        options: serde_json::Value,
    },
    SetTranslator {
        engine: String,
        #[serde(default)]
        options: serde_json::Value,
    },
    StopAsr,
    Shutdown,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    Ready {
        version: u32,
    },
    CueUpsert {
        cue: Cue,
    },
    Translation {
        cue_id: String,
        text: String,
    },
    Status {
        asr: String,
        #[serde(default)]
        message: Option<String>,
    },
    Error {
        message: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_open() {
        let msg = ClientMessage::Open {
            url: "/tmp/a.mp4".into(),
            start_ms: 1500,
            audio_stream: None,
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"open\""));
        let back: ClientMessage = serde_json::from_str(&json).unwrap();
        match back {
            ClientMessage::Open { start_ms, .. } => assert_eq!(start_ms, 1500),
            _ => panic!("wrong variant"),
        }
    }

    #[test]
    fn cue_default_partial_false() {
        let json = r#"{"id":"a","start_ms":0,"end_ms":1000,"text":"hi"}"#;
        let cue: Cue = serde_json::from_str(json).unwrap();
        assert!(!cue.partial);
        assert!(cue.translated_text.is_none());
    }

    #[test]
    fn server_translation_tag() {
        let msg = ServerMessage::Translation {
            cue_id: "x".into(),
            text: "你好".into(),
        };
        let json = serde_json::to_string(&msg).unwrap();
        assert!(json.contains("\"type\":\"translation\""));
        assert!(json.contains("cue_id"));
    }

    #[test]
    fn sanitize_drops_transcription_repr() {
        let dump = "TranscriptionResult(text='', language='English', duration=8.0)";
        assert_eq!(sanitize_caption(dump), None);
    }

    #[test]
    fn sanitize_strips_ass_tags() {
        let s = r"マイナス五{\fn黑体\fs22\bord1\shad0}你觉得呢。";
        assert_eq!(sanitize_caption(s).as_deref(), Some("マイナス五你觉得呢。"));
    }
}

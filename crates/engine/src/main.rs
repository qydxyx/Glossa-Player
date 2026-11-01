use std::path::PathBuf;
use std::sync::Arc;

use glossa_asr::{AsrKind, AsrSession};
use glossa_media::AudioDecoder;
use glossa_protocol::{sanitize_caption, ClientMessage, RetranslateItem, ServerMessage, PROTOCOL_VERSION};
use glossa_translate::{TranslateRequest, Translator};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::Mutex;
use tracing::{error, info, warn};

struct AppState {
    asr_engine: String,
    asr_options: serde_json::Value,
    translator_engine: Option<String>,
    translator_options: serde_json::Value,
    job: Option<tokio::task::JoinHandle<()>>,
    cancel: Option<tokio::sync::watch::Sender<bool>>,
    pause_tx: tokio::sync::watch::Sender<bool>,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env().add_directive("info".parse()?))
        .init();

    if std::env::args().any(|a| a == "--stdio") {
        info!("glossa-engine stdio mode");
        let reader = BufReader::new(tokio::io::stdin());
        let writer = tokio::io::stdout();
        handle_io(reader, writer).await?;
        return Ok(());
    }

    let sock = socket_path();
    if let Some(parent) = sock.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let _ = std::fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock)?;
    info!("glossa-engine listening on {}", sock.display());

    loop {
        let (stream, _) = listener.accept().await?;
        info!("client connected");
        if let Err(e) = handle_client(stream).await {
            error!("client error: {e}");
        }
    }
}

async fn handle_client(stream: UnixStream) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let (reader, writer) = stream.into_split();
    handle_io(BufReader::new(reader), writer).await
}

async fn handle_io<R, W>(reader: BufReader<R>, writer: W) -> Result<(), Box<dyn std::error::Error + Send + Sync>>
where
    R: tokio::io::AsyncRead + Unpin,
    W: tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    let mut lines = reader.lines();
    let writer = Arc::new(Mutex::new(writer));
    send(&writer, ServerMessage::Ready { version: PROTOCOL_VERSION }).await;

    let (pause_tx, _) = tokio::sync::watch::channel(false);
    let state = Arc::new(Mutex::new(AppState {
        asr_engine: "whisper".into(),
        asr_options: serde_json::json!({}),
        translator_engine: None,
        translator_options: serde_json::json!({}),
        job: None,
        cancel: None,
        pause_tx,
    }));

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let msg: ClientMessage = match serde_json::from_str(&line) {
            Ok(m) => m,
            Err(e) => {
                send(&writer, ServerMessage::Error { message: e.to_string() }).await;
                continue;
            }
        };
        match msg {
            ClientMessage::SetAsr { engine, options } => {
                let mut st = state.lock().await;
                st.asr_engine = engine.clone();
                st.asr_options = options;
                send(&writer, ServerMessage::Status { asr: engine, message: Some("asr configured".into()) }).await;
            }
            ClientMessage::SetTranslator { engine, options } => {
                let mut st = state.lock().await;
                st.translator_engine = Some(engine.clone());
                st.translator_options = options;
                send(&writer, ServerMessage::Status { asr: "ok".into(), message: Some(format!("translator {engine}")) }).await;
            }
            ClientMessage::Open { url, start_ms, audio_stream } => {
                start_job(state.clone(), writer.clone(), url, start_ms, audio_stream).await;
            }
            ClientMessage::Seek { time_ms } => {
                let url = {
                    // restart from new position using last url stored in job via cancel+open
                    time_ms
                };
                let _ = url;
                warn!("seek handled by app re-sending open; engine cancels current job");
                cancel_job(&state).await;
            }
            ClientMessage::StopAsr => {
                cancel_job(&state).await;
                send(&writer, ServerMessage::Status { asr: "idle".into(), message: None }).await;
            }
            ClientMessage::Pause { paused } => {
                let tx = state.lock().await.pause_tx.clone();
                let _ = tx.send(paused);
                send(
                    &writer,
                    ServerMessage::Status {
                        asr: if paused { "paused".into() } else { "running".into() },
                        message: None,
                    },
                )
                .await;
            }
            ClientMessage::Retranslate { items } => {
                let translator = {
                    let st = state.lock().await;
                    st.translator_engine
                        .as_ref()
                        .map(|e| (e.clone(), st.translator_options.clone()))
                };
                let writer = writer.clone();
                tokio::spawn(async move {
                    retranslate(writer, translator, items).await;
                });
            }
            ClientMessage::Shutdown => break,
        }
    }
    cancel_job(&state).await;
    Ok(())
}

async fn start_job<W>(
    state: Arc<Mutex<AppState>>,
    writer: Arc<Mutex<W>>,
    url: String,
    start_ms: u64,
    audio_stream: Option<i32>,
) where
    W: tokio::io::AsyncWrite + Unpin + Send + 'static,
{
    cancel_job(&state).await;
    let (tx, rx) = tokio::sync::watch::channel(false);
    let (engine, options, translator, pause_rx) = {
        let mut st = state.lock().await;
        st.cancel = Some(tx);
        let tr = st
            .translator_engine
            .as_ref()
            .map(|e| (e.clone(), st.translator_options.clone()));
        (
            st.asr_engine.clone(),
            st.asr_options.clone(),
            tr,
            st.pause_tx.subscribe(),
        )
    };

    let handle = tokio::spawn(async move {
        if let Err(e) = run_asr(
            writer,
            url,
            start_ms,
            audio_stream,
            engine,
            options,
            translator,
            rx,
            pause_rx,
        )
        .await
        {
            error!("asr job: {e}");
        }
    });
    state.lock().await.job = Some(handle);
}

async fn cancel_job(state: &Arc<Mutex<AppState>>) {
    let mut st = state.lock().await;
    if let Some(c) = st.cancel.take() {
        let _ = c.send(true);
    }
    if let Some(job) = st.job.take() {
        job.abort();
    }
}

async fn run_asr<W: tokio::io::AsyncWrite + Unpin + Send>(
    writer: Arc<Mutex<W>>,
    url: String,
    start_ms: u64,
    audio_stream: Option<i32>,
    engine: String,
    options: serde_json::Value,
    translator: Option<(String, serde_json::Value)>,
    mut cancel: tokio::sync::watch::Receiver<bool>,
    mut pause: tokio::sync::watch::Receiver<bool>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    send(&writer, ServerMessage::Status { asr: "starting".into(), message: Some(engine.clone()) }).await;

    let mut session = match AsrSession::start(&engine, &options).await {
        Ok(s) => s,
        Err(e) => {
            send(&writer, ServerMessage::Error { message: e.to_string() }).await;
            return Ok(());
        }
    };

    let mut decoder = AudioDecoder::open(&url, start_ms, audio_stream).await?;
    send(&writer, ServerMessage::Status { asr: "running".into(), message: None }).await;

    let window_ms = match session.kind() {
        AsrKind::LocalBurst => 8_000,
        AsrKind::CloudRealtime => 200,
    };

    let translator = translator.map(|(e, o)| Translator::new(&e, o));
    let mut recent: Vec<String> = Vec::new();

    loop {
        if wait_while_paused(&mut cancel, &mut pause).await {
            break;
        }
        tokio::select! {
            _ = cancel.changed() => {
                if *cancel.borrow() { break; }
            }
            frame = decoder.read_window(window_ms) => {
                match frame {
                    Ok(Some(frame)) => {
                        match session.feed(&frame).await {
                            Ok(cues) => {
                                publish_cues(&writer, &translator, &mut recent, cues).await;
                            }
                            Err(e) => {
                                send(&writer, ServerMessage::Error { message: e.to_string() }).await;
                            }
                        }
                    }
                    Ok(None) => {
                        let rest = session.finish().await.unwrap_or_default();
                        publish_cues(&writer, &translator, &mut recent, rest).await;
                        send(&writer, ServerMessage::Status { asr: "done".into(), message: None }).await;
                        break;
                    }
                    Err(e) => {
                        send(&writer, ServerMessage::Error { message: e.to_string() }).await;
                        break;
                    }
                }
            }
        }
    }
    decoder.kill().await;
    Ok(())
}

/// Returns true when the job should stop.
async fn wait_while_paused(
    cancel: &mut tokio::sync::watch::Receiver<bool>,
    pause: &mut tokio::sync::watch::Receiver<bool>,
) -> bool {
    loop {
        if *cancel.borrow() {
            return true;
        }
        if !*pause.borrow() {
            return false;
        }
        tokio::select! {
            _ = cancel.changed() => {}
            _ = pause.changed() => {}
        }
    }
}

async fn retranslate<W: tokio::io::AsyncWrite + Unpin + Send>(
    writer: Arc<Mutex<W>>,
    translator: Option<(String, serde_json::Value)>,
    items: Vec<RetranslateItem>,
) {
    let Some((engine, options)) = translator else {
        send(
            &writer,
            ServerMessage::Error {
                message: "no translator configured".into(),
            },
        )
        .await;
        return;
    };
    let translator = Translator::new(&engine, options);
    for item in items {
        let Some(text) = sanitize_caption(&item.text) else {
            continue;
        };
        match translator
            .translate(TranslateRequest {
                text: text.clone(),
                src: translator.resolve_src(item.language.as_deref()),
                tgt: translator.target_lang(),
                context: vec![],
            })
            .await
        {
            Ok(translated) => {
                if let Some(translated) = sanitize_caption(&translated) {
                    if translated != text {
                        send(
                            &writer,
                            ServerMessage::Translation {
                                cue_id: item.cue_id,
                                text: translated,
                            },
                        )
                        .await;
                    }
                }
            }
            Err(e) => {
                warn!("retranslate: {e}");
                send(
                    &writer,
                    ServerMessage::Status {
                        asr: "translate".into(),
                        message: Some(e.to_string()),
                    },
                )
                .await;
            }
        }
    }
    send(
        &writer,
        ServerMessage::Status {
            asr: "retranslate".into(),
            message: Some("done".into()),
        },
    )
    .await;
}

async fn publish_cues<W: tokio::io::AsyncWrite + Unpin>(
    writer: &Arc<Mutex<W>>,
    translator: &Option<Translator>,
    recent: &mut Vec<String>,
    cues: Vec<glossa_protocol::Cue>,
) {
    for mut cue in cues {
        let Some(text) = sanitize_caption(&cue.text) else {
            continue;
        };
        cue.text = text;
        send(writer, ServerMessage::CueUpsert { cue: cue.clone() }).await;
        if cue.partial {
            continue;
        }
        if let Some(tr) = translator {
            match tr
                .translate(TranslateRequest {
                    text: cue.text.clone(),
                    src: tr.resolve_src(cue.language.as_deref()),
                    tgt: tr.target_lang(),
                    context: recent.clone(),
                })
                .await
            {
                Ok(text) => {
                    if let Some(text) = sanitize_caption(&text) {
                        if text != cue.text {
                            cue.translated_text = Some(text.clone());
                            send(
                                writer,
                                ServerMessage::Translation {
                                    cue_id: cue.id.clone(),
                                    text,
                                },
                            )
                            .await;
                        }
                    }
                }
                Err(e) => {
                    warn!("translate: {e}");
                    send(
                        writer,
                        ServerMessage::Status {
                            asr: "translate".into(),
                            message: Some(e.to_string()),
                        },
                    )
                    .await;
                }
            }
        }
        recent.push(cue.text.clone());
        if recent.len() > 4 {
            recent.remove(0);
        }
    }
}

async fn send<W: tokio::io::AsyncWrite + Unpin>(writer: &Arc<Mutex<W>>, msg: ServerMessage) {
    let mut line = serde_json::to_string(&msg).unwrap();
    line.push('\n');
    let mut w = writer.lock().await;
    if let Err(e) = w.write_all(line.as_bytes()).await {
        warn!("write: {e}");
    }
}

fn socket_path() -> PathBuf {
    if let Ok(p) = std::env::var("GLOSSA_SOCK") {
        return PathBuf::from(p);
    }
    let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home)
        .join("Library/Application Support/Glossa/engine.sock")
}



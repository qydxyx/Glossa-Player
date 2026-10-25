use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde_json::{json, Value};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum TranslateError {
    #[error("{0}")]
    Msg(String),
    #[error(transparent)]
    Http(#[from] reqwest::Error),
}

pub struct TranslateRequest {
    pub text: String,
    pub src: String,
    pub tgt: String,
    pub context: Vec<String>,
}

pub struct Translator {
    engine: String,
    options: Value,
    client: reqwest::Client,
}

impl Translator {
    pub fn new(engine: &str, options: Value) -> Self {
        Self {
            engine: engine.to_string(),
            options,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(20))
                .build()
                .unwrap_or_else(|_| reqwest::Client::new()),
        }
    }

    pub fn source_lang(&self) -> String {
        self.opt("source_lang").unwrap_or_else(|| "auto".into())
    }

    pub fn target_lang(&self) -> String {
        self.opt("target_lang").unwrap_or_else(|| "zh".into())
    }

    pub fn resolve_src(&self, cue_lang: Option<&str>) -> String {
        let configured = self.source_lang();
        if configured != "auto" && !configured.is_empty() {
            iso_lang(&configured)
        } else if let Some(c) = cue_lang.map(iso_lang).filter(|s| s != "auto" && !s.is_empty()) {
            c
        } else {
            "auto".into()
        }
    }

    pub async fn translate(&self, req: TranslateRequest) -> Result<String, TranslateError> {
        match self.engine.as_str() {
            "openai" | "openai-compatible" | "ollama" | "lmstudio" | "claude" => {
                self.openai_compat(req).await
            }
            "deepl" => self.deepl(req).await,
            "libretranslate" | "libre" => self.libretranslate(req).await,
            "google" => self.google(req).await,
            "qwen" | "dashscope" => self.dashscope(req).await,
            other => Err(TranslateError::Msg(format!("unknown translator: {other}"))),
        }
    }

    async fn openai_compat(&self, req: TranslateRequest) -> Result<String, TranslateError> {
        let base = self
            .opt("base_url")
            .unwrap_or_else(|| "https://api.openai.com/v1".into())
            .trim_end_matches('/')
            .to_string();
        let model = self.opt("model").unwrap_or_else(|| "gpt-4o-mini".into());
        let key = self.opt("api_key").unwrap_or_default();
        let system = build_system(
            &req.src,
            &req.tgt,
            &req.context,
            self.opt("instruction").as_deref(),
            self.opt("formality").as_deref(),
        );
        let url = format!("{base}/chat/completions");
        let mut builder = self.client.post(&url).header(CONTENT_TYPE, "application/json");
        if !key.is_empty() {
            builder = builder.header(AUTHORIZATION, format!("Bearer {key}"));
        }
        let body = json!({
            "model": model,
            "temperature": 0.2,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": req.text}
            ]
        });
        let resp: Value = builder.json(&body).send().await?.error_for_status()?.json().await?;
        resp.pointer("/choices/0/message/content")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| TranslateError::Msg(format!("empty translation: {resp}")))
    }

    async fn deepl(&self, req: TranslateRequest) -> Result<String, TranslateError> {
        let key = self.opt("api_key").ok_or_else(|| TranslateError::Msg("deepl api_key required".into()))?;
        let host = deepl_endpoint(&key, self.opt("endpoint").as_deref());
        let tgt = deepl_lang(&req.tgt);
        let mut form = vec![("text", req.text.clone()), ("target_lang", tgt.to_string())];
        if !req.src.is_empty() && req.src != "auto" {
            form.push(("source_lang", deepl_lang(&req.src).to_string()));
        }
        if let Some(formality) = self.opt("formality") {
            if formality != "default" {
                form.push(("formality", formality));
            }
        }
        let resp: Value = self
            .client
            .post(host)
            .header("Authorization", format!("DeepL-Auth-Key {key}"))
            .form(&form)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        resp.pointer("/translations/0/text")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .ok_or_else(|| TranslateError::Msg("deepl empty".into()))
    }

    async fn libretranslate(&self, req: TranslateRequest) -> Result<String, TranslateError> {
        let base = self
            .opt("base_url")
            .unwrap_or_else(|| "http://127.0.0.1:5000".into())
            .trim_end_matches('/')
            .to_string();
        let origin = base.trim_end_matches("/translate").to_string();
        let url = if base.ends_with("/translate") {
            base
        } else {
            format!("{base}/translate")
        };
        let available = self.libre_languages(&origin).await;
        let wanted_src = if req.src.is_empty() {
            "auto".into()
        } else {
            libre_lang(&req.src)
        };
        let wanted_tgt = libre_lang(&req.tgt);
        let tgt = pick_libre_code(&wanted_tgt, &available, false);
        if looks_japanese(&req.text) && !lang_installed("ja", &available) {
            return Err(TranslateError::Msg(format!(
                "LibreTranslate has no Japanese model (installed: {}). Use Google/DeepL, or install Argos ja.",
                installed_label(&available)
            )));
        }
        let src = pick_libre_code(&wanted_src, &available, !looks_japanese(&req.text));
        let mut attempts = vec![(src.clone(), tgt.clone())];
        if src != "auto" && !looks_japanese(&req.text) {
            attempts.push(("auto".into(), tgt.clone()));
        }
        if tgt != wanted_tgt {
            attempts.push((src.clone(), wanted_tgt.clone()));
        }
        if !looks_japanese(&req.text) {
            attempts.push(("en".into(), tgt.clone()));
            attempts.push(("auto".into(), alt_zh(&tgt)));
        }

        let mut last = TranslateError::Msg("libretranslate failed".into());
        let mut seen = std::collections::BTreeSet::new();
        for (s, t) in attempts {
            if !seen.insert((s.clone(), t.clone())) {
                continue;
            }
            match self.libre_once(&url, &req.text, &s, &t).await {
                Ok(text) => return Ok(text),
                Err(e) if is_unsupported_lang(&e) => last = e,
                Err(e) => return Err(e),
            }
        }
        Err(last)
    }

    async fn libre_languages(&self, origin: &str) -> Vec<String> {
        let url = format!("{origin}/languages");
        let Ok(resp) = self.client.get(&url).send().await else {
            return vec![];
        };
        let Ok(v) = resp.json::<Value>().await else {
            return vec![];
        };
        v.as_array()
            .map(|arr| {
                arr.iter()
                    .filter_map(|item| item.get("code").and_then(|c| c.as_str()).map(|s| s.to_string()))
                    .collect()
            })
            .unwrap_or_default()
    }

    async fn libre_once(&self, url: &str, text: &str, src: &str, tgt: &str) -> Result<String, TranslateError> {
        let mut body = json!({
            "q": text,
            "source": src,
            "target": tgt,
            "format": "text",
        });
        if let Some(key) = self.opt("api_key") {
            body["api_key"] = json!(key);
        }
        let resp: Value = self
            .client
            .post(url)
            .header(CONTENT_TYPE, "application/json")
            .json(&body)
            .send()
            .await?
            .json()
            .await?;
        if let Some(err) = resp.get("error").and_then(|v| v.as_str()) {
            return Err(TranslateError::Msg(format!("libretranslate: {err}")));
        }
        resp.get("translatedText")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| TranslateError::Msg(format!("libretranslate empty: {resp}")))
    }

    async fn google(&self, req: TranslateRequest) -> Result<String, TranslateError> {
        let url = format!(
            "https://translate.googleapis.com/translate_a/single?client=gtx&sl={}&tl={}&dt=t&q={}",
            if req.src.is_empty() { "auto" } else { &req.src },
            req.tgt,
            urlencoding::encode(&req.text)
        );
        let resp: Value = self.client.get(url).send().await?.error_for_status()?.json().await?;
        let mut out = String::new();
        if let Some(arr) = resp.get(0).and_then(|v| v.as_array()) {
            for chunk in arr {
                if let Some(s) = chunk.get(0).and_then(|v| v.as_str()) {
                    out.push_str(s);
                }
            }
        }
        if out.is_empty() {
            Err(TranslateError::Msg("google empty".into()))
        } else {
            Ok(out)
        }
    }

    async fn dashscope(&self, req: TranslateRequest) -> Result<String, TranslateError> {
        let key = self.opt("api_key").ok_or_else(|| TranslateError::Msg("dashscope api_key required".into()))?;
        let model = self.opt("model").unwrap_or_else(|| "qwen-plus".into());
        let url = "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions";
        let system = build_system(&req.src, &req.tgt, &req.context, self.opt("instruction").as_deref(), self.opt("formality").as_deref());
        let body = json!({
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": req.text}
            ]
        });
        let resp: Value = self
            .client
            .post(url)
            .header(AUTHORIZATION, format!("Bearer {key}"))
            .json(&body)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        resp.pointer("/choices/0/message/content")
            .and_then(|v| v.as_str())
            .map(|s| s.trim().to_string())
            .ok_or_else(|| TranslateError::Msg("qwen empty".into()))
    }

    fn opt(&self, key: &str) -> Option<String> {
        self.options
            .get(key)
            .and_then(|v| v.as_str())
            .filter(|s| !s.is_empty())
            .map(|s| s.to_string())
    }
}

fn build_system(src: &str, tgt: &str, context: &[String], instruction: Option<&str>, formality: Option<&str>) -> String {
    let pair = if src.is_empty() || src == "auto" {
        format!("Translate into {tgt}.")
    } else {
        format!("Translate from {src} into {tgt}.")
    };
    let tone = match formality {
        Some("more") => " Use a more formal register.",
        Some("less") => " Use a more casual register.",
        _ => "",
    };
    let mut s = format!(
        "You are a subtitle translator. {pair}{tone} \
Keep tone, names, and line length suitable for on-screen captions. \
Output only the translation, no quotes or notes."
    );
    if let Some(extra) = instruction.filter(|t| !t.is_empty()) {
        s.push_str("\nExtra instruction: ");
        s.push_str(extra);
    }
    if !context.is_empty() {
        s.push_str("\nPrevious lines:\n");
        for line in context {
            s.push_str("- ");
            s.push_str(line);
            s.push('\n');
        }
    }
    s
}

fn deepl_endpoint(key: &str, endpoint: Option<&str>) -> &'static str {
    let free = match endpoint {
        Some("free") => true,
        Some("pro") => false,
        _ => key.ends_with(":fx"),
    };
    if free {
        "https://api-free.deepl.com/v2/translate"
    } else {
        "https://api.deepl.com/v2/translate"
    }
}

fn deepl_lang(code: &str) -> &str {
    match code {
        "zh" | "zh-CN" | "zh-Hans" => "ZH",
        "zh-TW" | "zh-Hant" => "ZH-HANT",
        "en" | "en-US" | "en-GB" => "EN",
        "ja" => "JA",
        "ko" => "KO",
        "de" => "DE",
        "fr" => "FR",
        "es" => "ES",
        "it" => "IT",
        "pt" | "pt-BR" => "PT",
        "ru" => "RU",
        "ar" => "AR",
        "id" => "ID",
        "nl" => "NL",
        "pl" => "PL",
        "tr" => "TR",
        "uk" => "UK",
        other => other,
    }
}

fn iso_lang(code: &str) -> String {
    match code.trim().to_lowercase().as_str() {
        "" | "auto" | "unknown" => "auto".into(),
        "en" | "en-us" | "en-gb" | "english" => "en".into(),
        "zh" | "zh-cn" | "zh-hans" | "chinese" | "mandarin" | "chinese (simplified)" => "zh".into(),
        "zh-tw" | "zh-hant" | "chinese (traditional)" => "zh-TW".into(),
        "ja" | "jp" | "japanese" => "ja".into(),
        "ko" | "kr" | "korean" => "ko".into(),
        "fr" | "french" => "fr".into(),
        "de" | "german" => "de".into(),
        "es" | "spanish" => "es".into(),
        other => other.to_string(),
    }
}

fn libre_lang(code: &str) -> String {
    iso_lang(code)
}

fn alt_zh(code: &str) -> String {
    match code {
        "zh" => "zh-Hans".into(),
        "zh-Hans" => "zh".into(),
        "zh-TW" | "zt" => "zh-Hant".into(),
        other => other.to_string(),
    }
}

fn pick_libre_code(wanted: &str, available: &[String], allow_auto: bool) -> String {
    if wanted == "auto" {
        return "auto".into();
    }
    if available.is_empty() {
        return wanted.to_string();
    }
    if let Some(hit) = available.iter().find(|c| c.eq_ignore_ascii_case(wanted)) {
        return hit.clone();
    }
    let want = wanted.to_lowercase();
    if let Some(hit) = available.iter().find(|c| c.to_lowercase().starts_with(&want) || want.starts_with(&c.to_lowercase())) {
        return hit.clone();
    }
    if want.starts_with("zh") {
        if let Some(hit) = available.iter().find(|c| c.to_lowercase().starts_with("zh")) {
            return hit.clone();
        }
    }
    if allow_auto {
        "auto".into()
    } else {
        wanted.to_string()
    }
}

fn is_unsupported_lang(err: &TranslateError) -> bool {
    let s = err.to_string().to_lowercase();
    s.contains("not supported") || s.contains("not available") || s.contains("invalid")
}

fn looks_japanese(s: &str) -> bool {
    s.chars().any(|c| ('\u{3040}'..='\u{30FF}').contains(&c))
}

fn lang_installed(code: &str, available: &[String]) -> bool {
    if available.is_empty() {
        return true;
    }
    let want = code.to_lowercase();
    available.iter().any(|c| {
        let c = c.to_lowercase();
        c == want || c.starts_with(&want) || want.starts_with(&c)
    })
}

fn installed_label(available: &[String]) -> String {
    if available.is_empty() {
        "unknown".into()
    } else {
        available.join(", ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deepl_free_keys_use_free_host() {
        assert!(deepl_endpoint("xxxx:fx", None).contains("api-free.deepl.com"));
        assert!(deepl_endpoint("pro-key", None).contains("://api.deepl.com"));
        assert!(deepl_endpoint("xxxx:fx", Some("pro")).contains("://api.deepl.com"));
        assert!(deepl_endpoint("pro-key", Some("free")).contains("api-free.deepl.com"));
    }

    #[test]
    fn deepl_zh_maps_to_zh() {
        assert_eq!(deepl_lang("zh"), "ZH");
        assert_eq!(deepl_lang("zh-TW"), "ZH-HANT");
    }

    #[test]
    fn libre_zh_and_auto() {
        assert_eq!(libre_lang("zh-CN"), "zh");
        assert_eq!(libre_lang("auto"), "auto");
        assert_eq!(libre_lang("JA"), "ja");
        assert_eq!(iso_lang("English"), "en");
        assert_eq!(iso_lang("Japanese"), "ja");
    }

    #[test]
    fn pick_zh_hans_and_drop_ja() {
        let langs = vec!["en".into(), "zh-Hans".into()];
        assert_eq!(pick_libre_code("zh", &langs, false), "zh-Hans");
        assert_eq!(pick_libre_code("ja", &langs, true), "auto");
        assert_eq!(pick_libre_code("en", &langs, true), "en");
        assert!(looks_japanese("ここなんだけど"));
        assert!(!looks_japanese("Hello"));
        assert!(!lang_installed("ja", &langs));
    }

    #[test]
    fn parse_libretranslate_body() {
        let resp: Value = serde_json::from_str(r#"{"translatedText":"你好"}"#).unwrap();
        assert_eq!(resp["translatedText"], "你好");
    }

    #[tokio::test]
    async fn libre_lan_ja_falls_back_to_auto() {
        let base = "http://192.168.0.3:5000";
        if reqwest::get(format!("{base}/languages")).await.is_err() {
            return;
        }
        let tr = Translator::new(
            "libretranslate",
            json!({"base_url": base, "source_lang": "ja", "target_lang": "zh"}),
        );
        let out = tr
            .translate(TranslateRequest {
                text: "Hello, this is a test.".into(),
                src: tr.resolve_src(None),
                tgt: tr.target_lang(),
                context: vec![],
            })
            .await
            .expect("libretranslate");
        assert!(
            out.contains("你好") || out.contains("测试") || out.contains("這"),
            "unexpected translation: {out}"
        );
    }
}

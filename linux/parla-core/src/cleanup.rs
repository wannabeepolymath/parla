use crate::config::Cleanup;
use crate::prompt::{self, Context};
use std::collections::BTreeMap;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq)]
pub struct Outcome {
    /// Always usable text: the cleaned version, or the raw transcript on failure.
    pub text: String,
    /// Short, user-facing reason. None means cleanup succeeded.
    pub failure: Option<String>,
}

/// Models sometimes wrap output in quotes or prepend a preamble despite the
/// system prompt. Strip both; leave everything else untouched.
pub fn sanitize(text: &str) -> String {
    let mut t = text.trim();
    // Only a *wrapping* pair. A quote inside the candidate body means the outer
    // ones are punctuation, not packaging — `"a" and "b"` must survive intact.
    if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') && !t[1..t.len() - 1].contains('"') {
        t = t[1..t.len() - 1].trim();
    }
    // A preamble is a short lead-in ending in ": ", e.g. "Here is the text: ".
    // Guard on length so an ordinary sentence containing a colon survives.
    if let Some(i) = t.find(": ") {
        let head = &t[..i];
        let lower = head.to_ascii_lowercase();
        if head.len() <= 40 && (lower.contains("text") || lower.contains("here")) {
            t = &t[i + 2..];
        }
    }
    t.trim().to_string()
}

/// Character ceiling for a cleaned result. Cleanup legitimately grows text a
/// little (punctuation) and triggered snippets a lot, so allow 2x + 200 plus
/// every matched expansion. Beyond this the output is a repetition loop.
// ponytail: char-count ceiling, not repeated-substring detection — upgrade if a
// real cleanup ever trips this.
pub fn allowance(transcript: &str, snippets: &BTreeMap<String, String>) -> usize {
    let lower = transcript.to_lowercase();
    let expansions: usize = snippets
        .iter()
        .map(|(k, v)| {
            if k.is_empty() {
                return 0; // an empty needle would match forever
            }
            lower.matches(&k.to_lowercase()).count() * v.chars().count()
        })
        .sum();
    2 * transcript.len() + 200 + expansions
}

fn api_key(cfg: &Cleanup) -> Option<String> {
    cfg.api_key_env
        .as_ref()
        .and_then(|n| std::env::var(n).ok())
        .filter(|k| !k.is_empty())
        .or_else(|| cfg.api_key.clone())
        .filter(|k| !k.is_empty())
}

/// Short, user-facing reason for an HTTP failure. Takes `cfg` rather than a
/// pre-computed flag so the whole decision — including *which* config makes a
/// 400 legible — is testable without standing up a server.
fn status_reason(status: u16, cfg: &Cleanup) -> &'static str {
    match status {
        401 | 403 => "invalid API key",
        429 => "rate limited",
        // Groq and OpenAI *require* `model` and answer 400 without it, so an
        // omitted model is by far the likeliest cause. "cleanup API error"
        // would leave the user with nothing to act on.
        400 if cfg.provider == "openai-compatible" && cfg.model.is_none() => {
            "cleanup rejected the request: set cleanup.model"
        }
        500..=599 => "cleanup service unavailable",
        _ => "cleanup API error",
    }
}

/// The assistant text out of either provider's reply shape — Anthropic's
/// `content[0].text` or the OpenAI-compatible `choices[0].message.content`.
/// A shape we don't recognise yields "", which `finish` reports as no text.
fn reply_text(json: &serde_json::Value) -> &str {
    json["content"][0]["text"]
        .as_str()
        .or_else(|| json["choices"][0]["message"]["content"].as_str())
        .unwrap_or("")
}

/// Turns the model's raw reply into an Outcome. Split from `clean` so the two
/// guards ported from Swift — the sanitizer and the degenerate-output ceiling —
/// are testable without standing up an HTTP server.
fn finish(content: &str, transcript: &str, ctx: &Context) -> Outcome {
    let cleaned = sanitize(content);
    let keep_raw = |why: &str| Outcome {
        text: transcript.to_string(),
        failure: Some(why.into()),
    };
    if cleaned.is_empty() {
        return keep_raw("cleanup returned no text");
    }
    if cleaned.len() > allowance(transcript, &ctx.snippets) {
        return keep_raw("cleanup returned invalid text");
    }
    Outcome { text: cleaned, failure: None }
}

/// Never returns Err. Every failure yields the raw transcript plus a reason, so
/// a broken provider config degrades to "you get your words, unpolished".
pub async fn clean(transcript: &str, ctx: &Context, cfg: &Cleanup) -> Outcome {
    let raw = || Outcome { text: transcript.to_string(), failure: None };
    let fail = |why: &str| Outcome { text: transcript.to_string(), failure: Some(why.into()) };

    if cfg.provider == "none" {
        return raw();
    }
    let Some(key) = api_key(cfg) else {
        return fail("no API key");
    };

    let sys = prompt::system(ctx);
    let usr = prompt::user(transcript, ctx);
    let client = match reqwest::Client::builder().timeout(Duration::from_secs(20)).build() {
        Ok(c) => c,
        Err(_) => return fail("cleanup client unavailable"),
    };

    let response = match cfg.provider.as_str() {
        "anthropic" => {
            let model = cfg.model.clone().unwrap_or_else(|| "claude-sonnet-5".into());
            client
                .post("https://api.anthropic.com/v1/messages")
                .header("x-api-key", key)
                .header("anthropic-version", "2023-06-01")
                .json(&serde_json::json!({
                    "model": model,
                    "max_tokens": 4096,
                    "system": sys,
                    "messages": [{ "role": "user", "content": usr }],
                }))
                .send()
                .await
        }
        "openai-compatible" => {
            let Some(base) = &cfg.base_url else {
                return fail("cleanup base_url not set");
            };
            let mut body = serde_json::json!({
                "messages": [
                    { "role": "system", "content": sys },
                    { "role": "user", "content": usr },
                ],
            });
            // Omitted on purpose when unset: some servers pick a default. The
            // ones that don't answer 400, which `status_reason` makes legible.
            if let Some(m) = &cfg.model {
                body["model"] = serde_json::Value::String(m.clone());
            }
            client
                .post(format!("{}/chat/completions", base.trim_end_matches('/')))
                .bearer_auth(key)
                .json(&body)
                .send()
                .await
        }
        _ => return fail("unknown cleanup provider"),
    };

    let response = match response {
        Ok(r) => r,
        Err(e) if e.is_timeout() => return fail("cleanup timed out"),
        Err(_) => return fail("cleanup network unavailable"),
    };
    if !response.status().is_success() {
        return fail(status_reason(response.status().as_u16(), cfg));
    }
    let Ok(json) = response.json::<serde_json::Value>().await else {
        return fail("cleanup returned invalid JSON");
    };

    finish(reply_text(&json), transcript, ctx)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[test]
    fn sanitizer_strips_wrapping_quotes() {
        assert_eq!(sanitize("\"hello there\""), "hello there");
        assert_eq!(sanitize("  \"hello\"  "), "hello");
        // An interior quote is content, not a wrapper.
        assert_eq!(sanitize("he said \"hi\" loudly"), "he said \"hi\" loudly");
        // Unbalanced quotes are left alone.
        assert_eq!(sanitize("\"hello"), "\"hello");
    }

    #[test]
    fn sanitizer_strips_a_leading_preamble() {
        assert_eq!(sanitize("Here is the cleaned text: hello there"), "hello there");
        assert_eq!(sanitize("Cleaned text: hello"), "hello");
        assert_eq!(sanitize("hello: world"), "hello: world");
    }

    #[test]
    fn sanitizer_leaves_ordinary_text_alone() {
        assert_eq!(sanitize("The meeting is at 6."), "The meeting is at 6.");
    }

    #[test]
    fn allowance_scales_with_transcript_length() {
        let empty = BTreeMap::new();
        assert_eq!(allowance("hello", &empty), 2 * 5 + 200);
    }

    #[test]
    fn allowance_adds_room_for_each_triggered_snippet() {
        let mut s = BTreeMap::new();
        s.insert("my address".to_string(), "1 Main Street, Springfield".to_string());
        // Trigger appears twice => two expansions of room.
        let t = "my address and also my address";
        assert_eq!(allowance(t, &s), 2 * t.len() + 200 + 26 * 2);
    }

    #[test]
    fn allowance_ignores_untriggered_snippets() {
        let mut s = BTreeMap::new();
        s.insert("my address".to_string(), "1 Main Street".to_string());
        assert_eq!(allowance("hello there", &s), 2 * 11 + 200);
    }

    #[test]
    fn allowance_matches_trigger_case_insensitively() {
        let mut s = BTreeMap::new();
        s.insert("my address".to_string(), "1 Main St".to_string());
        let t = "MY ADDRESS";
        assert_eq!(allowance(t, &s), 2 * t.len() + 200 + 9);
    }

    #[test]
    fn empty_snippet_key_cannot_cause_an_infinite_loop() {
        let mut s = BTreeMap::new();
        s.insert(String::new(), "x".to_string());
        assert_eq!(allowance("hello", &s), 2 * 5 + 200);
    }

    #[test]
    fn quoted_speech_inside_the_reply_is_not_treated_as_a_wrapper() {
        // Matches Sources/ParlaCore/Cleanup.swift's CleanupSanitizer: an inner
        // quote means the outer ones are punctuation, so stripping would corrupt.
        assert_eq!(sanitize("\"a\" and \"b\""), "\"a\" and \"b\"");
    }

    #[test]
    fn both_provider_reply_shapes_are_understood() {
        let anthropic = serde_json::json!({ "content": [{ "type": "text", "text": "hi" }] });
        assert_eq!(reply_text(&anthropic), "hi");
        let openai = serde_json::json!({
            "choices": [{ "message": { "role": "assistant", "content": "hi" } }]
        });
        assert_eq!(reply_text(&openai), "hi");
        // An unrecognised shape must not panic; "" becomes "cleanup returned no text".
        assert_eq!(reply_text(&serde_json::json!({ "error": "nope" })), "");
    }

    #[test]
    fn degenerate_output_keeps_the_raw_transcript() {
        let ctx = Context::default();
        let t = "hello";
        let loop_output = "hello ".repeat(100); // 600 chars, ceiling is 210
        let out = finish(&loop_output, t, &ctx);
        assert_eq!(out.text, t);
        assert_eq!(out.failure.as_deref(), Some("cleanup returned invalid text"));
    }

    #[test]
    fn output_within_the_ceiling_is_accepted() {
        let out = finish("\"Hello there.\"", "um hello there", &Context::default());
        assert_eq!(out.text, "Hello there.");
        assert_eq!(out.failure, None);
    }

    #[test]
    fn empty_output_keeps_the_raw_transcript() {
        let out = finish("   ", "hello", &Context::default());
        assert_eq!(out.text, "hello");
        assert_eq!(out.failure.as_deref(), Some("cleanup returned no text"));
    }

    #[test]
    fn an_omitted_model_is_named_in_the_400_reason() {
        // Groq and OpenAI reject a request with no `model`; "cleanup API error"
        // would leave the user with nothing to fix.
        let no_model = Cleanup {
            provider: "openai-compatible".into(),
            model: None,
            ..Default::default()
        };
        let with_model = Cleanup { model: Some("m".into()), ..no_model.clone() };
        assert_eq!(
            status_reason(400, &no_model),
            "cleanup rejected the request: set cleanup.model"
        );
        assert_eq!(status_reason(400, &with_model), "cleanup API error");
        // Anthropic supplies its own default model, so a 400 there is something else.
        let anthropic = Cleanup { provider: "anthropic".into(), model: None, ..Default::default() };
        assert_eq!(status_reason(400, &anthropic), "cleanup API error");
    }

    #[test]
    fn http_failures_map_to_actionable_reasons() {
        let c = Cleanup::default();
        assert_eq!(status_reason(401, &c), "invalid API key");
        assert_eq!(status_reason(403, &c), "invalid API key");
        assert_eq!(status_reason(429, &c), "rate limited");
        assert_eq!(status_reason(503, &c), "cleanup service unavailable");
        assert_eq!(status_reason(404, &c), "cleanup API error");
    }

    #[tokio::test]
    async fn unknown_provider_is_reported_not_silently_skipped() {
        let cfg = Cleanup {
            provider: "gopher".into(),
            api_key: Some("k".into()),
            api_key_env: None,
            ..Default::default()
        };
        let out = clean("hello", &Context::default(), &cfg).await;
        assert_eq!(out.text, "hello");
        assert_eq!(out.failure.as_deref(), Some("unknown cleanup provider"));
    }

    #[tokio::test]
    async fn openai_compatible_without_a_base_url_is_reported() {
        let cfg = Cleanup {
            provider: "openai-compatible".into(),
            base_url: None,
            api_key: Some("k".into()),
            api_key_env: None,
            ..Default::default()
        };
        let out = clean("hello", &Context::default(), &cfg).await;
        assert_eq!(out.text, "hello");
        assert_eq!(out.failure.as_deref(), Some("cleanup base_url not set"));
    }

    #[tokio::test]
    async fn provider_none_returns_the_raw_transcript_with_no_failure() {
        let cfg = Cleanup { provider: "none".into(), ..Default::default() };
        let out = clean("um hello there", &Context::default(), &cfg).await;
        assert_eq!(out.text, "um hello there");
        assert_eq!(out.failure, None);
    }

    #[tokio::test]
    async fn missing_api_key_returns_raw_with_a_reason() {
        let cfg = Cleanup {
            provider: "anthropic".into(),
            api_key_env: Some("PARLA_TEST_DEFINITELY_UNSET".into()),
            api_key: None,
            ..Default::default()
        };
        let out = clean("hello", &Context::default(), &cfg).await;
        assert_eq!(out.text, "hello");
        assert_eq!(out.failure.as_deref(), Some("no API key"));
    }

    #[tokio::test]
    async fn unreachable_endpoint_returns_raw_with_a_reason() {
        let cfg = Cleanup {
            provider: "openai-compatible".into(),
            // Reserved TEST-NET-1 address; connection fails fast without DNS.
            base_url: Some("http://192.0.2.1:1/v1".into()),
            api_key: Some("k".into()),
            api_key_env: None,
            model: Some("m".into()),
        };
        let out = clean("hello", &Context::default(), &cfg).await;
        assert_eq!(out.text, "hello", "a dead endpoint must never lose the transcript");
        assert!(out.failure.is_some());
    }

    /// The test above reaches `clean` through the *timeout* arm — a TEST-NET-1
    /// address black-holes the SYN, so it costs the full 20s client timeout and
    /// never exercises the ordinary connection-error arm. Loopback port 1 is
    /// refused immediately, which does, in microseconds.
    #[tokio::test]
    async fn a_refused_connection_returns_raw_with_a_reason() {
        let cfg = Cleanup {
            provider: "openai-compatible".into(),
            base_url: Some("http://127.0.0.1:1/v1".into()),
            api_key: Some("k".into()),
            api_key_env: None,
            model: Some("m".into()),
        };
        let out = clean("hello", &Context::default(), &cfg).await;
        assert_eq!(out.text, "hello");
        assert_eq!(out.failure.as_deref(), Some("cleanup network unavailable"));
    }
}

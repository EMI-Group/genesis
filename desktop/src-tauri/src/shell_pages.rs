//! Presentation-only, self-contained shell pages; no lifecycle decisions or IPC.

const CSS: &str = include_str!("shell_pages.css");
const DATA_PREFIX: &str = "data:text/html;charset=utf-8,";
const SLOW_START_SCRIPT: &str = "<script>setTimeout(function(){var el=document.getElementById('status');if(el){el.textContent='Still starting — this is taking longer than usual.';}},15000);</script>";

/// Percent-encode UTF-8 bytes, keeping only RFC 3986 unreserved characters.
pub fn percent_encode(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    for byte in input.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(byte as char);
        } else {
            out.push('%');
            out.push_str(&format!("{byte:02X}"));
        }
    }
    out
}

/// Shared document structure keeps typography, landmarks and styling consistent.
/// All arguments except `action` are static shell-owned strings.
fn page(
    title: &str,
    state: &str,
    heading: &str,
    message: &str,
    kind: &str,
    action: &str,
) -> String {
    let icon = match kind {
        "loading" => r#"<span class="spinner" aria-hidden="true"></span>"#,
        "error" => r#"<span class="state-icon" aria-hidden="true">!</span>"#,
        _ => r#"<span class="state-icon" aria-hidden="true">·</span>"#,
    };
    let script = if kind == "loading" {
        SLOW_START_SCRIPT
    } else {
        ""
    };
    let html = format!(
        r#"<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>{title}</title><style>{CSS}</style></head><body><main class="card {kind}" aria-labelledby="heading"><div class="brand"><span class="brand-mark" aria-hidden="true"></span>Genesis</div><div class="state">{icon}<span>{state}</span></div><h1 id="heading">{heading}</h1><p id="status" role="status" aria-live="polite" aria-atomic="true">{message}</p>{action}</main>{script}</body></html>"#
    );
    format!("{DATA_PREFIX}{}", percent_encode(&html))
}

/// A regular top-level navigation, with no IPC or remote resources.
/// Escape the URL for both the JS string and its enclosing HTML attribute.
fn action(backend_url: &str, label: &str) -> String {
    let js_url = backend_url
        .replace('\\', "\\\\")
        .replace('\'', "\\'")
        .replace('\r', "\\r")
        .replace('\n', "\\n")
        .replace('\u{2028}', "\\u2028")
        .replace('\u{2029}', "\\u2029");
    let attribute = js_url
        .replace('&', "&amp;")
        .replace('"', "&quot;")
        .replace('<', "&lt;")
        .replace('>', "&gt;");
    format!(
        r#"<button type="button" onclick="window.location.href='{attribute}'">{label}</button>"#
    )
}

/// Genuine backend failure; the watchdog owns automatic recovery.
pub fn error_page_data_url(backend_url: &str) -> String {
    page(
        "Genesis — Backend Unavailable",
        "Reconnecting",
        "Genesis backend unavailable",
        "The dashboard backend has stopped responding. It will be restarted automatically.",
        "error",
        &action(backend_url, "Retry now"),
    )
}

/// Honest fallback for a healthy backend whose dashboard has not loaded yet.
pub fn startup_page_data_url(backend_url: &str) -> String {
    page(
        "Genesis — Starting up",
        "Starting up",
        "Genesis is starting up",
        "The backend is running and the dashboard is taking longer than usual to load. Open it with the button below.",
        "startup",
        &action(backend_url, "Open the dashboard"),
    )
}

/// Boot-only loading presentation; no action, no backend URL, no recovery claim.
pub fn loading_page_data_url() -> String {
    page(
        "Genesis — Starting",
        "Starting up",
        "Genesis",
        "Starting Genesis… preparing the workspace. This usually takes a few seconds.",
        "loading",
        "",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(url: &str) -> String {
        let encoded = url.strip_prefix(DATA_PREFIX).expect("HTML data URL");
        let bytes = encoded.as_bytes();
        let mut decoded = Vec::new();
        let mut i = 0;
        while i < bytes.len() {
            if bytes[i] == b'%' {
                decoded.push(u8::from_str_radix(&encoded[i + 1..i + 3], 16).unwrap());
                i += 3;
            } else {
                decoded.push(bytes[i]);
                i += 1;
            }
        }
        String::from_utf8(decoded).unwrap()
    }

    #[test]
    fn pages_share_accessible_responsive_structure_and_style() {
        for url in [
            loading_page_data_url(),
            startup_page_data_url("http://127.0.0.1:80"),
            error_page_data_url("http://127.0.0.1:80"),
        ] {
            let html = decode(&url);
            assert!(html.contains(CSS));
            assert_eq!(html.matches("<style>").count(), 1);
            assert_eq!(html.matches("<main ").count(), 1);
            assert_eq!(html.matches("<h1 ").count(), 1);
            assert!(html.contains("<html lang=\"en\">"));
            assert!(html.contains("width=device-width, initial-scale=1"));
            assert!(!html.contains("maximum-scale"));
            assert!(html.contains("aria-labelledby=\"heading\""));
            assert!(html.contains("aria-live=\"polite\" aria-atomic=\"true\""));
            assert!(html.contains("button:focus-visible"));
            assert!(html.contains("prefers-reduced-motion:reduce"));
            assert!(html.contains(".spinner{animation:none}button{transition:none}"));
            assert!(html.contains("forced-colors:active"));
            for forbidden in [
                "<link",
                "<img",
                "<iframe",
                "src=",
                "url(",
                "@import",
                "__TAURI__",
                "invoke(",
                "fetch(",
            ] {
                assert!(
                    !html.contains(forbidden),
                    "unexpected resource/IPC: {forbidden}"
                );
            }
            for ch in ['#', ' ', '"', '<', '\n'] {
                assert!(!url.contains(ch));
            }
        }
    }

    #[test]
    fn loading_hint_is_optional_and_does_not_navigate() {
        let html = decode(&loading_page_data_url());
        assert!(html.contains(
            "Starting Genesis… preparing the workspace. This usually takes a few seconds."
        ));
        assert!(html.contains("Still starting — this is taking longer than usual."));
        assert!(html.contains("},15000)"));
        assert!(html.contains("@keyframes spin"));
        assert!(html.contains("class=\"spinner\" aria-hidden=\"true\""));
        assert!(!html.contains("<button"));
        assert!(!html.contains("window.location"));
        assert!(!html.contains("http://"));
        assert!(!html.contains("unavailable"));
        assert!(!html.contains("restarted automatically"));
    }

    #[test]
    fn action_pages_keep_distinct_meaning_and_manual_navigation_only() {
        let backend = "http://127.0.0.1:43123";
        let error = decode(&error_page_data_url(backend));
        let startup = decode(&startup_page_data_url(backend));
        assert_ne!(error, startup);
        assert!(error.contains("Genesis backend unavailable"));
        assert!(error.contains("It will be restarted automatically."));
        assert!(error.contains(">Retry now</button>"));
        assert!(startup.contains("The backend is running"));
        assert!(startup.contains(">Open the dashboard</button>"));
        assert!(!startup.contains("unavailable"));
        assert!(!startup.contains("restarted automatically"));
        for html in [error, startup] {
            assert_eq!(html.matches("<button type=\"button\"").count(), 1);
            assert!(html.contains(&format!("onclick=\"window.location.href='{backend}'\"")));
            assert!(!html.contains("<script>"));
            assert!(!html.contains("setTimeout"));
        }
    }

    #[test]
    fn encoding_roundtrips_unicode_empty_and_reserved_bytes() {
        for text in ["", "abc-._~123", "<html># & \"'\n", "Genesis… 中文 🦀"] {
            assert_eq!(
                decode(&format!("{DATA_PREFIX}{}", percent_encode(text))),
                text
            );
        }
        assert_eq!(percent_encode("abc-._~123"), "abc-._~123");
        assert_eq!(percent_encode("% /"), "%25%20%2F");
    }

    #[test]
    fn navigation_url_cannot_break_out_of_attribute_or_js_string() {
        let html = decode(&error_page_data_url(
            "http://127.0.0.1:80/?x='\"<&\\\n\r\u{2028}\u{2029}",
        ));
        assert!(html.contains(r#"onclick="window.location.href='http://127.0.0.1:80/?x=\'&quot;&lt;&amp;\\\n\r\u2028\u2029'""#));
        assert_eq!(html.matches("onclick=").count(), 1);
        assert_eq!(html.matches("<button").count(), 1);
        // The empty boundary remains a harmless manual navigation, not a script.
        assert!(decode(&startup_page_data_url("")).contains("window.location.href=''"));
    }
}

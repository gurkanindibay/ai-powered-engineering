//! Real notification sender: the WEBHOOK gateway behind `NotificationSender`.
//! This binary owns the process environment, so the delivery checks live in a
//! single sequential test.

use sitepulse_backend::domain::kvkk::DeliveryChannel;
use sitepulse_backend::models::{NOTIFY_FAILED, NOTIFY_SENT};
use sitepulse_backend::services::notification_service::{
    Message, NotificationService, Recipient, WebhookSender,
};
use sitepulse_backend::state::AppState;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

const TOKEN: &str = "test-gateway-token-not-real";

/// Serves one canned response and returns the raw request it received.
async fn gateway(
    status_line: &'static str,
    body: &'static str,
) -> (String, tokio::task::JoinHandle<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/send", listener.local_addr().unwrap());
    let handle = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut buf = vec![0u8; 8192];
        let mut raw = Vec::new();
        loop {
            let n = socket.read(&mut buf).await.unwrap();
            raw.extend_from_slice(&buf[..n]);
            let text = String::from_utf8_lossy(&raw).to_string();
            if let Some(idx) = text.find("\r\n\r\n") {
                let len = text
                    .lines()
                    .find_map(|l| {
                        l.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .and_then(|v| v.trim().parse::<usize>().ok())
                    })
                    .unwrap_or(0);
                if raw.len() >= idx + 4 + len {
                    break;
                }
            }
            if n == 0 {
                break;
            }
        }
        let reply = format!(
            "HTTP/1.1 {}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
            status_line,
            body.len(),
            body
        );
        socket.write_all(reply.as_bytes()).await.unwrap();
        String::from_utf8_lossy(&raw).to_string()
    });
    (url, handle)
}

fn message(key: &str) -> Message {
    Message {
        site_id: "1".into(),
        unit_id: Some("d-14".into()),
        channel: DeliveryChannel::Sms,
        category: "DEBT_REMINDER",
        subject: "Aidat hatirlatma".into(),
        body: "Odenmemis aidatiniz var".into(),
        dedupe_key: key.into(),
        mandatory: false,
    }
}

fn resident() -> Recipient {
    Recipient {
        reference: "usr-owner-14".into(),
        name: "Ahmet".into(),
        email: Some("ahmet@example.test".into()),
        phone: Some("+90 555 000 00 00".into()),
        has_app: true,
    }
}

#[test]
fn production_refuses_a_plain_http_gateway_and_never_prints_credentials() {
    let http_err = WebhookSender::new("http://gw.example.test", None, true).unwrap_err();
    assert!(http_err.to_string().contains("https URL"));
    let empty_err = WebhookSender::new("", None, false).unwrap_err();
    assert!(empty_err.to_string().contains("https URL"));
    let sender = WebhookSender::new(
        "https://gw.example.test/k?key=SECRET",
        Some(TOKEN.into()),
        true,
    )
    .unwrap();
    let printed = format!("{:?}", sender);
    assert!(!printed.contains("SECRET") && !printed.contains(TOKEN));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
// covers: SC-02-04-02
async fn when_a_reminder_is_delivered_then_the_gateway_receives_it_once_and_failures_are_recorded()
{
    let mut state = AppState::new_with_test_fixtures();
    state.settings.notification_sender = "WEBHOOK".into();
    state.settings.notification_webhook_token = Some(TOKEN.into());

    // Delivered: bearer token and payload reach the gateway, provider id is kept.
    let (url, handle) = gateway("200 OK", r#"{"id":"sms-123"}"#).await;
    state.settings.notification_webhook_url = Some(url.clone());
    let sent = NotificationService::new(&state)
        .deliver(message("k-1"), &resident())
        .await
        .unwrap();
    assert_eq!(sent.status, NOTIFY_SENT);
    assert_eq!(sent.provider_ref.as_deref(), Some("sms-123"));
    let request = handle.await.unwrap();
    assert!(request.contains(&format!("Bearer {}", TOKEN)));
    assert!(request.contains("\"channel\":\"SMS\"") && request.contains("+90 555 000 00 00"));

    // Dedupe: the same key never reaches the gateway again (no listener is up).
    let again = NotificationService::new(&state)
        .deliver(message("k-1"), &resident())
        .await
        .unwrap();
    assert_eq!(again.id, sent.id);

    // A gateway error is a FAILED row that leaks neither URL nor token.
    let (url, handle) = gateway("503 Service Unavailable", "{}").await;
    state.settings.notification_webhook_url = Some(url.clone());
    let failed = NotificationService::new(&state)
        .deliver(message("k-2"), &resident())
        .await
        .unwrap();
    handle.await.unwrap();
    assert_eq!(failed.status, NOTIFY_FAILED);
    let reason = failed.block_reason.unwrap();
    assert!(reason.contains("503") && !reason.contains(&url) && !reason.contains(TOKEN));

    // An unreachable gateway is also recorded as FAILED.
    state.settings.notification_webhook_url = Some("http://127.0.0.1:1/send".into());
    let down = NotificationService::new(&state)
        .deliver(message("k-3"), &resident())
        .await
        .unwrap();
    assert_eq!(down.status, NOTIFY_FAILED);
    assert!(!down.block_reason.unwrap().contains("127.0.0.1"));
}

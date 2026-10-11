use std::path::Path;
use serde::{Deserialize, Serialize};

/// Kuveyt Türk API Market Sandbox Integration Service
#[derive(Debug, Clone)]
pub struct KuveytTurkSandboxService {
    pub identity_base_url: String,
    pub gateway_base_url: String,
    pub private_key_path: String,
    pub public_key_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KuveytTurkSandboxConfig {
    pub is_sandbox: bool,
    pub identity_url: String,
    pub gateway_url: String,
    pub private_key_present: bool,
    pub public_key_present: bool,
    pub client_id_configured: bool,
    pub configured_client_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KuveytTurkTokenResponse {
    pub access_token: String,
    pub expires_in: u64,
    pub token_type: String,
    pub scope: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KuveytTurkProbeResult {
    pub success: bool,
    pub http_status: u16,
    pub message: String,
    pub environment: String,
    pub token_received: bool,
    pub token_preview: Option<String>,
    pub expires_in_seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConfigureKuveytTurkRequest {
    pub client_id: String,
    pub client_secret: String,
}

impl Default for KuveytTurkSandboxService {
    fn default() -> Self {
        Self::new()
    }
}

impl KuveytTurkSandboxService {
    pub const DEFAULT_PREP_IDENTITY: &'static str = "https://prep-identity.kuveytturk.com.tr";
    pub const DEFAULT_PREP_GATEWAY: &'static str = "https://prep-gateway.kuveytturk.com.tr";
    pub const DEFAULT_PRIVATE_KEY_PATH: &'static str = "keys/kt-private-key.asc";
    pub const DEFAULT_PUBLIC_KEY_PATH: &'static str = "keys/kt-public-key.asc";

    pub fn new() -> Self {
        Self {
            identity_base_url: std::env::var("KT_IDENTITY_URL")
                .unwrap_or_else(|_| Self::DEFAULT_PREP_IDENTITY.to_string()),
            gateway_base_url: std::env::var("KT_GATEWAY_URL")
                .unwrap_or_else(|_| Self::DEFAULT_PREP_GATEWAY.to_string()),
            private_key_path: std::env::var("KT_PRIVATE_KEY_PATH")
                .unwrap_or_else(|_| Self::DEFAULT_PRIVATE_KEY_PATH.to_string()),
            public_key_path: std::env::var("KT_PUBLIC_KEY_PATH")
                .unwrap_or_else(|_| Self::DEFAULT_PUBLIC_KEY_PATH.to_string()),
        }
    }

    /// Checks if RSA key pair exists on disk.
    pub fn get_key_status(&self) -> (bool, bool) {
        let priv_exists = Path::new(&self.private_key_path).exists()
            || Path::new(&format!("backend/{}", self.private_key_path)).exists();
        let pub_exists = Path::new(&self.public_key_path).exists()
            || Path::new(&format!("backend/{}", self.public_key_path)).exists();
        (priv_exists, pub_exists)
    }

    /// Reads current configuration summary.
    pub fn get_config_status(&self, configured_client_id: Option<&str>) -> KuveytTurkSandboxConfig {
        let (priv_key, pub_key) = self.get_key_status();
        let client_id_env = std::env::var("KT_CLIENT_ID").ok();
        let effective_client_id = configured_client_id.map(|s| s.to_string()).or(client_id_env);

        KuveytTurkSandboxConfig {
            is_sandbox: true,
            identity_url: self.identity_base_url.clone(),
            gateway_url: self.gateway_base_url.clone(),
            private_key_present: priv_key,
            public_key_present: pub_key,
            client_id_configured: effective_client_id.is_some(),
            configured_client_id: effective_client_id,
        }
    }

    /// Tests live OAuth 2.0 connectivity with Kuveyt Türk Sandbox Identity Server.
    pub async fn test_connection(
        &self,
        client_id: &str,
        client_secret: &str,
    ) -> Result<KuveytTurkProbeResult, String> {
        let token_url = format!("{}/connect/token", self.identity_base_url.trim_end_matches('/'));

        let params = [
            ("grant_type", "client_credentials"),
            ("client_id", client_id),
            ("client_secret", client_secret),
            ("scope", "public"),
        ];

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(10))
            .build()
            .map_err(|e| format!("Failed to build HTTP client: {}", e))?;

        let res = client
            .post(&token_url)
            .form(&params)
            .send()
            .await
            .map_err(|e| format!("Network probe failed reaching {}: {}", token_url, e))?;

        let status = res.status().as_u16();
        let body = res
            .text()
            .await
            .unwrap_or_else(|_| "Failed to read response body".to_string());

        if status == 200 {
            if let Ok(token_data) = serde_json::from_str::<KuveytTurkTokenResponse>(&body) {
                let preview = if token_data.access_token.len() > 16 {
                    format!("{}...", &token_data.access_token[..16])
                } else {
                    token_data.access_token.clone()
                };

                return Ok(KuveytTurkProbeResult {
                    success: true,
                    http_status: 200,
                    message: "Successfully connected to Kuveyt Türk Prep (Sandbox) Identity Server. OAuth 2.0 Bearer token acquired!".to_string(),
                    environment: "SANDBOX (PREP)".to_string(),
                    token_received: true,
                    token_preview: Some(preview),
                    expires_in_seconds: Some(token_data.expires_in),
                });
            }
        }

        Ok(KuveytTurkProbeResult {
            success: false,
            http_status: status,
            message: format!("Kuveyt Türk Sandbox responded with HTTP {}: {}", status, body),
            environment: "SANDBOX (PREP)".to_string(),
            token_received: false,
            token_preview: None,
            expires_in_seconds: None,
        })
    }
}

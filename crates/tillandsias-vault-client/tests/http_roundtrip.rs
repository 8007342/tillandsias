//! Integration tests for the Vault HTTP client, using a wiremock fake.
//!
//! These tests do NOT require a real Vault. They assert the on-the-wire
//! shape: how the client maps Vault's JSON envelopes and HTTP status codes
//! to its `Result<_, VaultError>` surface.
//!
//! @trace spec:tillandsias-vault

use serde_json::json;
use tillandsias_vault_client::{VaultClient, VaultError};
use wiremock::matchers::{body_json, header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[tokio::test]
async fn read_secret_parses_data_field() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/v1/secret/data/github/token"))
        .and(header("X-Vault-Token", "tray-root"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "request_id": "abc",
            "lease_id": "",
            "renewable": false,
            "data": {
                "data": { "token": "xyz" },
                "metadata": { "version": 1 }
            }
        })))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    let v = client
        .read_secret("secret/github/token")
        .await
        .expect("read_secret should succeed");
    assert_eq!(v["token"].as_str(), Some("xyz"));
}

#[tokio::test]
async fn read_secret_handles_404_as_not_found() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/secret/data/missing"))
        .respond_with(ResponseTemplate::new(404).set_body_string("{\"errors\":[]}"))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    let err = client
        .read_secret("secret/missing")
        .await
        .expect_err("missing secret must error");
    assert!(matches!(err, VaultError::NotFound(_)), "got: {err:?}");
}

#[tokio::test]
async fn read_secret_handles_403_as_unauthorized() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/secret/data/github/token"))
        .respond_with(
            ResponseTemplate::new(403)
                .set_body_string("{\"errors\":[\"1 error occurred: permission denied\"]}"),
        )
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "forge-token");
    let err = client
        .read_secret("secret/github/token")
        .await
        .expect_err("forge policy must 403 on github/token");
    assert!(matches!(err, VaultError::Unauthorized(_)), "got: {err:?}");
}

#[tokio::test]
async fn write_secret_wraps_in_data_envelope() {
    let server = MockServer::start().await;

    // wiremock body assertion: the request body MUST be { "data": { ... } }.
    Mock::given(method("POST"))
        .and(path("/v1/secret/data/test/key"))
        .and(header("X-Vault-Token", "tray-root"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": { "version": 1, "created_time": "now" }
        })))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    client
        .write_secret("secret/test/key", json!({ "hello": "world" }))
        .await
        .expect("write_secret should succeed");
}

#[tokio::test]
async fn issue_approle_token_returns_client_token_field() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/v1/auth/approle/role/git-mirror/role-id"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": { "role_id": "rid-abc" }
        })))
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/v1/auth/approle/role/git-mirror/secret-id"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": { "secret_id": "sid-xyz", "secret_id_accessor": "sa-1" }
        })))
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/v1/auth/approle/login"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "auth": {
                "client_token": "hvs.minted-token-12345",
                "policies": ["git-mirror-policy"],
                "lease_duration": 3600
            }
        })))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    let token = client
        .issue_approle_token("git-mirror")
        .await
        .expect("issue_approle_token should succeed");
    assert_eq!(token, "hvs.minted-token-12345");
}

#[tokio::test]
async fn issue_approle_credentials_returns_reauth_material_without_logging_in() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/v1/auth/approle/role/git-mirror/role-id"))
        .and(header("X-Vault-Token", "tray-root"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": { "role_id": "rid-agent" }
        })))
        .mount(&server)
        .await;

    Mock::given(method("POST"))
        .and(path("/v1/auth/approle/role/git-mirror/secret-id"))
        .and(header("X-Vault-Token", "tray-root"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": {
                "secret_id": "sid-agent",
                "secret_id_accessor": "sid-accessor-agent"
            }
        })))
        .mount(&server)
        .await;

    // This boundary deliberately returns AppRole material to Vault Agent; the
    // host must not consume it by logging in and mounting another fixed token.
    Mock::given(method("POST"))
        .and(path("/v1/auth/approle/login"))
        .respond_with(ResponseTemplate::new(500))
        .expect(0)
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    let credentials = client
        .issue_approle_credentials("git-mirror")
        .await
        .expect("credential issuance should succeed without an AppRole login");
    assert_eq!(credentials.role_id(), "rid-agent");
    assert_eq!(credentials.secret_id(), "sid-agent");
    assert_eq!(credentials.secret_id_accessor(), "sid-accessor-agent");
}

#[tokio::test]
async fn malformed_approle_response_never_echoes_secret_id() {
    let server = MockServer::start().await;

    Mock::given(method("GET"))
        .and(path("/v1/auth/approle/role/git-mirror/role-id"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": { "role_id": "rid-agent" }
        })))
        .mount(&server)
        .await;

    let issued_secret = "sid-must-never-enter-an-error";
    Mock::given(method("POST"))
        .and(path("/v1/auth/approle/role/git-mirror/secret-id"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": { "secret_id": issued_secret }
        })))
        .mount(&server)
        .await;

    let error = match VaultClient::new(server.uri(), "tray-root")
        .issue_approle_credentials("git-mirror")
        .await
    {
        Ok(_) => panic!("missing accessor must reject the malformed response"),
        Err(error) => error.to_string(),
    };
    assert!(
        error.contains("missing secret_id_accessor"),
        "schema error must name the missing field: {error}"
    );
    assert!(
        !error.contains(issued_secret),
        "schema error must never echo the adjacent SecretID: {error}"
    );
}

#[tokio::test]
async fn destroy_approle_secret_id_accessor_posts_accessor_with_root_auth() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path(
            "/v1/auth/approle/role/git-mirror/secret-id-accessor/destroy",
        ))
        .and(header("X-Vault-Token", "tray-root"))
        .and(body_json(json!({
            "secret_id_accessor": "sid-accessor-agent"
        })))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;

    VaultClient::new(server.uri(), "tray-root")
        .destroy_approle_secret_id_accessor("git-mirror", "sid-accessor-agent")
        .await
        .expect("accessor destruction should accept Vault's 204");
}

#[tokio::test]
async fn revoke_token_handles_204_no_content() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/auth/token/revoke"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    client
        .revoke_token("hvs.some-token")
        .await
        .expect("revoke should accept 204");
}

#[tokio::test]
async fn write_policy_uses_acl_endpoint() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/sys/policies/acl/git-mirror-policy"))
        .and(header("X-Vault-Token", "tray-root"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    client
        .write_policy(
            "git-mirror-policy",
            "path \"secret/data/github/token\" {}\n",
        )
        .await
        .expect("write_policy should accept 204");
}

#[tokio::test]
async fn enable_approle_swallows_already_in_use_400() {
    // Vault returns 400 with "path is already in use" when the auth method
    // is already enabled. The client must treat that as success so callers
    // can call enable_approle on every boot.
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/sys/auth/approle"))
        .respond_with(
            ResponseTemplate::new(400).set_body_string("{\"errors\":[\"path is already in use\"]}"),
        )
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    client
        .enable_approle()
        .await
        .expect("enable_approle must squash already-enabled 400");
}

#[tokio::test]
async fn create_approle_role_posts_policies_and_ttls() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/auth/approle/role/git-mirror"))
        .and(header("X-Vault-Token", "tray-root"))
        .and(body_json(json!({
            "token_policies": "git-mirror-policy",
            "token_ttl": "3600s",
            "token_max_ttl": "86400s",
            "token_num_uses": 0,
            "secret_id_num_uses": 1,
            "secret_id_ttl": "30s"
        })))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    client
        .create_approle_role("git-mirror", &["git-mirror-policy"], 3_600, 86_400)
        .await
        .expect("create_approle_role should accept 204");
}

#[tokio::test]
async fn create_approle_agent_role_posts_reusable_secret_id_lifecycle() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/v1/auth/approle/role/git-mirror-agent"))
        .and(header("X-Vault-Token", "tray-root"))
        .and(body_json(json!({
            "token_policies": "git-mirror-policy",
            "token_ttl": "3600s",
            "token_max_ttl": "86400s",
            "token_num_uses": 0,
            "secret_id_num_uses": 0,
            "secret_id_ttl": "48h"
        })))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;

    VaultClient::new(server.uri(), "tray-root")
        .create_approle_agent_role("git-mirror-agent", &["git-mirror-policy"], 3_600, 86_400)
        .await
        .expect("long-running Agent role should accept 204");
}

#[tokio::test]
async fn health_reports_sealed_state() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/sys/health"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "initialized": true,
            "sealed": false,
            "standby": false,
            "version": "1.18.1"
        })))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    let h = client.health().await.expect("health should succeed");
    assert!(h.initialized);
    assert!(!h.sealed);
    assert_eq!(h.version, "1.18.1");
}

#[tokio::test]
async fn approle_role_exists_returns_true_when_exists() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/auth/approle/role/git-mirror/role-id"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": { "role_id": "rid-abc" }
        })))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    let exists = client
        .approle_role_exists("git-mirror")
        .await
        .expect("exists check should succeed");
    assert!(exists);
}

#[tokio::test]
async fn approle_role_exists_returns_false_when_not_found() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/v1/auth/approle/role/git-mirror/role-id"))
        .respond_with(ResponseTemplate::new(404).set_body_string("{\"errors\":[]}"))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    let exists = client
        .approle_role_exists("git-mirror")
        .await
        .expect("exists check should succeed");
    assert!(!exists);
}

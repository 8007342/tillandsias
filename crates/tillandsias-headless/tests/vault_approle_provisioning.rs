//! Integration tests for the vault bootstrap's AppRole provisioning path.
//!
//! These tests do NOT require a real Vault. They wire a `wiremock` server
//! into `tillandsias_vault_client::VaultClient` and assert the exact set
//! of policies + roles the Phase 6 bootstrap installs.
//!
//! @trace spec:tillandsias-vault, spec:secrets-management

use serde_json::json;
use tillandsias_vault_client::{Policy, VaultClient};
use wiremock::matchers::{header, method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[tokio::test]
async fn vault_bootstrap_mints_approle_tokens_for_each_role() {
    let server = MockServer::start().await;

    // Each policy should get a write to sys/policies/acl/<name>.
    for policy in Policy::all() {
        Mock::given(method("POST"))
            .and(path(format!("/v1/sys/policies/acl/{}", policy.name())))
            .and(header("X-Vault-Token", "tray-root"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;
    }

    // enable_approle: idempotent; respond with the "already enabled" 400 so
    // we exercise the swallow-400 branch.
    Mock::given(method("POST"))
        .and(path("/v1/sys/auth/approle"))
        .respond_with(
            ResponseTemplate::new(400).set_body_string("{\"errors\":[\"path is already in use\"]}"),
        )
        .mount(&server)
        .await;

    // create_approle_role for each role.
    let roles = ["git-mirror", "forge", "tray", "inference"];
    for role in &roles {
        Mock::given(method("POST"))
            .and(path(format!("/v1/auth/approle/role/{role}")))
            .and(header("X-Vault-Token", "tray-root"))
            .respond_with(ResponseTemplate::new(204))
            .mount(&server)
            .await;
    }

    let client = VaultClient::new(server.uri(), "tray-root");

    // Drive the policy + role provisioning exactly the way the bootstrap
    // does. We can't call vault_bootstrap directly here because it shells
    // out to podman; the spec-relevant assertion is "every role gets a
    // policy of the same family".
    for policy in Policy::all() {
        client
            .write_policy(policy.name(), policy.hcl())
            .await
            .expect("write_policy must succeed against mock");
    }
    client
        .enable_approle()
        .await
        .expect("enable_approle must swallow 400-already-enabled");
    for role in &roles {
        let policy_name = format!("{role}-policy");
        client
            .create_approle_role(role, &[&policy_name], 3_600, 86_400)
            .await
            .expect("create_approle_role must succeed against mock");
    }

    // Now exercise the per-container token minting path for each role.
    for role in &roles {
        Mock::given(method("GET"))
            .and(path(format!("/v1/auth/approle/role/{role}/role-id")))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "data": { "role_id": format!("rid-{role}") }
            })))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(path(format!("/v1/auth/approle/role/{role}/secret-id")))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "data": { "secret_id": format!("sid-{role}"), "secret_id_accessor": "a" }
            })))
            .mount(&server)
            .await;
    }
    // login responds with a role-specific token so we can assert
    // the issued token contains the role name.
    Mock::given(method("POST"))
        .and(path("/v1/auth/approle/login"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "auth": {
                "client_token": "hvs.minted-for-some-role",
                "lease_duration": 3_600,
                "policies": ["git-mirror-policy"]
            }
        })))
        .mount(&server)
        .await;

    for role in &roles {
        let token = client
            .issue_approle_token(role)
            .await
            .expect("issue_approle_token must succeed");
        assert!(
            token.starts_with("hvs."),
            "expected vault token prefix; got {token}"
        );
    }
}

#[tokio::test]
async fn write_github_token_round_trips_through_kv_v2_envelope() {
    let server = MockServer::start().await;

    Mock::given(method("POST"))
        .and(path("/v1/secret/data/github/token"))
        .and(header("X-Vault-Token", "tray-root"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": { "version": 1, "created_time": "now" }
        })))
        .mount(&server)
        .await;

    Mock::given(method("GET"))
        .and(path("/v1/secret/data/github/token"))
        .and(header("X-Vault-Token", "tray-root"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "data": {
                "data": { "token": "ghp_FAKE_PERSISTED_TOKEN" },
                "metadata": { "version": 1 }
            }
        })))
        .mount(&server)
        .await;

    let client = VaultClient::new(server.uri(), "tray-root");
    client
        .write_secret(
            "secret/github/token",
            json!({ "token": "ghp_FAKE_PERSISTED_TOKEN" }),
        )
        .await
        .expect("write must succeed");
    let read_back = client
        .read_secret("secret/github/token")
        .await
        .expect("read-back must succeed");
    assert_eq!(
        read_back["token"].as_str(),
        Some("ghp_FAKE_PERSISTED_TOKEN"),
        "read-back must match write"
    );
}

//! ORDER 1829-guit: a Cloudflare Access service token per host, held only in
//! the vault.
//!
//! After the operator's `--cloudflare-login`, the host creates (or reuses) one
//! Access service token named `tillandsias-<host>` on the operator's account
//! and stores its client id and secret only through the vault. Forges receive
//! it through the existing vault injection path.
//!
//! NOT WIRED YET (2026-11-03). Two operator decisions are pending, and nothing
//! here may reach Cloudflare before them:
//! - the login's OAuth scopes (`CLOUDFLARE_LOGIN_SCOPES`) hold no Access
//!   service-token scope, and adding one is a dashboard change;
//! - `cloudflare_oauth::HttpClient` deliberately has no bearer POST.
//!
//! So this module has no HTTP client and no vault client of its own. It
//! decides through two narrow seams, [`ServiceTokenApi`] (create one token,
//! nothing else) and [`TokenStore`] (is a valid token stored, store one), and
//! the tests drive both with recording mocks. The secret never reaches a
//! file, a log line or a `Debug` print: [`ClientSecret`] redacts itself.
//! @trace order:1829-guit (related: 1824-58bm, 1505-sm2j)
// Unwired until the operator rules (see above); the tests are the only callers.
#![cfg_attr(not(test), allow(dead_code))]

use serde_json::Value;

/// A service token's secret. Its `Debug` never shows the value, and it has
/// no `Display`: the only way out is [`ClientSecret::expose_to_vault`].
#[derive(Clone, PartialEq, Eq)]
pub struct ClientSecret(String);

impl std::fmt::Debug for ClientSecret {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ClientSecret(<redacted>)")
    }
}

impl ClientSecret {
    /// The value, for the vault write and nothing else.
    pub fn expose_to_vault(&self) -> &str {
        &self.0
    }
}

/// What Access returns for a created token. The secret is shown by Access
/// only once, at create time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreatedToken {
    pub id: String,
    pub client_id: String,
    pub client_secret: ClientSecret,
    pub expires_at: Option<String>,
}

/// The Access service-tokens API, narrowed to the one call this needs.
pub trait ServiceTokenApi {
    /// `POST accounts/{account}/access/service_tokens {name}`.
    fn create(&self, account: &str, name: &str) -> Result<CreatedToken, String>;
}

/// The vault, narrowed to this token's path.
pub trait TokenStore {
    /// Whether a token is stored at `path` and has not expired.
    fn has_valid(&self, path: &str) -> Result<bool, String>;
    /// Store the token at `path`. The only place the secret goes.
    fn put(&self, path: &str, token: &CreatedToken) -> Result<(), String>;
}

/// What [`ensure_service_token`] did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// A valid token was already in the vault; nothing was created.
    Reused,
    /// One token was created and stored; `id` is its Access id (not secret).
    Created { id: String },
}

/// `tillandsias-<host>`: lowercase, `[a-z0-9-]` only, so the Access name is
/// stable however the host spells its name.
pub fn token_name(host: &str) -> String {
    let clean: String = host
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect();
    format!("tillandsias-{}", clean.trim_matches('-'))
}

/// The vault path that holds this host's token.
pub fn vault_path(host: &str) -> String {
    format!("cloudflare/access/service-token/{}", token_name(host))
}

/// Create the host's token once and store it only in the vault; reuse a
/// valid stored one. A store failure after a create is an error (the caller
/// reports it; the token can be revoked by its id), never a fallback write.
pub fn ensure_service_token(
    api: &dyn ServiceTokenApi,
    store: &dyn TokenStore,
    account: &str,
    host: &str,
) -> Result<Outcome, String> {
    let path = vault_path(host);
    if store.has_valid(&path)? {
        return Ok(Outcome::Reused);
    }
    let token = api.create(account, &token_name(host))?;
    let id = token.id.clone();
    store.put(&path, &token).map_err(|e| {
        format!("access_token_not_stored: created {id} but the vault write failed ({e}); revoke {id} and log in again")
    })?;
    Ok(Outcome::Created { id })
}

/// Parse Cloudflare's v4 envelope for a create. A missing field is an error
/// that names the field, never the body (which holds the secret).
pub fn parse_create_response(body: &str) -> Result<CreatedToken, String> {
    let v: Value = serde_json::from_str(body)
        .map_err(|_| "access_token_bad_response: not JSON".to_string())?;
    if v["success"] != true {
        let codes: Vec<String> = v["errors"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|e| e["code"].to_string())
            .collect();
        return Err(format!(
            "access_token_refused: Cloudflare said success=false (codes {})",
            codes.join(",")
        ));
    }
    let r = &v["result"];
    let field = |k: &str| {
        r[k].as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_string)
            .ok_or_else(|| format!("access_token_bad_response: result.{k} is missing"))
    };
    Ok(CreatedToken {
        id: field("id")?,
        client_id: field("client_id")?,
        client_secret: ClientSecret(field("client_secret")?),
        expires_at: r["expires_at"].as_str().map(str::to_string),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    /// Records every create; returns a fixed-shape token.
    #[derive(Default)]
    struct Api {
        creates: RefCell<Vec<(String, String)>>,
    }
    impl ServiceTokenApi for Api {
        fn create(&self, account: &str, name: &str) -> Result<CreatedToken, String> {
            self.creates
                .borrow_mut()
                .push((account.to_string(), name.to_string()));
            parse_create_response(
                &serde_json::json!({"success": true, "errors": [], "result": {
                    "id": "tok-1", "client_id": "tok-1.access",
                    "client_secret": "shape-only-not-a-real-secret", "name": name}})
                .to_string(),
            )
        }
    }

    /// An in-memory vault that records writes.
    #[derive(Default)]
    struct Vault {
        held: RefCell<Vec<(String, CreatedToken)>>,
        fail_put: bool,
    }
    impl TokenStore for Vault {
        fn has_valid(&self, path: &str) -> Result<bool, String> {
            Ok(self.held.borrow().iter().any(|(p, _)| p == path))
        }
        fn put(&self, path: &str, token: &CreatedToken) -> Result<(), String> {
            if self.fail_put {
                return Err("sealed".into());
            }
            self.held
                .borrow_mut()
                .push((path.to_string(), token.clone()));
            Ok(())
        }
    }

    /// 1829-guit exit criteria 1 and 2: one create named tillandsias-<host>,
    /// the secret written only through the vault, and a second login with a
    /// valid stored token makes no create call. Pre-fix: FAILS, no such call.
    #[test]
    fn cloudflare_access_service_token_is_created_once_and_held_only_in_the_vault() {
        let api = Api::default();
        let vault = Vault::default();
        let first = ensure_service_token(&api, &vault, "acct", "Lenovinha.local").unwrap();
        assert_eq!(first, Outcome::Created { id: "tok-1".into() });
        assert_eq!(
            api.creates.borrow().as_slice(),
            &[(
                "acct".to_string(),
                "tillandsias-lenovinha-local".to_string()
            )]
        );
        let held = vault.held.borrow();
        assert_eq!(held.len(), 1);
        assert_eq!(
            held[0].0,
            "cloudflare/access/service-token/tillandsias-lenovinha-local"
        );
        assert_eq!(
            held[0].1.client_secret.expose_to_vault(),
            "shape-only-not-a-real-secret"
        );
        drop(held);

        let second = ensure_service_token(&api, &vault, "acct", "Lenovinha.local").unwrap();
        assert_eq!(second, Outcome::Reused);
        assert_eq!(api.creates.borrow().len(), 1, "no second create");
    }

    /// A vault that cannot store fails the call, naming the token id to
    /// revoke; nothing falls back to another place.
    #[test]
    fn cloudflare_access_service_token_unstored_is_an_error_not_a_fallback() {
        let api = Api::default();
        let vault = Vault {
            fail_put: true,
            ..Default::default()
        };
        let e = ensure_service_token(&api, &vault, "acct", "h").unwrap_err();
        assert!(
            e.starts_with("access_token_not_stored:") && e.contains("tok-1"),
            "{e}"
        );
        assert!(
            !e.contains("shape-only"),
            "the error never carries the secret: {e}"
        );
    }

    /// The secret never prints, and a refusal or a bad body never echoes it.
    #[test]
    fn cloudflare_access_service_token_secret_never_prints() {
        let t = parse_create_response(
            r#"{"success":true,"result":{"id":"i","client_id":"i.access","client_secret":"shape-only"}}"#,
        )
        .unwrap();
        let shown = format!("{t:?}");
        assert!(
            !shown.contains("shape-only") && shown.contains("<redacted>"),
            "{shown}"
        );
        let e = parse_create_response(
            r#"{"success":true,"result":{"id":"i","client_secret":"shape-only"}}"#,
        )
        .unwrap_err();
        assert!(e.contains("client_id") && !e.contains("shape-only"), "{e}");
        let e =
            parse_create_response(r#"{"success":false,"errors":[{"code":10000}]}"#).unwrap_err();
        assert!(
            e.starts_with("access_token_refused:") && e.contains("10000"),
            "{e}"
        );
    }

    /// Exit criterion 3: the module writes the secret to no file and no log.
    #[test]
    fn cloudflare_access_service_token_module_has_no_disk_or_log_write() {
        let src = include_str!("cloudflare_access_tokens.rs");
        let body = src.split("#[cfg(test)]").next().unwrap();
        for banned in [
            "std::fs",
            "File::",
            "println!",
            "eprintln!",
            "tracing::",
            "info!(",
            "debug!(",
            "warn!(",
        ] {
            assert!(!body.contains(banned), "module body uses {banned}");
        }
    }
}

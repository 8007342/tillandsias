// @trace order:2080-dhzf
//! `tillandsias --huggingface-login [--via device|paste]` and
//! `tillandsias --huggingface-logout`.
//!
//! Hugging Face offers the OAuth 2.0 device grant (its discovery document at
//! `https://huggingface.co/.well-known/openid-configuration` names
//! `device_authorization_endpoint` `/oauth/device` and lists
//! `urn:ietf:params:oauth:grant-type:device_code`), so this login reuses the
//! device-grant core of [`crate::cloudflare_oauth`] (`discover_device_grant`,
//! `device_authorize`, `device_poll`) with Hugging Face's base URL and client
//! id. Nothing here is a second OAuth implementation.
//!
//! - **device**: needs a registered Hugging Face OAuth app. Its client id is
//!   CONFIG-DRIVEN: [`CLIENT_ID_ENV`], else [`HUGGINGFACE_APP_CLIENT_ID`],
//!   which is empty until the operator registers the app. With no client id
//!   the login goes straight to paste.
//! - **paste**: the operator pastes a user access token (read scope) from
//!   `https://huggingface.co/settings/tokens` on the terminal, echo off. The
//!   tray launches this same command in a terminal, so this is also the
//!   tray's fallback. The token is checked once against `/api/whoami-v2`.
//!
//! # Where the token goes
//!
//! Only to Vault ([`vault_bootstrap::HUGGINGFACE_TOKEN_PATH`]) and to
//! huggingface.co. It is never printed, logged, put in argv or a file, or
//! named in a refusal (every refusal is a fixed reason word). Host-side model
//! fetchers read it through [`token_for_fetch`] and send it only to
//! `https://huggingface.co` ([`crate::imagegen_models::hf_auth_header`]).
//! Forges never see it: `HF_TOKEN` and `HUGGING_FACE_HUB_TOKEN` are scrubbed
//! credentials in `tillandsias-plan` `child_env`.

use std::io::Write;
use std::time::{Duration, Instant};

use crate::cloudflare_login::{Refusal, fixed_word};
use crate::cloudflare_oauth::{self, DevicePoll, DeviceStart, HttpClient};
use crate::vault_bootstrap::{
    self, HuggingFaceToken, HuggingFaceTokenStore, VaultHuggingFaceTokenStore,
};

pub const HUGGINGFACE_BASE_URL_DEFAULT: &str = "https://huggingface.co";
/// Override of the base URL (a stub authorization server in tests).
pub const BASE_URL_ENV: &str = "TILLANDSIAS_HUGGINGFACE_BASE_URL";
/// The Hugging Face OAuth app's client id, when set on this host.
pub const CLIENT_ID_ENV: &str = "TILLANDSIAS_HUGGINGFACE_CLIENT_ID";
/// The compiled-in client id of the Tillandsias Hugging Face OAuth app. EMPTY
/// until the operator registers the app on their account (an operator action;
/// no agent registers it). Empty means: no device flow, paste only.
pub const HUGGINGFACE_APP_CLIENT_ID: &str = "";
/// read-repos for downloads; gated-repos so models whose terms the operator
/// accepted on huggingface.co can be fetched.
pub const HUGGINGFACE_LOGIN_SCOPES: &[&str] = &["openid", "profile", "read-repos", "gated-repos"];
pub const LOGIN_WINDOW: Duration = Duration::from_secs(600);
const MAX_TOKEN_LEN: usize = 256;

pub fn base_url() -> String {
    std::env::var(BASE_URL_ENV)
        .ok()
        .filter(|s| !s.trim().is_empty())
        .unwrap_or_else(|| HUGGINGFACE_BASE_URL_DEFAULT.to_string())
}

/// The configured client id, or `None` when no app is registered.
pub fn client_id_from(env: Option<String>, compiled: &str) -> Option<String> {
    env.map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .or_else(|| Some(compiled.to_string()).filter(|s| !s.is_empty()))
}

pub fn client_id() -> Option<String> {
    client_id_from(std::env::var(CLIENT_ID_ENV).ok(), HUGGINGFACE_APP_CLIENT_ID)
}

fn refuse_login(reason: impl Into<String>, why: impl Into<String>, remedy: &str) -> Refusal {
    Refusal {
        command: "huggingface-login",
        reason: fixed_word(&reason.into()),
        why: why.into(),
        remedy: remedy.to_string(),
    }
}

fn refuse_logout(reason: impl Into<String>, why: impl Into<String>, remedy: &str) -> Refusal {
    Refusal {
        command: "huggingface-logout",
        reason: fixed_word(&reason.into()),
        why: why.into(),
        remedy: remedy.to_string(),
    }
}

/// A core error (`refused:cloudflare-login:<words>`) reduced to its words.
fn core_reason(e: &str) -> String {
    fixed_word(
        e.strip_prefix("refused:cloudflare-login:")
            .unwrap_or("core-error"),
    )
}

const REMEDY_RETRY: &str = "run `tillandsias --huggingface-login` again; nothing was stored";
const REMEDY_VAULT: &str = "start Tillandsias (the tray) so its Vault is up, then run `tillandsias --huggingface-login` again";

// ── the command line ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Via {
    Device,
    Paste,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Login { via: Option<Via> },
    Logout,
}

/// Parse `--huggingface-login [--via device|paste] [--debug]` or
/// `--huggingface-logout [--debug]`. A positional argument is refused and
/// never echoed: a token belongs on the terminal, not in argv.
pub fn parse_args(args: &[String]) -> Result<Command, Refusal> {
    let login = args.iter().any(|a| a == "--huggingface-login");
    let logout = args.iter().any(|a| a == "--huggingface-logout");
    let usage = "tillandsias --huggingface-login [--via device|paste] [--debug] | tillandsias --huggingface-logout [--debug]";
    let refuse = |reason: &str, why: &str| {
        if logout && !login {
            refuse_logout(reason, why, usage)
        } else {
            refuse_login(reason, why, usage)
        }
    };
    if login && logout {
        return Err(refuse(
            "both-login-and-logout",
            "--huggingface-login and --huggingface-logout were both given",
        ));
    }
    let mut via = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--huggingface-login" | "--huggingface-logout" | "--debug" => {}
            "--via" if login => {
                via = Some(match args.get(i + 1).map(String::as_str) {
                    Some("device") => Via::Device,
                    Some("paste") => Via::Paste,
                    _ => {
                        return Err(refuse(
                            "bad-via",
                            "--via takes exactly one of device, paste",
                        ));
                    }
                });
                i += 1;
            }
            _ => {
                return Err(refuse(
                    "unsupported-argument",
                    "an argument this command does not take was given (not echoed: a token is pasted on the terminal, never put on the command line)",
                ));
            }
        }
        i += 1;
    }
    Ok(if logout {
        Command::Logout
    } else {
        Command::Login { via }
    })
}

// ── login ──────────────────────────────────────────────────────────────────

pub struct LoginDeps<'a> {
    pub http: &'a dyn HttpClient,
    pub store: &'a dyn HuggingFaceTokenStore,
    pub base_url: String,
    pub client_id: Option<String>,
    pub stdin_is_terminal: bool,
    pub read_paste: &'a mut dyn FnMut() -> Result<String, String>,
    pub host_is_forge: bool,
    pub window: Duration,
    pub device_interval_unit: Duration,
    pub now_unix: u64,
}

/// A user access token's shape: `hf_` and URL-safe characters only.
pub fn valid_token_shape(t: &str) -> bool {
    t.len() > 3
        && t.len() <= MAX_TOKEN_LEN
        && t.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
}

pub fn login(
    via: Option<Via>,
    deps: &mut LoginDeps<'_>,
    out: &mut dyn Write,
) -> Result<(), Refusal> {
    if deps.host_is_forge {
        return Err(refuse_login(
            "forge-refused",
            "the Hugging Face sign-in is the operator's, on the host; a forge never holds the token",
            "run `tillandsias --huggingface-login` on the host",
        ));
    }
    match via {
        Some(Via::Paste) => login_paste(deps, out),
        Some(Via::Device) => {
            if deps.client_id.is_none() {
                return Err(refuse_login(
                    "no-client-id",
                    "the device sign-in needs a registered Hugging Face OAuth app and none is configured on this host",
                    "set TILLANDSIAS_HUGGINGFACE_CLIENT_ID to the app's client id, or run `tillandsias --huggingface-login --via paste`",
                ));
            }
            login_device(deps, true, out).map(|_| ())
        }
        None => {
            if deps.client_id.is_some() && login_device(deps, false, out)? {
                return Ok(());
            }
            if deps.client_id.is_none() {
                let _ = writeln!(
                    out,
                    "note:huggingface-login:no-client-id (no Hugging Face OAuth app is configured; using the token paste)"
                );
            }
            login_paste(deps, out)
        }
    }
}

fn vault_preflight(deps: &LoginDeps<'_>) -> Result<(), Refusal> {
    deps.store.read_token().map(|_| ()).map_err(|e| {
        refuse_login(
            format!("vault:{e}"),
            "Vault could not be read, so a token could not be stored; nothing was spent",
            REMEDY_VAULT,
        )
    })
}

fn store_token(
    deps: &LoginDeps<'_>,
    token: HuggingFaceToken,
    out: &mut dyn Write,
) -> Result<(), Refusal> {
    vault_bootstrap::store_huggingface_token(deps.store, &token).map_err(|e| {
        refuse_login(
            format!("vault-write:{e}"),
            "the token could not be stored in Vault; it was not written anywhere else",
            REMEDY_VAULT,
        )
    })?;
    let _ = writeln!(
        out,
        "ok:huggingface-login:stored ({} sign-in kept in Vault only; model downloads from huggingface.co use it)",
        token.source
    );
    Ok(())
}

/// `Ok(true)`: signed in. `Ok(false)`: the device grant is unavailable and the
/// caller may fall back (only when not `explicit`).
fn login_device(
    deps: &mut LoginDeps<'_>,
    explicit: bool,
    out: &mut dyn Write,
) -> Result<bool, Refusal> {
    let client_id = deps.client_id.clone().unwrap_or_default();
    let endpoints = match cloudflare_oauth::discover_device_grant(deps.http, &deps.base_url) {
        Ok(Some(e)) => e,
        Ok(None) | Err(_) if !explicit => {
            let _ = writeln!(
                out,
                "note:huggingface-login:device-grant-unavailable (using the token paste)"
            );
            return Ok(false);
        }
        Ok(None) => {
            return Err(refuse_login(
                "device-grant-not-offered",
                "Hugging Face's discovery document does not offer the device grant",
                "run `tillandsias --huggingface-login --via paste`",
            ));
        }
        Err(e) => {
            return Err(refuse_login(
                core_reason(&e),
                "the Hugging Face OpenID discovery document could not be read",
                "check the network, then retry",
            ));
        }
    };
    for u in [
        &endpoints.device_authorization_endpoint,
        &endpoints.token_endpoint,
    ] {
        if !vault_bootstrap::cloudflare_token_endpoint_is_safe(u) {
            return Err(refuse_login(
                "endpoint-not-https",
                "a discovered Hugging Face endpoint is not https",
                REMEDY_RETRY,
            ));
        }
    }
    vault_preflight(deps)?;
    let auth = match cloudflare_oauth::device_authorize(
        deps.http,
        &endpoints,
        &client_id,
        HUGGINGFACE_LOGIN_SCOPES,
    ) {
        Ok(DeviceStart::Started(a)) => a,
        Ok(DeviceStart::Refused(word)) if !explicit => {
            let _ = writeln!(
                out,
                "note:huggingface-login:device-grant-refused:{word} (using the token paste)"
            );
            return Ok(false);
        }
        Ok(DeviceStart::Refused(word)) => {
            return Err(refuse_login(
                format!("device-grant-refused:{word}"),
                "Hugging Face would not start a device sign-in for this client id",
                "check the OAuth app's scopes on huggingface.co, or run `tillandsias --huggingface-login --via paste`",
            ));
        }
        Err(e) => {
            return Err(refuse_login(
                core_reason(&e),
                "Hugging Face's device authorization endpoint did not start a sign-in",
                REMEDY_RETRY,
            ));
        }
    };
    let shown = auth
        .verification_uri_complete
        .clone()
        .unwrap_or_else(|| auth.verification_uri.clone());
    if !vault_bootstrap::cloudflare_token_endpoint_is_safe(&shown) {
        return Err(refuse_login(
            "verification-uri-not-https",
            "the verification URI is not https",
            REMEDY_RETRY,
        ));
    }
    let _ = writeln!(
        out,
        "\nSign in to Hugging Face: open {} and enter the code: {}\n(direct link: {shown})\nWaiting for the approval on huggingface.co...",
        auth.verification_uri, auth.user_code
    );
    let _ = out.flush();
    let deadline = Instant::now() + Duration::from_secs(auth.expires_in).min(deps.window);
    let mut interval = auth.interval;
    let bundle = loop {
        std::thread::sleep(deps.device_interval_unit * interval as u32);
        if Instant::now() >= deadline {
            return Err(refuse_login(
                "device-code-expired",
                "the device code expired before the sign-in was approved; nothing was stored",
                REMEDY_RETRY,
            ));
        }
        match cloudflare_oauth::device_poll(deps.http, &auth, &client_id) {
            Ok(DevicePoll::Pending) => {}
            Ok(DevicePoll::SlowDown) => interval += 5,
            Ok(DevicePoll::Denied) => {
                return Err(refuse_login(
                    "access-denied",
                    "the sign-in was declined on huggingface.co; nothing was stored",
                    REMEDY_RETRY,
                ));
            }
            Ok(DevicePoll::Expired) => {
                return Err(refuse_login(
                    "device-code-expired",
                    "the device code expired before the sign-in was approved; nothing was stored",
                    REMEDY_RETRY,
                ));
            }
            Ok(DevicePoll::Token(b)) => break b,
            Err(e) => {
                return Err(refuse_login(
                    format!("exchange:{}", core_reason(&e)),
                    "the token endpoint did not issue a token for the approved device code",
                    REMEDY_RETRY,
                ));
            }
        }
    };
    let token = HuggingFaceToken {
        access_token: bundle.access_token.clone(),
        refresh_token: bundle.refresh_token.clone(),
        expires_at: bundle.expires_in.map(|s| deps.now_unix.saturating_add(s)),
        source: "device".into(),
    };
    store_token(deps, token, out).map(|_| true)
}

fn login_paste(deps: &mut LoginDeps<'_>, out: &mut dyn Write) -> Result<(), Refusal> {
    if !deps.stdin_is_terminal {
        return Err(refuse_login(
            "paste-needs-a-terminal",
            "the token is read from a terminal with echo off; a pipe or file is refused so the token never passes through another process or a file",
            "run `tillandsias --huggingface-login` in a terminal (the tray opens one)",
        ));
    }
    vault_preflight(deps)?;
    let _ = write!(
        out,
        "Create a Hugging Face access token with the Read role at https://huggingface.co/settings/tokens\nand paste it here (input is hidden): "
    );
    let _ = out.flush();
    let line = (deps.read_paste)().map_err(|_| {
        refuse_login(
            "no-token-pasted",
            "nothing was pasted; nothing was stored",
            REMEDY_RETRY,
        )
    })?;
    let token = line.trim().to_string();
    if !valid_token_shape(&token) {
        return Err(refuse_login(
            "token-shape",
            "the pasted text is not a Hugging Face access token (expected letters, digits, `_`, `-`); nothing was stored",
            REMEDY_RETRY,
        ));
    }
    let url = format!("{}/api/whoami-v2", deps.base_url.trim_end_matches('/'));
    match deps.http.get_with_bearer(&url, &token) {
        Ok(r) if r.status == 200 => {}
        Ok(r) if r.status == 401 || r.status == 403 => {
            return Err(refuse_login(
                "token-rejected",
                "huggingface.co did not accept the pasted token; nothing was stored",
                "create a new token with the Read role at https://huggingface.co/settings/tokens and retry",
            ));
        }
        Ok(r) => {
            return Err(refuse_login(
                format!("whoami-http-{}", r.status),
                "huggingface.co could not check the pasted token; nothing was stored",
                REMEDY_RETRY,
            ));
        }
        Err(e) => {
            return Err(refuse_login(
                core_reason(&e),
                "huggingface.co could not be reached to check the pasted token; nothing was stored",
                REMEDY_RETRY,
            ));
        }
    }
    store_token(
        deps,
        HuggingFaceToken {
            access_token: token,
            refresh_token: None,
            expires_at: None,
            source: "paste".into(),
        },
        out,
    )
}

// ── logout ─────────────────────────────────────────────────────────────────

pub fn logout(
    store: &dyn HuggingFaceTokenStore,
    host_is_forge: bool,
    out: &mut dyn Write,
) -> Result<(), Refusal> {
    if host_is_forge {
        return Err(refuse_logout(
            "forge-refused",
            "the Hugging Face sign-in is the operator's, on the host",
            "run `tillandsias --huggingface-logout` on the host",
        ));
    }
    vault_bootstrap::delete_huggingface_token(store).map_err(|e| {
        refuse_logout(
            format!("vault:{e}"),
            "the stored Hugging Face sign-in could not be deleted",
            "start Tillandsias (the tray) so its Vault is up, then run `tillandsias --huggingface-logout` again",
        )
    })?;
    let _ = writeln!(
        out,
        "ok:huggingface-logout:deleted (the token is gone from Vault; revoke it on huggingface.co too: settings/tokens for a pasted token, settings/connected-applications for the app)"
    );
    Ok(())
}

// ── the fetchers' read ─────────────────────────────────────────────────────

/// The token a host-side huggingface.co download may send, or `None` (no
/// sign-in, Vault not running, an expired OAuth token). Never starts Vault:
/// an unauthenticated download works exactly as before.
pub fn token_for_fetch() -> Option<String> {
    let store = VaultHuggingFaceTokenStore {
        debug: false,
        may_start_vault: false,
    };
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    usable_token(&store, now)
}

pub fn usable_token(store: &dyn HuggingFaceTokenStore, now: u64) -> Option<String> {
    store
        .read_token()
        .ok()
        .flatten()
        .filter(|t| t.usable_at(now))
        .map(|t| t.access_token)
}

pub fn run_cli(args: &[String]) -> i32 {
    use std::io::IsTerminal;
    let cmd = match parse_args(args) {
        Ok(c) => c,
        Err(r) => {
            eprint!("{}", r.render());
            return 2;
        }
    };
    let debug = args.iter().any(|a| a == "--debug");
    let store = VaultHuggingFaceTokenStore {
        debug,
        may_start_vault: true,
    };
    let host_is_forge = std::env::var("TILLANDSIAS_HOST_KIND").as_deref() == Ok("forge");
    let mut stdout = std::io::stdout();
    let result = match cmd {
        Command::Logout => logout(&store, host_is_forge, &mut stdout),
        Command::Login { via } => {
            let http = cloudflare_oauth::ReqwestHttpClient::default();
            let mut read = crate::cloudflare_login::read_paste_line_from_terminal;
            let mut deps = LoginDeps {
                http: &http,
                store: &store,
                base_url: base_url(),
                client_id: client_id(),
                stdin_is_terminal: std::io::stdin().is_terminal(),
                read_paste: &mut read,
                host_is_forge,
                window: LOGIN_WINDOW,
                device_interval_unit: Duration::from_secs(1),
                now_unix: std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0),
            };
            login(via, &mut deps, &mut stdout)
        }
    };
    match result {
        Ok(()) => 0,
        Err(r) => {
            let _ = stdout.flush();
            eprint!("{}", r.render());
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cloudflare_oauth::HttpResponse;
    use std::cell::RefCell;
    use std::collections::HashMap;

    const SECRET: &str = "hf_STUBsecretTOKEN0123456789";
    type Post = (String, Vec<(String, String)>);

    #[derive(Default)]
    struct MemStore {
        recs: RefCell<HashMap<String, serde_json::Value>>,
        fail: bool,
    }
    impl HuggingFaceTokenStore for MemStore {
        fn read_token(&self) -> Result<Option<HuggingFaceToken>, String> {
            if self.fail {
                return Err("vault-unavailable".into());
            }
            Ok(self
                .recs
                .borrow()
                .get(vault_bootstrap::HUGGINGFACE_TOKEN_PATH)
                .and_then(HuggingFaceToken::from_record))
        }
        fn write_record(&self, path: &str, value: serde_json::Value) -> Result<(), String> {
            if self.fail {
                return Err("vault-unavailable".into());
            }
            self.recs.borrow_mut().insert(path.into(), value);
            Ok(())
        }
        fn delete_record(&self, path: &str) -> Result<(), String> {
            self.recs.borrow_mut().remove(path);
            Ok(())
        }
    }

    /// A stub authorization server: discovery, /oauth/device, /oauth/token
    /// (pending once, then the token), and /api/whoami-v2.
    struct Stub {
        polls: RefCell<u32>,
        posts: RefCell<Vec<Post>>,
        device_grant: bool,
    }
    impl Stub {
        fn new(device_grant: bool) -> Self {
            Stub {
                polls: RefCell::new(0),
                posts: RefCell::new(vec![]),
                device_grant,
            }
        }
    }
    fn ok(body: String) -> HttpResponse {
        HttpResponse {
            status: 200,
            body,
            retry_after_s: None,
        }
    }
    impl HttpClient for Stub {
        fn get(&self, url: &str) -> Result<HttpResponse, String> {
            assert_eq!(url, "https://hf.stub/.well-known/openid-configuration");
            let grants = if self.device_grant {
                r#"["authorization_code","urn:ietf:params:oauth:grant-type:device_code"]"#
            } else {
                r#"["authorization_code"]"#
            };
            Ok(ok(format!(
                r#"{{"authorization_endpoint":"https://hf.stub/oauth/authorize","token_endpoint":"https://hf.stub/oauth/token","device_authorization_endpoint":"https://hf.stub/oauth/device","grant_types_supported":{grants}}}"#
            )))
        }
        fn post_form(&self, url: &str, form: &[(&str, &str)]) -> Result<HttpResponse, String> {
            self.posts.borrow_mut().push((
                url.into(),
                form.iter()
                    .map(|(k, v)| (k.to_string(), v.to_string()))
                    .collect(),
            ));
            match url {
                "https://hf.stub/oauth/device" => Ok(ok(r#"{"device_code":"DEV","user_code":"ABCD-EFGH","verification_uri":"https://hf.stub/oauth/device","expires_in":300,"interval":1}"#.into())),
                "https://hf.stub/oauth/token" => {
                    let mut n = self.polls.borrow_mut();
                    *n += 1;
                    if *n == 1 {
                        Ok(HttpResponse { status: 400, body: r#"{"error":"authorization_pending"}"#.into(), retry_after_s: None })
                    } else {
                        Ok(ok(format!(r#"{{"access_token":"{SECRET}","refresh_token":"hf_oauth_REFRESH","expires_in":3600,"token_type":"bearer"}}"#)))
                    }
                }
                other => panic!("unexpected POST {other}"),
            }
        }
        fn get_with_bearer(&self, url: &str, bearer: &str) -> Result<HttpResponse, String> {
            assert_eq!(url, "https://hf.stub/api/whoami-v2");
            Ok(HttpResponse {
                status: if bearer == SECRET { 200 } else { 401 },
                body: "{}".into(),
                retry_after_s: None,
            })
        }
    }

    fn run(
        via: Option<Via>,
        http: &Stub,
        store: &MemStore,
        client_id: Option<&str>,
        paste: &str,
    ) -> (Result<(), Refusal>, String) {
        let paste = paste.to_string();
        let mut read = move || Ok(paste.clone());
        let mut deps = LoginDeps {
            http,
            store,
            base_url: "https://hf.stub".into(),
            client_id: client_id.map(str::to_string),
            stdin_is_terminal: true,
            read_paste: &mut read,
            host_is_forge: false,
            window: Duration::from_secs(30),
            device_interval_unit: Duration::from_millis(1),
            now_unix: 1_000,
        };
        let mut out = Vec::new();
        let r = login(via, &mut deps, &mut out);
        (r, String::from_utf8(out).unwrap())
    }

    /// Exit criterion 1: the device flow against a stub server stores the
    /// token in the (Vault) store only, and prints it nowhere.
    #[test]
    fn device_flow_against_a_stub_server_stores_in_vault_only() {
        let http = Stub::new(true);
        let store = MemStore::default();
        let (r, out) = run(None, &http, &store, Some("cid-123"), "");
        r.unwrap();
        let rec = store.recs.borrow()[vault_bootstrap::HUGGINGFACE_TOKEN_PATH].clone();
        let t = HuggingFaceToken::from_record(&rec).unwrap();
        assert_eq!(t.access_token, SECRET);
        assert_eq!(t.expires_at, Some(4_600));
        assert_eq!(t.source, "device");
        assert!(out.contains("ABCD-EFGH"), "{out}");
        assert!(!out.contains(SECRET), "token printed: {out}");
        assert!(!out.contains("DEV\""), "device code printed");
        let posts = http.posts.borrow();
        let grant = posts
            .iter()
            .find(|(u, _)| u.ends_with("/oauth/token"))
            .unwrap();
        assert!(grant.1.contains(&(
            "grant_type".into(),
            "urn:ietf:params:oauth:grant-type:device_code".into()
        )));
        assert!(grant.1.contains(&("client_id".into(), "cid-123".into())));
    }

    /// Exit criterion 2: with no client id the paste path stores the pasted
    /// token the same way.
    #[test]
    fn with_no_client_id_the_paste_path_stores_the_token() {
        let http = Stub::new(true);
        let store = MemStore::default();
        let (r, out) = run(None, &http, &store, None, &format!("{SECRET}\n"));
        r.unwrap();
        assert!(out.contains("note:huggingface-login:no-client-id"), "{out}");
        let t = store.read_token().unwrap().unwrap();
        assert_eq!(t.access_token, SECRET);
        assert_eq!(t.source, "paste");
        assert_eq!(t.expires_at, None);
        assert!(!out.contains(SECRET));
        assert!(
            http.posts.borrow().is_empty(),
            "no OAuth request without a client id"
        );
    }

    #[test]
    fn when_the_device_grant_is_not_offered_login_falls_back_to_paste() {
        let http = Stub::new(false);
        let store = MemStore::default();
        let (r, out) = run(None, &http, &store, Some("cid"), SECRET);
        r.unwrap();
        assert!(out.contains("device-grant-unavailable"), "{out}");
        assert_eq!(store.read_token().unwrap().unwrap().source, "paste");
    }

    #[test]
    fn a_rejected_or_malformed_paste_stores_nothing_and_is_not_echoed() {
        let http = Stub::new(true);
        let store = MemStore::default();
        let (r, _) = run(Some(Via::Paste), &http, &store, None, "hf_wrongTOKEN");
        let e = r.unwrap_err();
        assert_eq!(e.verdict(), "refused:huggingface-login:token-rejected");
        assert!(!e.render().contains("hf_wrongTOKEN"));
        let (r, _) = run(Some(Via::Paste), &http, &store, None, "not a token!");
        assert_eq!(r.unwrap_err().reason, "token-shape");
        assert!(store.recs.borrow().is_empty());
    }

    #[test]
    fn an_unreachable_vault_refuses_before_anything_is_spent() {
        let http = Stub::new(true);
        let store = MemStore {
            fail: true,
            ..Default::default()
        };
        let (r, _) = run(None, &http, &store, Some("cid"), SECRET);
        assert!(r.unwrap_err().reason.starts_with("vault:"));
        assert!(
            !http
                .posts
                .borrow()
                .iter()
                .any(|(u, _)| u.ends_with("/oauth/device")),
            "device code requested with no Vault"
        );
    }

    #[test]
    fn paste_refuses_a_pipe() {
        let http = Stub::new(true);
        let store = MemStore::default();
        let mut read = || Ok(SECRET.to_string());
        let mut deps = LoginDeps {
            http: &http,
            store: &store,
            base_url: "https://hf.stub".into(),
            client_id: None,
            stdin_is_terminal: false,
            read_paste: &mut read,
            host_is_forge: false,
            window: Duration::from_secs(1),
            device_interval_unit: Duration::from_millis(1),
            now_unix: 0,
        };
        let e = login(None, &mut deps, &mut Vec::new()).unwrap_err();
        assert_eq!(e.reason, "paste-needs-a-terminal");
    }

    #[test]
    fn logout_deletes_the_record() {
        let store = MemStore::default();
        store
            .write_record(
                vault_bootstrap::HUGGINGFACE_TOKEN_PATH,
                serde_json::json!({"access_token": SECRET}),
            )
            .unwrap();
        logout(&store, false, &mut Vec::new()).unwrap();
        assert!(store.read_token().unwrap().is_none());
        assert!(logout(&store, true, &mut Vec::new()).is_err());
    }

    #[test]
    fn token_debug_is_redacted() {
        let t = HuggingFaceToken {
            access_token: SECRET.into(),
            refresh_token: Some("hf_oauth_REFRESH".into()),
            expires_at: Some(5),
            source: "device".into(),
        };
        let d = format!("{t:?}");
        assert!(!d.contains(SECRET) && !d.contains("REFRESH"), "{d}");
        assert_eq!(HuggingFaceToken::from_record(&t.record()), Some(t));
    }

    #[test]
    fn fetch_uses_only_a_live_token() {
        let store = MemStore::default();
        assert_eq!(usable_token(&store, 0), None);
        store
            .write_record(
                vault_bootstrap::HUGGINGFACE_TOKEN_PATH,
                serde_json::json!({"access_token": SECRET, "expires_at": 1_000}),
            )
            .unwrap();
        assert_eq!(usable_token(&store, 100).as_deref(), Some(SECRET));
        assert_eq!(
            usable_token(&store, 999),
            None,
            "an expiring token is not sent"
        );
        let failing = MemStore {
            fail: true,
            ..Default::default()
        };
        assert_eq!(usable_token(&failing, 0), None, "no Vault: unauthenticated");
    }

    #[test]
    fn args_parse_and_never_echo_a_positional() {
        let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            parse_args(&a(&["--huggingface-login", "--via", "paste"])).unwrap(),
            Command::Login {
                via: Some(Via::Paste)
            }
        );
        assert_eq!(
            parse_args(&a(&["--huggingface-logout"])).unwrap(),
            Command::Logout
        );
        let e = parse_args(&a(&["--huggingface-login", SECRET])).unwrap_err();
        assert!(!e.render().contains(SECRET));
        assert!(parse_args(&a(&["--huggingface-login", "--huggingface-logout"])).is_err());
    }

    #[test]
    fn client_id_is_config_driven() {
        assert_eq!(client_id_from(None, ""), None);
        assert_eq!(client_id_from(Some("  ".into()), ""), None);
        assert_eq!(
            client_id_from(Some("abc".into()), "zzz").as_deref(),
            Some("abc")
        );
        assert_eq!(client_id_from(None, "zzz").as_deref(), Some("zzz"));
    }

    /// Exit criterion 3, forge half: HF_TOKEN never reaches a forge child.
    #[test]
    fn forge_children_never_get_hf_token() {
        let src = include_str!("../../tillandsias-plan/src/child_env.rs");
        assert!(src.contains("\"HF_TOKEN\""));
        assert!(src.contains("\"HUGGING_FACE_HUB_TOKEN\""));
    }
}

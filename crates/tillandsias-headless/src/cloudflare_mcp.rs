//! Read-only Cloudflare tools on the lane's MCP socket (order 1772-irs3).
//!
//! @trace order:1772-irs3, spec:mcp-tool-socket
//!
//! A forge agent names a tool; THIS process (the tray, or the VM guest that
//! launched the forge) reads the Vault-stored Cloudflare sign-in, refreshes it
//! when due (the 1719 rotation path), and sends one fixed GET. The token never
//! enters the forge: it is not in a tool's input, its result, a log line or an
//! error.
//!
//! OPERATOR-APPROVED SCOPE (2026-10-17, in tlatoanis-macbook-air's session):
//! GET only, a named allowlist with no generic endpoint tool, a scope probe,
//! redaction, and the account bound to the tray. Anything wider (a write
//! tool, a path or method argument) needs a fresh approval.
//!
//! - Every tool in [`TOOLS`] is one path template. Only the tray-bound account
//!   id and validated ids, page numbers and cursors are interpolated.
//! - [`send`] refuses any method other than GET before the transport is
//!   touched, and the transport it calls can only GET.
//! - The account is the one stored with the sign-in (or, when none was
//!   stored, the only one Cloudflare lists). A forge-supplied `account_id`
//!   that differs is refused.
//! - Errors are fixed reason words plus a why and a remedy. Cloudflare's
//!   error text is never quoted (only its numeric error codes), and every
//!   result and error passes through [`redact`] on its way out.

use crate::cloudflare_oauth::{HttpClient, HttpResponse};
use crate::vault_bootstrap::CloudflareTokenStore;

/// Cloudflare's v4 API. `TILLANDSIAS_CLOUDFLARE_API_BASE_URL` overrides it for
/// the fixtures' fake; the host process's environment is not forge-writable.
pub(crate) const API_BASE_DEFAULT: &str = "https://api.cloudflare.com/client/v4";

pub(crate) fn api_base_url() -> String {
    std::env::var("TILLANDSIAS_CLOUDFLARE_API_BASE_URL")
        .unwrap_or_else(|_| API_BASE_DEFAULT.to_string())
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Method {
    Get,
    // Never in TOOLS: these exist so `send` can be shown to refuse them.
    #[cfg_attr(not(test), allow(dead_code))]
    Post,
    #[cfg_attr(not(test), allow(dead_code))]
    Delete,
}

impl Method {
    fn word(self) -> &'static str {
        match self {
            Method::Get => "GET",
            Method::Post => "POST",
            Method::Delete => "DELETE",
        }
    }
}

/// A validated argument a path template or query can carry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Arg {
    /// A Worker's script name (`{script}`).
    Script,
    /// A Worker's tag, which the Builds API calls `external_script_id`.
    ScriptTag,
    /// A Workers Builds build UUID.
    BuildId,
    /// A Pages project name.
    Project,
    /// A log page cursor (query `cursor`).
    Cursor,
    /// A page number (query `page`).
    Page,
}

impl Arg {
    fn key(self) -> &'static str {
        match self {
            Arg::Script => "script",
            Arg::ScriptTag => "script_tag",
            Arg::BuildId => "build_id",
            Arg::Project => "project",
            Arg::Cursor => "cursor",
            Arg::Page => "page",
        }
    }

    fn schema(self) -> serde_json::Value {
        match self {
            Arg::Script => {
                serde_json::json!({ "type": "string", "description": "The Worker's script name, as cloudflare.workers_scripts_list shows it (its id)." })
            }
            Arg::ScriptTag => {
                serde_json::json!({ "type": "string", "description": "The Worker's tag, as cloudflare.workers_scripts_list shows it." })
            }
            Arg::BuildId => {
                serde_json::json!({ "type": "string", "description": "A build's UUID, as cloudflare.builds_list shows it." })
            }
            Arg::Project => {
                serde_json::json!({ "type": "string", "description": "A Pages project name." })
            }
            Arg::Cursor => {
                serde_json::json!({ "type": "string", "description": "The cursor the previous page of this log returned while it was truncated." })
            }
            Arg::Page => serde_json::json!({ "type": "integer", "minimum": 1, "maximum": 10000 }),
        }
    }

    /// The value, checked against this argument's alphabet. The reason word
    /// names the argument, never the value.
    fn validate(self, v: &serde_json::Value) -> Result<String, String> {
        let bad = || format!("invalid-argument:{}", self.key());
        if self == Arg::Page {
            return v
                .as_u64()
                .filter(|n| (1..=10_000).contains(n))
                .map(|n| n.to_string())
                .ok_or_else(bad);
        }
        let s = v.as_str().ok_or_else(bad)?;
        let (max, extra): (usize, &str) = match self {
            Arg::Script | Arg::Project => (64, "_-"),
            Arg::ScriptTag | Arg::BuildId => (64, "-"),
            Arg::Cursor => (512, "._~=+/-"),
            Arg::Page => unreachable!(),
        };
        let ok = !s.is_empty()
            && s.len() <= max
            && s.chars()
                .all(|c| c.is_ascii_alphanumeric() || extra.contains(c));
        if !ok {
            return Err(bad());
        }
        Ok(percent_encode(s))
    }
}

/// Encode everything but RFC 3986 unreserved characters.
fn percent_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// One allowlisted call.
#[derive(Debug)]
pub(crate) struct Tool {
    pub name: &'static str,
    pub description: &'static str,
    pub method: Method,
    /// Path under the API base. `{account}` is the tray-bound account; each
    /// other `{key}` is the [`Arg`] of that key from `path_args`.
    pub path: &'static str,
    pub path_args: &'static [Arg],
    pub query_args: &'static [Arg],
    /// The OAuth scope this call needs. The ids Tillandsias requests at login
    /// are in `CLOUDFLARE_LOGIN_SCOPES` (measured, 1718-adra); `zone.read`,
    /// `workers-scripts.read` and `pages.read` are not requested today, so the
    /// probe reports them missing until they are added to the client.
    pub scope: &'static str,
}

pub(crate) const SCOPE_PROBE_TOOL: &str = "cloudflare.scope_probe";

pub(crate) const TOOLS: &[Tool] = &[
    Tool {
        name: "cloudflare.accounts_list",
        description: "List the Cloudflare accounts the operator's sign-in reaches.",
        method: Method::Get,
        path: "/accounts",
        path_args: &[],
        query_args: &[Arg::Page],
        scope: "account-settings.read",
    },
    Tool {
        name: "cloudflare.zones_list",
        description: "List the zones (domains) in the operator's account.",
        method: Method::Get,
        path: "/zones?account.id={account}",
        path_args: &[],
        query_args: &[Arg::Page],
        scope: "zone.read",
    },
    Tool {
        name: "cloudflare.workers_scripts_list",
        description: "List the account's Workers: each one's name (id), tag and last change.",
        method: Method::Get,
        path: "/accounts/{account}/workers/scripts",
        path_args: &[],
        query_args: &[],
        scope: "workers-scripts.metadata_read",
    },
    Tool {
        name: "cloudflare.workers_script_settings",
        description: "Read one Worker's settings (bindings, compatibility date, logging).",
        method: Method::Get,
        path: "/accounts/{account}/workers/scripts/{script}/settings",
        path_args: &[Arg::Script],
        query_args: &[],
        scope: "workers-scripts.read",
    },
    Tool {
        name: "cloudflare.workers_deployments_list",
        description: "List one Worker's deployments.",
        method: Method::Get,
        path: "/accounts/{account}/workers/scripts/{script}/deployments",
        path_args: &[Arg::Script],
        query_args: &[],
        scope: "workers-scripts.read",
    },
    Tool {
        name: "cloudflare.builds_triggers_list",
        description: "List one Worker's Workers Builds triggers, with their branch and path filters. Use it to see why a push did or did not start a build.",
        method: Method::Get,
        path: "/accounts/{account}/builds/workers/{script_tag}/triggers",
        path_args: &[Arg::ScriptTag],
        query_args: &[],
        scope: "workers-ci.read",
    },
    Tool {
        name: "cloudflare.builds_list",
        description: "List one Worker's recent builds: branch, commit, trigger, status and duration.",
        method: Method::Get,
        path: "/accounts/{account}/builds/workers/{script_tag}/builds",
        path_args: &[Arg::ScriptTag],
        query_args: &[Arg::Page],
        scope: "workers-ci.read",
    },
    Tool {
        name: "cloudflare.build_get",
        description: "Read one build.",
        method: Method::Get,
        path: "/accounts/{account}/builds/builds/{build_id}",
        path_args: &[Arg::BuildId],
        query_args: &[],
        scope: "workers-ci.read",
    },
    Tool {
        name: "cloudflare.build_logs",
        description: "Read one build's log. While the result says it is truncated, call again with the cursor it returned.",
        method: Method::Get,
        path: "/accounts/{account}/builds/builds/{build_id}/logs",
        path_args: &[Arg::BuildId],
        query_args: &[Arg::Cursor],
        scope: "workers-ci.read",
    },
    Tool {
        name: "cloudflare.pages_projects_list",
        description: "List the account's Pages projects.",
        method: Method::Get,
        path: "/accounts/{account}/pages/projects",
        path_args: &[],
        query_args: &[Arg::Page],
        scope: "pages.read",
    },
    Tool {
        name: "cloudflare.pages_deployments_list",
        description: "List one Pages project's deployments.",
        method: Method::Get,
        path: "/accounts/{account}/pages/projects/{project}/deployments",
        path_args: &[Arg::Project],
        query_args: &[Arg::Page],
        scope: "pages.read",
    },
];

pub(crate) fn find_tool(name: &str) -> Option<&'static Tool> {
    TOOLS.iter().find(|t| t.name == name)
}

/// The descriptors `tools/list` advertises: the probe first, then the table.
pub(crate) fn tool_descriptors() -> Vec<serde_json::Value> {
    let mut out = vec![serde_json::json!({
        "name": SCOPE_PROBE_TOOL,
        "description": "Call this first. Reports which of the read-only Cloudflare tools the operator's stored sign-in permits, by scope, and the account they are bound to. Every cloudflare.* tool is a read (GET) of the operator's own account; none can change anything.",
        "inputSchema": { "type": "object", "properties": {} }
    })];
    for t in TOOLS {
        let mut props = serde_json::Map::new();
        let mut required = Vec::new();
        for a in t.path_args {
            props.insert(a.key().into(), a.schema());
            required.push(a.key());
        }
        for a in t.query_args {
            props.insert(a.key().into(), a.schema());
        }
        out.push(serde_json::json!({
            "name": t.name,
            "description": format!("{} Read-only (GET); needs the {} scope.", t.description, t.scope),
            "inputSchema": { "type": "object", "properties": props, "required": required }
        }));
    }
    out
}

/// A named refusal: `refused:cloudflare-mcp:<reason>`, why, remedy.
fn refusal(reason: &str, why: &str, remedy: &str) -> String {
    format!("refused:cloudflare-mcp:{reason}\n  why: {why}\n  remedy: {remedy}")
}

fn refuse_reason(reason: &str) -> String {
    let (why, remedy): (&str, &str) = if let Some(scope) = reason.strip_prefix("scope-missing:") {
        return refusal(
            reason,
            &format!(
                "the operator's Cloudflare sign-in does not carry the {scope} scope, so Cloudflare refused the read"
            ),
            "ask the operator to add the scope to the Tillandsias client and sign in again with `tillandsias --cloudflare-login`; cloudflare.scope_probe lists what the sign-in permits today",
        );
    } else if reason.starts_with("invalid-argument:") {
        (
            "an argument is missing or outside its allowed characters and length",
            "pass the id exactly as the matching list tool shows it",
        )
    } else if reason.starts_with("unknown-argument") {
        (
            "the tool takes only the arguments its schema lists; the method, path and account are fixed",
            "drop the extra argument",
        )
    } else if reason.starts_with("method-not-allowed:") {
        (
            "these tools only read (GET); nothing is sent for any other method",
            "use a read tool; changes to the account are the operator's to make",
        )
    } else {
        match reason {
            "unknown-tool" => (
                "no allowlisted Cloudflare tool has that name",
                "call tools/list and use a cloudflare.* name",
            ),
            "account-not-bound" => (
                "the tools reach only the account the operator's tray is signed in to, never one a caller names",
                "omit account_id; the bound account is used",
            ),
            "account-unresolved" => (
                "the stored sign-in names no account and Cloudflare does not list exactly one",
                "ask the operator to sign in again with `tillandsias --cloudflare-login`",
            ),
            "not-signed-in" => (
                "the operator has not signed in to Cloudflare on this host",
                "ask the operator to run `tillandsias --cloudflare-login`",
            ),
            "unauthorized" => (
                "Cloudflare refused the stored sign-in (expired or revoked)",
                "ask the operator to run `tillandsias --cloudflare-login`",
            ),
            "not-found" => (
                "Cloudflare has no such item in the bound account",
                "list first, and pass an id the list returned",
            ),
            "rate-limited" => (
                "Cloudflare is rate-limiting this account",
                "wait a minute and retry",
            ),
            "response-unusable" => (
                "Cloudflare's answer was not the JSON envelope its API documents",
                "retry; if it repeats, report it",
            ),
            "api-base-not-https" => (
                "the API base is neither https nor loopback, so the sign-in is never sent to it",
                "unset TILLANDSIAS_CLOUDFLARE_API_BASE_URL",
            ),
            _ if reason.starts_with("vault") || reason.starts_with("store:") => (
                "the host could not read the stored sign-in from Vault",
                "start Tillandsias (the tray) so its Vault is up, then retry",
            ),
            _ if reason.starts_with("transport") => (
                "the request did not reach Cloudflare or its answer did not arrive",
                "check the host's network, then retry",
            ),
            _ => (
                "Cloudflare answered with an error",
                "retry; if it repeats, report it with this reason",
            ),
        }
    };
    refusal(reason, why, remedy)
}

/// Replace every occurrence of each non-empty secret with `<redacted>`.
pub(crate) fn redact(text: &str, secrets: &[&str]) -> String {
    let mut out = text.to_string();
    for s in secrets.iter().filter(|s| !s.is_empty()) {
        out = out.replace(s, "<redacted>");
    }
    out
}

/// Keep a reason word only when it is made of `[a-z0-9.:-]`, so a reason can
/// never carry response bytes.
fn fixed_word(s: &str) -> String {
    let ok = !s.is_empty()
        && s.len() <= 80
        && s.chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || ".:-_".contains(c));
    if ok {
        s.to_string()
    } else {
        "unclassified".to_string()
    }
}

/// The ONE function that sends. A method other than GET is refused here,
/// before the transport is touched; the transport itself can only GET.
pub(crate) fn send(
    http: &dyn HttpClient,
    method: Method,
    url: &str,
    token: &str,
) -> Result<HttpResponse, String> {
    if method != Method::Get {
        return Err(format!("method-not-allowed:{}", method.word()));
    }
    http.get_with_bearer(url, token).map_err(|e| {
        // ReqwestHttpClient's transport words are `refused:cloudflare-login:
        // transport-get-<kind>`; keep only the kind.
        match e.rsplit_once("transport-get-") {
            Some((_, kind)) => format!("transport-{}", fixed_word(kind)),
            None => "transport".to_string(),
        }
    })
}

/// Map a response to the tool's result, or a reason word.
fn interpret(resp: &HttpResponse, scope: &str) -> Result<serde_json::Value, String> {
    match resp.status {
        200..=299 => {}
        401 => return Err("unauthorized".into()),
        403 => return Err(format!("scope-missing:{scope}")),
        404 => return Err("not-found".into()),
        429 => return Err("rate-limited".into()),
        s => {
            let codes = error_codes(&resp.body);
            return Err(if codes.is_empty() {
                format!("http-{s}")
            } else {
                format!("http-{s}:cf-errors-{codes}")
            });
        }
    }
    let v: serde_json::Value =
        serde_json::from_str(&resp.body).map_err(|_| "response-unusable".to_string())?;
    if v.get("success").and_then(serde_json::Value::as_bool) != Some(true) {
        return Err("response-unusable".into());
    }
    let mut out = serde_json::Map::new();
    out.insert(
        "result".into(),
        v.get("result").cloned().unwrap_or(serde_json::Value::Null),
    );
    if let Some(info) = v.get("result_info") {
        out.insert("result_info".into(), info.clone());
    }
    Ok(serde_json::Value::Object(out))
}

/// Cloudflare's numeric error codes, joined with `.` (never its messages).
fn error_codes(body: &str) -> String {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(body) else {
        return String::new();
    };
    v.get("errors")
        .and_then(serde_json::Value::as_array)
        .map(|errs| {
            errs.iter()
                .filter_map(|e| e.get("code").and_then(serde_json::Value::as_u64))
                .take(4)
                .map(|c| c.to_string())
                .collect::<Vec<_>>()
                .join(".")
        })
        .unwrap_or_default()
}

/// Is `id` shaped like a Cloudflare account id?
fn account_id_ok(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().all(|c| c.is_ascii_alphanumeric())
}

/// The URL for one call, from the template, the bound account and the
/// validated arguments. Unknown arguments, and an `account_id` other than the
/// bound one, are refused.
pub(crate) fn build_url(
    api_base: &str,
    tool: &Tool,
    account: &str,
    args: Option<&serde_json::Map<String, serde_json::Value>>,
) -> Result<String, String> {
    let empty = serde_json::Map::new();
    let args = args.unwrap_or(&empty);
    for (k, v) in args {
        if k == "account_id" {
            if v.as_str() != Some(account) {
                return Err("account-not-bound".into());
            }
            continue;
        }
        let known = tool
            .path_args
            .iter()
            .chain(tool.query_args)
            .any(|a| a.key() == k);
        if !known {
            let named = k.len() <= 32 && k.chars().all(|c| c.is_ascii_lowercase() || c == '_');
            return Err(if named {
                format!("unknown-argument:{k}")
            } else {
                "unknown-argument".into()
            });
        }
    }
    let mut path = tool.path.replace("{account}", account);
    for a in tool.path_args {
        let v = args
            .get(a.key())
            .ok_or_else(|| format!("invalid-argument:{}", a.key()))?;
        path = path.replace(&format!("{{{}}}", a.key()), &a.validate(v)?);
    }
    for a in tool.query_args {
        if let Some(v) = args.get(a.key()) {
            let sep = if path.contains('?') { '&' } else { '?' };
            path = format!("{path}{sep}{}={}", a.key(), a.validate(v)?);
        }
    }
    Ok(format!("{}{path}", api_base.trim_end_matches('/')))
}

/// What a tool call needs from the host.
pub(crate) struct Deps<'a> {
    pub http: &'a dyn HttpClient,
    pub store: &'a dyn CloudflareTokenStore,
    /// Rotate the stored sign-in when it is due. A failure is a note, not a
    /// refusal: the call's own 401 says whether the token still works.
    pub freshen: &'a dyn Fn() -> Result<(), String>,
    pub api_base: &'a str,
}

/// The stored token and the tray-bound account.
fn signed_in(deps: &Deps) -> Result<(String, Option<String>, String), String> {
    if !crate::vault_bootstrap::cloudflare_token_endpoint_is_safe(deps.api_base) {
        return Err("api-base-not-https".into());
    }
    if let Err(e) = (deps.freshen)() {
        eprintln!(
            "note:cloudflare-mcp:rotation-not-done:{} (the call proceeds with the stored token)",
            fixed_word(e.split([' ', '(']).next().unwrap_or(""))
        );
    }
    let bundle = deps
        .store
        .read_bundle()
        .map_err(|e| format!("store:{}", fixed_word(&e)))?
        .ok_or("not-signed-in")?;
    let token = bundle.access_token.clone();
    let refresh = bundle.refresh_token.clone();
    let account = match bundle.account_id.as_deref().filter(|a| !a.is_empty()) {
        Some(a) if account_id_ok(a) => a.to_string(),
        Some(_) => return Err("account-unresolved".into()),
        None => resolve_only_account(deps, &token)?,
    };
    Ok((token, refresh, account))
}

/// With no account stored beside the sign-in, the bound account is the ONLY
/// one Cloudflare lists; zero or several is a refusal, never a guess.
fn resolve_only_account(deps: &Deps, token: &str) -> Result<String, String> {
    let url = format!("{}/accounts", deps.api_base.trim_end_matches('/'));
    let resp = send(deps.http, Method::Get, &url, token)?;
    let v = interpret(&resp, "account-settings.read")?;
    match v["result"].as_array().map(Vec::as_slice) {
        Some([only]) => only["id"]
            .as_str()
            .filter(|a| account_id_ok(a))
            .map(str::to_string)
            .ok_or_else(|| "account-unresolved".to_string()),
        _ => Err("account-unresolved".into()),
    }
}

/// Serve one `tools/call` for a `cloudflare.*` name. `Ok` is the tool's
/// result; `Err` is the refusal text. Both are redacted.
pub(crate) fn call(
    deps: &Deps,
    name: &str,
    args: Option<&serde_json::Map<String, serde_json::Value>>,
) -> Result<serde_json::Value, String> {
    let mut secrets: Vec<String> = Vec::new();
    let out = call_inner(deps, name, args, &mut secrets);
    let refs: Vec<&str> = secrets.iter().map(String::as_str).collect();
    match out {
        Ok(v) => {
            let text = redact(&v.to_string(), &refs);
            serde_json::from_str(&text).map_err(|_| refuse_reason("response-unusable"))
        }
        Err(reason) => Err(redact(&refuse_reason(&reason), &refs)),
    }
}

fn call_inner(
    deps: &Deps,
    name: &str,
    args: Option<&serde_json::Map<String, serde_json::Value>>,
    secrets: &mut Vec<String>,
) -> Result<serde_json::Value, String> {
    let tool = find_tool(name);
    if tool.is_none() && name != SCOPE_PROBE_TOOL {
        return Err("unknown-tool".into());
    }
    let (token, refresh, account) = signed_in(deps)?;
    secrets.push(token.clone());
    if let Some(r) = refresh {
        secrets.push(r);
    }
    let Some(tool) = tool else {
        return scope_probe(deps, &token, &account, args);
    };
    let url = build_url(deps.api_base, tool, &account, args)?;
    let resp = send(deps.http, tool.method, &url, &token)?;
    interpret(&resp, tool.scope)
}

/// For each scope, one argument-free read (or, for the per-Worker scopes, a
/// read of the first Worker listed). 2xx is permitted, 403 is missing; a 401
/// refuses the whole probe.
fn scope_probe(
    deps: &Deps,
    token: &str,
    account: &str,
    args: Option<&serde_json::Map<String, serde_json::Value>>,
) -> Result<serde_json::Value, String> {
    if args.is_some_and(|a| a.keys().any(|k| k != "account_id")) {
        return Err("unknown-argument".into());
    }
    if let Some(a) = args.and_then(|a| a.get("account_id"))
        && a.as_str() != Some(account)
    {
        return Err("account-not-bound".into());
    }
    let mut scopes = serde_json::Map::new();
    let mut first_script: Option<(String, String)> = None;
    let probe = |tool_name: &str,
                 call_args: serde_json::Map<String, serde_json::Value>|
     -> Result<(&'static str, Option<serde_json::Value>), String> {
        let tool = find_tool(tool_name).ok_or("unknown-tool")?;
        let url = build_url(deps.api_base, tool, account, Some(&call_args))?;
        let resp = send(deps.http, tool.method, &url, token)?;
        match interpret(&resp, tool.scope) {
            Ok(v) => Ok(("permitted", Some(v))),
            Err(e) if e == "unauthorized" => Err(e),
            Err(e) if e.starts_with("scope-missing:") => Ok(("missing", None)),
            Err(e) => Ok((
                if e.starts_with("transport") {
                    "unknown:transport"
                } else {
                    "unknown:error"
                },
                None,
            )),
        }
    };
    let (s, _) = probe("cloudflare.accounts_list", serde_json::Map::new())?;
    scopes.insert("account-settings.read".into(), s.into());
    let (s, _) = probe("cloudflare.zones_list", serde_json::Map::new())?;
    scopes.insert("zone.read".into(), s.into());
    let (s, listed) = probe("cloudflare.workers_scripts_list", serde_json::Map::new())?;
    scopes.insert("workers-scripts.metadata_read".into(), s.into());
    if let Some(first) = listed
        .as_ref()
        .and_then(|v| v["result"].as_array())
        .and_then(|a| a.first())
        && let (Some(id), Some(tag)) = (first["id"].as_str(), first["tag"].as_str())
    {
        first_script = Some((id.to_string(), tag.to_string()));
    }
    match &first_script {
        Some((id, tag)) => {
            let mut a = serde_json::Map::new();
            a.insert("script".into(), id.clone().into());
            let (s, _) = probe("cloudflare.workers_deployments_list", a)?;
            scopes.insert("workers-scripts.read".into(), s.into());
            let mut a = serde_json::Map::new();
            a.insert("script_tag".into(), tag.clone().into());
            let (s, _) = probe("cloudflare.builds_triggers_list", a)?;
            scopes.insert("workers-ci.read".into(), s.into());
        }
        None => {
            for scope in ["workers-scripts.read", "workers-ci.read"] {
                scopes.insert(scope.into(), "unknown:no-worker-to-probe-with".into());
            }
        }
    }
    let (s, _) = probe("cloudflare.pages_projects_list", serde_json::Map::new())?;
    scopes.insert("pages.read".into(), s.into());

    let tools: serde_json::Map<String, serde_json::Value> = TOOLS
        .iter()
        .map(|t| {
            (
                t.name.to_string(),
                scopes
                    .get(t.scope)
                    .cloned()
                    .unwrap_or_else(|| "unknown:error".into()),
            )
        })
        .collect();
    Ok(serde_json::json!({
        "account_id": account,
        "account_binding": "the account the operator's tray is signed in to; a call naming another is refused",
        "scopes": scopes,
        "tools": tools,
        "remedy_for_missing": "ask the operator to add the scope to the Tillandsias client and sign in again with `tillandsias --cloudflare-login`",
    }))
}

/// The live dependencies: Vault, the rotation path, reqwest.
pub(crate) fn call_live(
    name: &str,
    args: Option<&serde_json::Map<String, serde_json::Value>>,
    debug: bool,
) -> Result<serde_json::Value, String> {
    let http = crate::cloudflare_oauth::ReqwestHttpClient::default();
    let store = crate::vault_bootstrap::VaultCloudflareTokenStore { debug };
    let freshen = || crate::vault_bootstrap::cloudflare_token_due_check_live(debug).map(|_| ());
    let api_base = api_base_url();
    let deps = Deps {
        http: &http,
        store: &store,
        freshen: &freshen,
        api_base: &api_base,
    };
    call(&deps, name, args)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault_bootstrap::CloudflareTokenBundle;
    use std::cell::RefCell;

    // Split so the literal never appears whole in this file's own text.
    const TOKEN: &str = concat!("cf-access-", "SECRET-0f1e2d");
    const REFRESH: &str = concat!("cf-refresh-", "SECRET-9a8b7c");
    const ACCOUNT: &str = "0123456789abcdef0123456789abcdef";

    struct FakeStore(Result<Option<CloudflareTokenBundle>, String>);

    impl CloudflareTokenStore for FakeStore {
        fn read_bundle(&self) -> Result<Option<CloudflareTokenBundle>, String> {
            self.0.clone()
        }
        fn write_record(&self, _: &str, _: serde_json::Value) -> Result<(), String> {
            Err("read-only-fake".into())
        }
        fn delete_record(&self, _: &str) -> Result<(), String> {
            Err("read-only-fake".into())
        }
    }

    fn bundle(account: Option<&str>) -> CloudflareTokenBundle {
        CloudflareTokenBundle {
            access_token: TOKEN.into(),
            expires_at: Some(4_000_000_000),
            account_id: account.map(str::to_string),
            client_id: "client".into(),
            refresh_token: Some(REFRESH.into()),
            refresh_token_expires_at: None,
        }
    }

    type Answer = Box<dyn Fn(&str) -> Result<HttpResponse, String>>;

    /// Records every request (the ledger) and answers by URL suffix.
    struct Api {
        ledger: RefCell<Vec<(String, String)>>,
        answer: Answer,
    }

    impl Api {
        fn new(answer: impl Fn(&str) -> Result<HttpResponse, String> + 'static) -> Self {
            Self {
                ledger: RefCell::new(Vec::new()),
                answer: Box::new(answer),
            }
        }
    }

    impl HttpClient for Api {
        fn get(&self, url: &str) -> Result<HttpResponse, String> {
            self.ledger
                .borrow_mut()
                .push(("GET-unauth".into(), url.into()));
            Err("unexpected".into())
        }
        fn post_form(&self, url: &str, _: &[(&str, &str)]) -> Result<HttpResponse, String> {
            self.ledger.borrow_mut().push(("POST".into(), url.into()));
            Err("unexpected".into())
        }
        fn get_with_bearer(&self, url: &str, bearer: &str) -> Result<HttpResponse, String> {
            assert_eq!(bearer, TOKEN, "the stored token is the bearer");
            self.ledger.borrow_mut().push(("GET".into(), url.into()));
            (self.answer)(url)
        }
    }

    fn ok(result: serde_json::Value) -> Result<HttpResponse, String> {
        Ok(HttpResponse {
            status: 200,
            body:
                serde_json::json!({"success": true, "errors": [], "messages": [], "result": result})
                    .to_string(),
        })
    }

    fn status(code: u16, body: &str) -> Result<HttpResponse, String> {
        Ok(HttpResponse {
            status: code,
            body: body.into(),
        })
    }

    fn run(
        store: &FakeStore,
        api: &Api,
        name: &str,
        args: serde_json::Value,
    ) -> Result<serde_json::Value, String> {
        let freshen = || Ok(());
        let deps = Deps {
            http: api,
            store,
            freshen: &freshen,
            api_base: "http://127.0.0.1:9/client/v4",
        };
        call(&deps, name, args.as_object())
    }

    #[test]
    fn cloudflare_mcp_every_tool_is_a_get_with_a_fixed_template() {
        assert!(TOOLS.len() >= 10);
        for t in TOOLS {
            assert_eq!(t.method, Method::Get, "{} must be GET", t.name);
            assert!(t.name.starts_with("cloudflare."), "{}", t.name);
            assert!(t.path.starts_with('/'), "{}", t.name);
            for key in ["path", "method", "url", "endpoint"] {
                assert!(
                    t.path_args
                        .iter()
                        .chain(t.query_args)
                        .all(|a| a.key() != key),
                    "{} takes no {key} argument",
                    t.name
                );
            }
        }
        let names: Vec<_> = tool_descriptors()
            .iter()
            .map(|d| d["name"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(names[0], SCOPE_PROBE_TOOL, "the probe is listed first");
        assert_eq!(names.len(), TOOLS.len() + 1);
    }

    #[test]
    fn cloudflare_mcp_non_get_is_refused_before_anything_is_sent() {
        let api = Api::new(|_| ok(serde_json::json!([])));
        for m in [Method::Post, Method::Delete] {
            let e = send(&api, m, "http://127.0.0.1:9/accounts", TOKEN).unwrap_err();
            assert_eq!(e, format!("method-not-allowed:{}", m.word()));
        }
        assert!(api.ledger.borrow().is_empty(), "nothing was sent");
        // NEGATIVE CONTROL: the same call as a GET is sent.
        send(&api, Method::Get, "http://127.0.0.1:9/accounts", TOKEN).unwrap();
        assert_eq!(api.ledger.borrow().len(), 1);
    }

    #[test]
    fn cloudflare_mcp_builds_calls_reach_the_bound_account() {
        let store = FakeStore(Ok(Some(bundle(Some(ACCOUNT)))));
        let api = Api::new(|_| {
            ok(serde_json::json!([{"trigger_uuid": "t1", "branch_includes": ["main"]}]))
        });
        let v = run(
            &store,
            &api,
            "cloudflare.builds_triggers_list",
            serde_json::json!({"script_tag": "abc123"}),
        )
        .unwrap();
        assert_eq!(v["result"][0]["trigger_uuid"], "t1");
        let ledger = api.ledger.borrow();
        assert_eq!(ledger.len(), 1);
        assert_eq!(
            ledger[0].1,
            format!(
                "http://127.0.0.1:9/client/v4/accounts/{ACCOUNT}/builds/workers/abc123/triggers"
            )
        );
    }

    #[test]
    fn cloudflare_mcp_log_cursor_is_validated_and_encoded() {
        let store = FakeStore(Ok(Some(bundle(Some(ACCOUNT)))));
        let api = Api::new(|_| ok(serde_json::json!({"lines": [], "truncated": false})));
        run(
            &store,
            &api,
            "cloudflare.build_logs",
            serde_json::json!({"build_id": "1f2e-3d4c", "cursor": "ab+c/d="}),
        )
        .unwrap();
        assert!(
            api.ledger.borrow()[0]
                .1
                .ends_with("/builds/builds/1f2e-3d4c/logs?cursor=ab%2Bc%2Fd%3D")
        );
        // A traversal or query injection in an id never reaches the URL.
        for bad in ["../../user", "x?y=1", "a b", ""] {
            let e = run(
                &store,
                &api,
                "cloudflare.build_get",
                serde_json::json!({ "build_id": bad }),
            )
            .unwrap_err();
            assert!(
                e.starts_with("refused:cloudflare-mcp:invalid-argument:build_id"),
                "{e}"
            );
        }
        assert_eq!(api.ledger.borrow().len(), 1, "no refused call was sent");
    }

    #[test]
    fn cloudflare_mcp_account_is_bound_to_the_tray() {
        let store = FakeStore(Ok(Some(bundle(Some(ACCOUNT)))));
        let api = Api::new(|_| ok(serde_json::json!([])));
        let e = run(
            &store,
            &api,
            "cloudflare.workers_scripts_list",
            serde_json::json!({"account_id": "ffffffffffffffffffffffffffffffff"}),
        )
        .unwrap_err();
        assert!(
            e.starts_with("refused:cloudflare-mcp:account-not-bound"),
            "{e}"
        );
        assert!(
            api.ledger.borrow().is_empty(),
            "nothing sent for another account"
        );
        // NEGATIVE CONTROL: the bound account, named or not, is served.
        run(
            &store,
            &api,
            "cloudflare.workers_scripts_list",
            serde_json::json!({ "account_id": ACCOUNT }),
        )
        .unwrap();
        run(
            &store,
            &api,
            "cloudflare.workers_scripts_list",
            serde_json::json!({}),
        )
        .unwrap();
        assert_eq!(api.ledger.borrow().len(), 2);
        assert!(
            api.ledger.borrow()[1]
                .1
                .contains(&format!("/accounts/{ACCOUNT}/"))
        );
    }

    #[test]
    fn cloudflare_mcp_unstored_account_is_the_only_one_listed_or_refused() {
        let store = FakeStore(Ok(Some(bundle(None))));
        let api = Api::new(|url| {
            if url.ends_with("/accounts") {
                ok(serde_json::json!([{"id": ACCOUNT, "name": "a"}]))
            } else {
                ok(serde_json::json!([]))
            }
        });
        run(
            &store,
            &api,
            "cloudflare.workers_scripts_list",
            serde_json::json!({}),
        )
        .unwrap();
        assert!(api.ledger.borrow()[1].1.contains(ACCOUNT));
        let two = Api::new(|_| ok(serde_json::json!([{"id": "a1"}, {"id": "b2"}])));
        let e = run(
            &store,
            &two,
            "cloudflare.workers_scripts_list",
            serde_json::json!({}),
        )
        .unwrap_err();
        assert!(
            e.starts_with("refused:cloudflare-mcp:account-unresolved"),
            "{e}"
        );
    }

    #[test]
    fn cloudflare_mcp_unknown_argument_and_tool_are_refused() {
        let store = FakeStore(Ok(Some(bundle(Some(ACCOUNT)))));
        let api = Api::new(|_| ok(serde_json::json!([])));
        let e = run(
            &store,
            &api,
            "cloudflare.accounts_list",
            serde_json::json!({"method": "POST"}),
        )
        .unwrap_err();
        assert!(
            e.starts_with("refused:cloudflare-mcp:unknown-argument:method"),
            "{e}"
        );
        let e = run(&store, &api, "cloudflare.request", serde_json::json!({})).unwrap_err();
        assert!(e.starts_with("refused:cloudflare-mcp:unknown-tool"), "{e}");
        assert!(api.ledger.borrow().is_empty());
    }

    #[test]
    fn cloudflare_mcp_scope_missing_is_named_with_a_remedy() {
        let store = FakeStore(Ok(Some(bundle(Some(ACCOUNT)))));
        let api = Api::new(|_| {
            status(
                403,
                r#"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}"#,
            )
        });
        let e = run(&store, &api, "cloudflare.zones_list", serde_json::json!({})).unwrap_err();
        assert!(
            e.starts_with("refused:cloudflare-mcp:scope-missing:zone.read\n"),
            "{e}"
        );
        assert!(
            e.contains("remedy:") && e.contains("--cloudflare-login"),
            "{e}"
        );
    }

    #[test]
    fn cloudflare_mcp_scope_probe_reports_each_scope() {
        let store = FakeStore(Ok(Some(bundle(Some(ACCOUNT)))));
        let api = Api::new(|url| {
            if url.contains("/zones") || url.contains("/pages/") {
                status(403, "{}")
            } else if url.ends_with("/workers/scripts") {
                ok(serde_json::json!([{"id": "observatorium", "tag": "abc123"}]))
            } else {
                ok(serde_json::json!([]))
            }
        });
        let v = run(&store, &api, SCOPE_PROBE_TOOL, serde_json::json!({})).unwrap();
        assert_eq!(v["account_id"], ACCOUNT);
        assert_eq!(v["scopes"]["workers-ci.read"], "permitted");
        assert_eq!(v["scopes"]["account-settings.read"], "permitted");
        assert_eq!(v["scopes"]["zone.read"], "missing");
        assert_eq!(v["scopes"]["pages.read"], "missing");
        assert_eq!(v["tools"]["cloudflare.builds_list"], "permitted");
        assert_eq!(v["tools"]["cloudflare.zones_list"], "missing");
        assert!(
            api.ledger
                .borrow()
                .iter()
                .any(|(_, u)| u.ends_with("/builds/workers/abc123/triggers"))
        );
    }

    #[test]
    fn cloudflare_mcp_token_appears_in_no_result_or_error() {
        let store = FakeStore(Ok(Some(bundle(Some(ACCOUNT)))));
        // A response that echoes the token back.
        let echoing = format!(
            r#"{{"success":true,"errors":[],"result":[{{"id":"x","note":"Bearer {TOKEN} and {REFRESH}"}}]}}"#
        );
        let cases: Vec<Answer> = vec![
            Box::new(move |_| status(200, &echoing)),
            Box::new(|_| {
                status(
                    401,
                    &format!(r#"{{"errors":[{{"code":10001,"message":"bad token {TOKEN}"}}]}}"#),
                )
            }),
            Box::new(|_| status(500, &format!("<html>{TOKEN}</html>"))),
            Box::new(|_| status(200, &format!("not json {TOKEN}"))),
            Box::new(|_| {
                Err(format!(
                    "refused:cloudflare-login:transport-get-connect {TOKEN}"
                ))
            }),
            Box::new(|_| Err(format!("transport-get-{TOKEN}"))),
        ];
        for (i, answer) in cases.into_iter().enumerate() {
            let api = Api::new(answer);
            let out = run(
                &store,
                &api,
                "cloudflare.accounts_list",
                serde_json::json!({}),
            );
            let text = match &out {
                Ok(v) => v.to_string(),
                Err(e) => e.clone(),
            };
            assert!(!text.contains(TOKEN), "case {i} leaked the token: {text}");
            assert!(
                !text.contains(REFRESH),
                "case {i} leaked the refresh token: {text}"
            );
            assert!(!text.contains("SECRET"), "case {i}: {text}");
        }
    }

    #[test]
    fn cloudflare_mcp_error_text_is_fixed_words() {
        let store = FakeStore(Ok(Some(bundle(Some(ACCOUNT)))));
        let api = Api::new(|_| {
            status(
                502,
                r#"{"errors":[{"code":7003,"message":"<script>steal()</script>"}]}"#,
            )
        });
        let e = run(
            &store,
            &api,
            "cloudflare.accounts_list",
            serde_json::json!({}),
        )
        .unwrap_err();
        assert!(
            e.starts_with("refused:cloudflare-mcp:http-502:cf-errors-7003\n"),
            "{e}"
        );
        assert!(
            !e.contains("steal"),
            "Cloudflare's message text is never quoted: {e}"
        );
        let api = Api::new(|_| status(401, "{}"));
        let e = run(
            &store,
            &api,
            "cloudflare.accounts_list",
            serde_json::json!({}),
        )
        .unwrap_err();
        assert!(
            e.starts_with("refused:cloudflare-mcp:unauthorized\n"),
            "{e}"
        );
    }

    #[test]
    fn cloudflare_mcp_not_signed_in_and_vault_down_are_refusals() {
        let api = Api::new(|_| ok(serde_json::json!([])));
        let e = run(
            &FakeStore(Ok(None)),
            &api,
            "cloudflare.accounts_list",
            serde_json::json!({}),
        )
        .unwrap_err();
        assert!(
            e.starts_with("refused:cloudflare-mcp:not-signed-in\n"),
            "{e}"
        );
        let e = run(
            &FakeStore(Err("vault-sealed".into())),
            &api,
            "cloudflare.accounts_list",
            serde_json::json!({}),
        )
        .unwrap_err();
        assert!(
            e.starts_with("refused:cloudflare-mcp:store:vault-sealed\n"),
            "{e}"
        );
        assert!(api.ledger.borrow().is_empty());
    }

    #[test]
    fn cloudflare_mcp_never_sends_the_token_to_plain_http_off_loopback() {
        let store = FakeStore(Ok(Some(bundle(Some(ACCOUNT)))));
        let api = Api::new(|_| ok(serde_json::json!([])));
        let freshen = || Ok(());
        let deps = Deps {
            http: &api,
            store: &store,
            freshen: &freshen,
            api_base: "http://api.example.net/client/v4",
        };
        let e = call(&deps, "cloudflare.accounts_list", None).unwrap_err();
        assert!(
            e.starts_with("refused:cloudflare-mcp:api-base-not-https"),
            "{e}"
        );
        assert!(api.ledger.borrow().is_empty());
        assert_eq!(API_BASE_DEFAULT, "https://api.cloudflare.com/client/v4");
    }
}

/// Against the real fake (`tillandsias-fake-cloudflare`) over a loopback
/// socket with the real reqwest client: run with
/// `TILLANDSIAS_FAKE_CLOUDFLARE_BIN=<path> cargo test -p tillandsias-headless
/// --bin tillandsias cloudflare_mcp::loopback_tests -- --ignored`.
#[cfg(test)]
mod loopback_tests {
    use super::*;
    use crate::vault_bootstrap::CloudflareTokenBundle;
    use std::io::{BufRead, BufReader};
    use std::process::{Child, Command, Stdio};

    const TOKEN: &str = concat!("loopback-", "cf-token-77aa");

    struct Store;
    impl CloudflareTokenStore for Store {
        fn read_bundle(&self) -> Result<Option<CloudflareTokenBundle>, String> {
            Ok(Some(CloudflareTokenBundle {
                access_token: TOKEN.into(),
                account_id: None,
                client_id: "c".into(),
                ..Default::default()
            }))
        }
        fn write_record(&self, _: &str, _: serde_json::Value) -> Result<(), String> {
            Err("no".into())
        }
        fn delete_record(&self, _: &str) -> Result<(), String> {
            Err("no".into())
        }
    }

    struct Fake {
        child: Child,
        base: String,
        ledger: std::path::PathBuf,
    }
    impl Drop for Fake {
        fn drop(&mut self) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
    }

    fn start() -> Fake {
        let bin = std::env::var("TILLANDSIAS_FAKE_CLOUDFLARE_BIN")
            .expect("set TILLANDSIAS_FAKE_CLOUDFLARE_BIN to a built tillandsias-fake-cloudflare");
        let ledger =
            std::env::temp_dir().join(format!("cf-mcp-loopback-{}.jsonl", std::process::id()));
        let mut child = Command::new(bin)
            .args(["--ledger", ledger.to_str().unwrap()])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn fake");
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap())
            .read_line(&mut line)
            .unwrap();
        Fake {
            child,
            base: format!("http://127.0.0.1:{}", line.trim()),
            ledger,
        }
    }

    fn ledger_lines(f: &Fake) -> Vec<serde_json::Value> {
        std::fs::read_to_string(&f.ledger)
            .unwrap_or_default()
            .lines()
            .filter_map(|l| serde_json::from_str(l).ok())
            .collect()
    }

    #[test]
    #[ignore]
    fn loopback_cloudflare_mcp_non_get_sends_nothing_and_builds_are_served() {
        let fake = start();
        let http = crate::cloudflare_oauth::ReqwestHttpClient::default();
        let before = ledger_lines(&fake).len();
        let e = send(
            &http,
            Method::Post,
            &format!("{}/accounts", fake.base),
            TOKEN,
        )
        .unwrap_err();
        assert_eq!(e, "method-not-allowed:POST");
        let e = send(
            &http,
            Method::Delete,
            &format!("{}/accounts", fake.base),
            TOKEN,
        )
        .unwrap_err();
        assert_eq!(e, "method-not-allowed:DELETE");
        assert_eq!(
            ledger_lines(&fake).len(),
            before,
            "the fake's ledger shows nothing sent"
        );

        let freshen = || Ok(());
        let deps = Deps {
            http: &http,
            store: &Store,
            freshen: &freshen,
            api_base: &fake.base,
        };
        let probe = call(&deps, SCOPE_PROBE_TOOL, None).unwrap();
        assert_eq!(probe["scopes"]["workers-ci.read"], "permitted", "{probe}");
        let tag = "fa4e0b0c0e0f4a1b8c9d0e1f2a3b4c5d";
        let mut a = serde_json::Map::new();
        a.insert("script_tag".into(), tag.into());
        let triggers = call(&deps, "cloudflare.builds_triggers_list", Some(&a)).unwrap();
        assert!(
            triggers["result"][0]["branch_includes"].is_array(),
            "{triggers}"
        );
        let builds = call(&deps, "cloudflare.builds_list", Some(&a)).unwrap();
        let build_id = builds["result"][0]["build_uuid"]
            .as_str()
            .unwrap()
            .to_string();
        let mut b = serde_json::Map::new();
        b.insert("build_id".into(), build_id.into());
        let page1 = call(&deps, "cloudflare.build_logs", Some(&b)).unwrap();
        assert_eq!(page1["result"]["truncated"], true);
        b.insert("cursor".into(), page1["result"]["cursor"].clone());
        let page2 = call(&deps, "cloudflare.build_logs", Some(&b)).unwrap();
        assert_eq!(page2["result"]["truncated"], false);

        let lines = ledger_lines(&fake);
        assert!(
            lines.iter().all(|l| l["method"] == "GET"),
            "only GETs reached the fake"
        );
        let all = std::fs::read_to_string(&fake.ledger).unwrap_or_default();
        assert!(
            !all.contains(TOKEN),
            "the token is a header, never in a path or body"
        );
        for v in [&probe, &triggers, &builds, &page1, &page2] {
            assert!(!v.to_string().contains(TOKEN));
        }
    }
}

//! `cloud.usage`: used vs free-tier cap per provider, read-only (order 1966-47vt).
//!
//! @trace order:1966-47vt, spec:mcp-tool-socket
//!
//! One MCP tool beside the read-only `cloudflare.*` family (1772-irs3) and
//! under the same rules: THIS host-side process reads the tokens from Vault
//! (the Cloudflare sign-in through [`CloudflareTokenStore`], the Tillandsias
//! GitHub App token through [`GitHubTokenStore`]), sends fixed GET paths, and
//! returns numbers. Neither token is in a tool input, a result, a log line or
//! an error: every result passes through [`cloudflare_mcp::redact`].
//!
//! A 403 or 404 is never a zero. It is reported on that metric as
//! `unavailable: permission-missing:<provider>:<permission>`, naming the
//! permission documented for the path that refused, and the other metrics
//! still fill.
//!
//! - cloudflare `workers_builds_minutes`: Cloudflare has no usage endpoint,
//!   so the tool sums (end − created_on) over the calendar month for every
//!   build the builds list returns, across every Worker in the bound account.
//!   Cap 3,000 minutes/month and one concurrent build (Workers Free).
//! - github `actions_cache_bytes` per repo vs the 10 GiB per-repo cap.
//! - github `actions_run_minutes` per repo this month (runs + timing). Both
//!   repos are public, so hosted-runner minutes are not billed: cap null.
//! - github `billing_usage`: the enhanced-billing usage report for the token's
//!   user, summed per product/sku.

use crate::cloudflare_mcp::{self, Method};
use crate::cloudflare_oauth::HttpClient;
use crate::vault_bootstrap::{CloudflareTokenStore, GitHubTokenStore};
use chrono::{DateTime, Datelike, NaiveDate, SecondsFormat, TimeZone, Utc};
use serde_json::{Value, json};

pub(crate) const TOOL_NAME: &str = "cloud.usage";
pub(crate) const GITHUB_API_DEFAULT: &str = "https://api.github.com";
/// The repositories whose Actions usage is read. Fixed: nothing in a request
/// chooses a repo.
pub(crate) const GITHUB_REPOS: &[&str] = &["8007342/tillandsias", "8007342/macron.dev"];
pub(crate) const CLOUDFLARE_BUILD_MINUTES_CAP: u64 = 3000;
pub(crate) const CLOUDFLARE_CONCURRENT_BUILDS_CAP: u64 = 1;
pub(crate) const GITHUB_CACHE_CAP_BYTES: u64 = 10 * 1024 * 1024 * 1024;
const MAX_PAGES: u32 = 20;
const MAX_RUNS_PER_REPO: usize = 300;

// The documented permission for each path (named in a 403/404, never guessed).
const PERM_CF_SCRIPTS: &str = "Workers Scripts: Read";
const PERM_CF_BUILDS: &str = "Workers Builds Configuration: Read";
const PERM_GH_ACTIONS: &str = "Actions: Read";
const PERM_GH_PLAN: &str = "Plan: Read";

/// `TILLANDSIAS_GITHUB_API_BASE_URL` overrides the GitHub API for a fake; the
/// host process's environment is not forge-writable.
pub(crate) fn github_api_base_url() -> String {
    std::env::var("TILLANDSIAS_GITHUB_API_BASE_URL")
        .unwrap_or_else(|_| GITHUB_API_DEFAULT.to_string())
}

pub(crate) fn descriptor() -> Value {
    json!({
        "name": TOOL_NAME,
        "description": "Read-only. Reports, per provider, used vs the free-tier cap for a calendar month (default: this month): Cloudflare Workers Builds minutes vs 3,000/month, GitHub Actions cache bytes vs 10 GiB per repo, GitHub Actions run minutes, and GitHub billing usage. Each metric names its source API path(s) and as_of. A metric the stored grants cannot read says `unavailable: permission-missing:<provider>:<permission>`, never zero. Call it before a merge to main or a deploy.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "provider": { "type": "string", "enum": ["github", "cloudflare"] },
                "year": { "type": "integer", "minimum": 2020, "maximum": 2100 },
                "month": { "type": "integer", "minimum": 1, "maximum": 12 }
            }
        }
    })
}

/// What the call needs from the host.
pub(crate) struct Deps<'a> {
    pub http: &'a dyn HttpClient,
    pub cf_store: &'a dyn CloudflareTokenStore,
    pub cf_freshen: &'a dyn Fn() -> Result<(), String>,
    pub gh_store: &'a dyn GitHubTokenStore,
    pub cf_api_base: &'a str,
    pub gh_api_base: &'a str,
    pub now: DateTime<Utc>,
}

#[derive(Clone, Copy)]
struct Period {
    year: i32,
    month: u32,
    start: DateTime<Utc>,
    end: DateTime<Utc>,
}

impl Period {
    fn new(year: i32, month: u32) -> Option<Self> {
        let first = NaiveDate::from_ymd_opt(year, month, 1)?;
        let next = if month == 12 {
            NaiveDate::from_ymd_opt(year + 1, 1, 1)?
        } else {
            NaiveDate::from_ymd_opt(year, month + 1, 1)?
        };
        Some(Self {
            year,
            month,
            start: Utc.from_utc_datetime(&first.and_hms_opt(0, 0, 0)?),
            end: Utc.from_utc_datetime(&next.and_hms_opt(0, 0, 0)?),
        })
    }
    fn json(&self) -> Value {
        json!({ "year": self.year, "month": self.month })
    }
    fn last_day(&self) -> NaiveDate {
        (self.end - chrono::Duration::days(1)).date_naive()
    }
}

/// Serve one `tools/call` of `cloud.usage`. `Err` is a refusal (bad
/// arguments only); a provider that cannot be read is a metric status.
pub(crate) fn call(
    deps: &Deps,
    args: Option<&serde_json::Map<String, Value>>,
) -> Result<Value, String> {
    let mut provider: Option<&str> = None;
    let mut year = deps.now.year();
    let mut month = deps.now.month();
    if let Some(args) = args {
        for (k, v) in args {
            match k.as_str() {
                "provider" => match v.as_str() {
                    Some(p @ ("github" | "cloudflare")) => provider = Some(p),
                    _ => return Err(refusal("invalid-argument:provider")),
                },
                "year" => {
                    year = v
                        .as_i64()
                        .filter(|y| (2020..=2100).contains(y))
                        .ok_or_else(|| refusal("invalid-argument:year"))?
                        as i32
                }
                "month" => {
                    month = v
                        .as_u64()
                        .filter(|m| (1..=12).contains(m))
                        .ok_or_else(|| refusal("invalid-argument:month"))?
                        as u32
                }
                _ => return Err(refusal("unknown-argument")),
            }
        }
    }
    let period = Period::new(year, month).ok_or_else(|| refusal("invalid-argument:month"))?;
    let as_of = deps.now.to_rfc3339_opts(SecondsFormat::Secs, true);
    let mut secrets: Vec<String> = Vec::new();
    let mut providers = Vec::new();
    if provider.is_none_or(|p| p == "github") {
        providers.extend(github(deps, &period, &as_of, &mut secrets));
    }
    if provider.is_none_or(|p| p == "cloudflare") {
        providers.push(cloudflare(deps, &period, &as_of, &mut secrets));
    }
    let out = json!({
        "tool": TOOL_NAME,
        "period": period.json(),
        "as_of": as_of,
        "providers": providers,
    });
    let refs: Vec<&str> = secrets.iter().map(String::as_str).collect();
    serde_json::from_str(&cloudflare_mcp::redact(&out.to_string(), &refs))
        .map_err(|_| refusal("response-unusable"))
}

fn refusal(reason: &str) -> String {
    format!(
        "refused:cloud-usage:{reason}\n  why: cloud.usage takes only provider (github|cloudflare), year and month\n  remedy: call it with no arguments for this month"
    )
}

fn metric(
    provider: &str,
    name: &str,
    unit: &str,
    cap: Option<u64>,
    period: &Period,
    as_of: &str,
) -> Value {
    json!({
        "provider": provider,
        "metric": name,
        "used": Value::Null,
        "cap": cap,
        "unit": unit,
        "period": period.json(),
        "source": [],
        "as_of": as_of,
        "status": "ok",
    })
}

fn unavailable(m: &mut Value, reason: String) {
    m["used"] = Value::Null;
    m["status"] = format!("unavailable: {reason}").into();
}

fn parse_time(v: &Value) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(v.as_str()?)
        .ok()
        .map(|t| t.with_timezone(&Utc))
}

// ── Cloudflare ──────────────────────────────────────────────────────────────

fn cloudflare(deps: &Deps, period: &Period, as_of: &str, secrets: &mut Vec<String>) -> Value {
    let mut m = metric(
        "cloudflare",
        "workers_builds_minutes",
        "minutes",
        Some(CLOUDFLARE_BUILD_MINUTES_CAP),
        period,
        as_of,
    );
    m["concurrent_cap"] = CLOUDFLARE_CONCURRENT_BUILDS_CAP.into();
    m["source"] = json!([
        "GET /accounts/{account}/workers/scripts",
        "GET /accounts/{account}/builds/workers/{script_tag}/builds?page=N"
    ]);
    let cf = cloudflare_mcp::Deps {
        http: deps.http,
        store: deps.cf_store,
        freshen: deps.cf_freshen,
        api_base: deps.cf_api_base,
    };
    let (token, refresh, account) = match cloudflare_mcp::signed_in(&cf) {
        Ok(t) => t,
        Err(e) => {
            unavailable(&mut m, format!("cloudflare:{e}"));
            return m;
        }
    };
    secrets.push(token.clone());
    if let Some(r) = refresh {
        secrets.push(r);
    }
    let base = deps.cf_api_base.trim_end_matches('/');
    let get = |path: &str, scope: &str, perm: &str| -> Result<Value, String> {
        let resp = cloudflare_mcp::send(deps.http, Method::Get, &format!("{base}{path}"), &token)?;
        match resp.status {
            403 | 404 => Err(format!("permission-missing:cloudflare:{perm}")),
            _ => cloudflare_mcp::interpret(&resp, scope).map_err(|e| format!("cloudflare:{e}")),
        }
    };
    let scripts = match get(
        &format!("/accounts/{account}/workers/scripts"),
        "workers-scripts.metadata_read",
        PERM_CF_SCRIPTS,
    ) {
        Ok(v) => v,
        Err(e) => {
            unavailable(&mut m, e);
            return m;
        }
    };
    let tags: Vec<(String, String)> = scripts["result"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|s| {
                    let tag = s["tag"].as_str()?;
                    tag.chars()
                        .all(|c| c.is_ascii_alphanumeric())
                        .then(|| (s["id"].as_str().unwrap_or(tag).to_string(), tag.to_string()))
                })
                .collect()
        })
        .unwrap_or_default();
    let mut total_secs: i64 = 0;
    let mut builds_counted = 0u64;
    let mut in_progress = 0u64;
    let mut per_worker = serde_json::Map::new();
    for (name, tag) in &tags {
        let mut worker_secs = 0i64;
        for page in 1..=MAX_PAGES {
            let v = match get(
                &format!("/accounts/{account}/builds/workers/{tag}/builds?page={page}"),
                "workers-ci.read",
                PERM_CF_BUILDS,
            ) {
                Ok(v) => v,
                Err(e) => {
                    if e.starts_with("permission-missing:") {
                        m["refusal"] =
                            "refused:cloudflare-mcp:scope-missing:workers-ci.read".into();
                        m["remedy"] = "ask the operator to add the scope to the Tillandsias client and sign in again with `tillandsias --cloudflare-login`".into();
                    }
                    unavailable(&mut m, e);
                    return m;
                }
            };
            let builds = v["result"].as_array().cloned().unwrap_or_default();
            if builds.is_empty() {
                break;
            }
            // The list is not ordered by created_on (measured live 2026-11-02), so a
            // page stops the walk only when EVERY build on it predates the month.
            let mut all_older = true;
            for b in &builds {
                let Some(created) = parse_time(&b["created_on"]) else {
                    continue;
                };
                if created >= period.start {
                    all_older = false;
                }
                if created < period.start {
                    continue;
                }
                if created >= period.end {
                    continue;
                }
                match parse_time(&b["stopped_on"]).or_else(|| parse_time(&b["completed_on"])) {
                    Some(end) if end >= created => {
                        worker_secs += (end - created).num_seconds();
                        builds_counted += 1;
                    }
                    _ => in_progress += 1,
                }
            }
            let total_pages = v["result_info"]["total_pages"].as_u64();
            if all_older || total_pages.is_some_and(|t| u64::from(page) >= t) {
                break;
            }
        }
        total_secs += worker_secs;
        per_worker.insert(
            name.clone(),
            json!((worker_secs as f64 / 60.0 * 10.0).round() / 10.0),
        );
    }
    m["used"] = json!((total_secs as f64 / 60.0 * 10.0).round() / 10.0);
    m["builds_counted"] = builds_counted.into();
    m["builds_in_progress"] = in_progress.into();
    m["per_worker"] = Value::Object(per_worker);
    m["note"] = "summed (end − created_on) per build; Cloudflare exposes no usage endpoint".into();
    m
}

// ── GitHub ──────────────────────────────────────────────────────────────────

enum GhErr {
    Permission,
    Other(String),
}

fn github(deps: &Deps, period: &Period, as_of: &str, secrets: &mut Vec<String>) -> Vec<Value> {
    let mut out = Vec::new();
    let mut cache: Vec<Value> = GITHUB_REPOS
        .iter()
        .map(|r| {
            let mut m = metric(
                "github",
                "actions_cache_bytes",
                "bytes",
                Some(GITHUB_CACHE_CAP_BYTES),
                period,
                as_of,
            );
            m["repo"] = (*r).into();
            m["source"] = json!([format!("GET /repos/{r}/actions/cache/usage")]);
            m
        })
        .collect();
    let mut runs: Vec<Value> = GITHUB_REPOS
        .iter()
        .map(|r| {
            let mut m = metric(
                "github",
                "actions_run_minutes",
                "minutes",
                None,
                period,
                as_of,
            );
            m["repo"] = (*r).into();
            m["note"] = "public repo: hosted-runner minutes not billed".into();
            m["source"] = json!([
                format!("GET /repos/{r}/actions/runs?created=<period>"),
                format!("GET /repos/{r}/actions/runs/{{run_id}}/timing")
            ]);
            m
        })
        .collect();
    let mut billing = metric("github", "billing_usage", "quantity", None, period, as_of);
    billing["source"] = json!([
        "GET /user",
        "GET /users/{username}/settings/billing/usage?year=&month="
    ]);

    let token = if !crate::vault_bootstrap::cloudflare_token_endpoint_is_safe(deps.gh_api_base) {
        Err("github:api-base-not-https".to_string())
    } else {
        match deps.gh_store.read_bundle() {
            Ok(Some(b)) if !b.token.is_empty() => {
                if let Some(r) = b.refresh_token.clone() {
                    secrets.push(r);
                }
                Ok(b.token)
            }
            Ok(_) => Err("github:not-signed-in".to_string()),
            Err(e) => Err(format!("github:store:{}", fixed_word(&e))),
        }
    };
    let token = match token {
        Ok(t) => t,
        Err(e) => {
            for m in cache
                .iter_mut()
                .chain(runs.iter_mut())
                .chain(std::iter::once(&mut billing))
            {
                unavailable(m, e.clone());
            }
            out.extend(cache);
            out.extend(runs);
            out.push(billing);
            return out;
        }
    };
    secrets.push(token.clone());
    let base = deps.gh_api_base.trim_end_matches('/');
    let get = |path: &str| -> Result<Value, GhErr> {
        let resp = deps
            .http
            .get_with_bearer(&format!("{base}{path}"), &token)
            .map_err(|_| GhErr::Other("github:transport".into()))?;
        match resp.status {
            200..=299 => serde_json::from_str(&resp.body)
                .map_err(|_| GhErr::Other("github:response-unusable".into())),
            401 => Err(GhErr::Other("github:unauthorized".into())),
            403 | 404 => Err(GhErr::Permission),
            429 => Err(GhErr::Other("github:rate-limited".into())),
            s => Err(GhErr::Other(format!("github:http-{s}"))),
        }
    };
    let reason = |e: GhErr, perm: &str| match e {
        GhErr::Permission => format!("permission-missing:github:{perm}"),
        GhErr::Other(s) => s,
    };

    for (i, repo) in GITHUB_REPOS.iter().enumerate() {
        match get(&format!("/repos/{repo}/actions/cache/usage")) {
            Ok(v) => match v["active_caches_size_in_bytes"].as_u64() {
                Some(b) => {
                    cache[i]["used"] = b.into();
                    cache[i]["active_caches_count"] = v["active_caches_count"].clone();
                }
                None => unavailable(&mut cache[i], "github:response-unusable".into()),
            },
            Err(e) => unavailable(&mut cache[i], reason(e, PERM_GH_ACTIONS)),
        }
        let range = format!("{}..{}", period.start.date_naive(), period.last_day());
        let mut ids = Vec::new();
        let mut failed = None;
        for page in 1..=MAX_PAGES {
            match get(&format!(
                "/repos/{repo}/actions/runs?created={range}&per_page=100&page={page}"
            )) {
                Ok(v) => {
                    let list = v["workflow_runs"].as_array().cloned().unwrap_or_default();
                    ids.extend(list.iter().filter_map(|r| r["id"].as_u64()));
                    let total = v["total_count"].as_u64().unwrap_or(0) as usize;
                    if list.is_empty() || ids.len() >= total || ids.len() >= MAX_RUNS_PER_REPO {
                        break;
                    }
                }
                Err(e) => {
                    failed = Some(reason(e, PERM_GH_ACTIONS));
                    break;
                }
            }
        }
        if let Some(e) = failed {
            unavailable(&mut runs[i], e);
            continue;
        }
        let truncated = ids.len() > MAX_RUNS_PER_REPO;
        ids.truncate(MAX_RUNS_PER_REPO);
        let mut ms: u64 = 0;
        for id in &ids {
            match get(&format!("/repos/{repo}/actions/runs/{id}/timing")) {
                Ok(v) => ms += v["run_duration_ms"].as_u64().unwrap_or(0),
                Err(e) => {
                    failed = Some(reason(e, PERM_GH_ACTIONS));
                    break;
                }
            }
        }
        if let Some(e) = failed {
            unavailable(&mut runs[i], e);
            continue;
        }
        runs[i]["used"] = json!((ms as f64 / 60_000.0 * 10.0).round() / 10.0);
        runs[i]["runs_counted"] = ids.len().into();
        if truncated {
            runs[i]["truncated_at_runs"] = MAX_RUNS_PER_REPO.into();
        }
    }

    match get("/user") {
        Ok(u) => match u["login"].as_str().filter(|l| {
            !l.is_empty()
                && l.len() <= 39
                && l.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
        }) {
            Some(login) => {
                billing["user"] = login.into();
                match get(&format!(
                    "/users/{login}/settings/billing/usage?year={}&month={}",
                    period.year, period.month
                )) {
                    Ok(v) => {
                        let mut per = serde_json::Map::new();
                        let mut total = 0f64;
                        let mut net = 0f64;
                        for item in v["usageItems"].as_array().into_iter().flatten() {
                            let key = format!(
                                "{}/{}",
                                item["product"].as_str().unwrap_or("?"),
                                item["sku"].as_str().unwrap_or("?")
                            );
                            let q = item["quantity"].as_f64().unwrap_or(0.0);
                            total += q;
                            net += item["netAmount"].as_f64().unwrap_or(0.0);
                            let e = per.entry(key).or_insert(json!(0.0));
                            *e = json!(e.as_f64().unwrap_or(0.0) + q);
                        }
                        billing["used"] = json!(total);
                        billing["per_product_sku"] = Value::Object(per);
                        billing["net_amount_usd"] = json!(net);
                    }
                    Err(e) => unavailable(&mut billing, reason(e, PERM_GH_PLAN)),
                }
            }
            None => unavailable(&mut billing, "github:response-unusable".into()),
        },
        Err(GhErr::Permission) => unavailable(
            &mut billing,
            format!("permission-missing:github:{PERM_GH_PLAN}"),
        ),
        Err(GhErr::Other(e)) => unavailable(&mut billing, e),
    }
    out.extend(cache);
    out.extend(runs);
    out.push(billing);
    out
}

fn fixed_word(s: &str) -> String {
    let w: String = s
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || "-_.:".contains(*c))
        .take(60)
        .collect();
    if w.is_empty() {
        "unclassified".into()
    } else {
        w
    }
}

/// The live dependencies: Vault, the Cloudflare rotation path, reqwest.
pub(crate) fn call_live(
    args: Option<&serde_json::Map<String, Value>>,
    debug: bool,
) -> Result<Value, String> {
    let http = crate::cloudflare_oauth::ReqwestHttpClient::default();
    let cf_store = crate::vault_bootstrap::VaultCloudflareTokenStore { debug };
    let gh_store = crate::vault_bootstrap::VaultGitHubTokenStore { debug };
    let freshen = || crate::vault_bootstrap::cloudflare_token_due_check_live(debug).map(|_| ());
    let cf_api_base = cloudflare_mcp::api_base_url();
    let gh_api_base = github_api_base_url();
    let deps = Deps {
        http: &http,
        cf_store: &cf_store,
        cf_freshen: &freshen,
        gh_store: &gh_store,
        cf_api_base: &cf_api_base,
        gh_api_base: &gh_api_base,
        now: Utc::now(),
    };
    call(&deps, args)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault_bootstrap::{CloudflareTokenBundle, GitHubTokenBundle};
    use std::io::{BufRead, BufReader, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex};

    const CF_TOKEN: &str = concat!("cf-access-", "SECRET-47vt");
    const GH_TOKEN: &str = concat!("ghu_", "SECRET47vt");
    const ACCOUNT: &str = "0123456789abcdef0123456789abcdef";

    type Route = Box<dyn Fn(&str) -> (u16, String) + Send + Sync>;

    /// A stub HTTP server on loopback: answers by path, records each request
    /// line and Authorization header.
    struct Stub {
        base: String,
        seen: Arc<Mutex<Vec<(String, String)>>>,
    }

    fn stub(route: Route) -> Stub {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let seen2 = seen.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(mut stream) = stream else { continue };
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    continue;
                }
                let mut auth = String::new();
                loop {
                    let mut h = String::new();
                    if reader.read_line(&mut h).unwrap_or(0) == 0 || h == "\r\n" {
                        break;
                    }
                    if h.to_ascii_lowercase().starts_with("authorization:") {
                        auth = h.trim().to_string();
                    }
                }
                let mut parts = line.split_whitespace();
                let method = parts.next().unwrap_or("").to_string();
                let path = parts.next().unwrap_or("").to_string();
                seen2
                    .lock()
                    .unwrap()
                    .push((format!("{method} {path}"), auth));
                let (code, body) = if method == "GET" {
                    route(&path)
                } else {
                    (405, String::new())
                };
                let _ = write!(
                    stream,
                    "HTTP/1.1 {code} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                );
            }
        });
        Stub { base, seen }
    }

    struct Cf;
    impl CloudflareTokenStore for Cf {
        fn read_bundle(&self) -> Result<Option<CloudflareTokenBundle>, String> {
            Ok(Some(CloudflareTokenBundle {
                access_token: CF_TOKEN.into(),
                account_id: Some(ACCOUNT.into()),
                client_id: "c".into(),
                ..Default::default()
            }))
        }
        fn write_record(&self, _: &str, _: Value) -> Result<(), String> {
            Err("no".into())
        }
        fn delete_record(&self, _: &str) -> Result<(), String> {
            Err("no".into())
        }
    }

    struct Gh;
    impl GitHubTokenStore for Gh {
        fn read_bundle(&self) -> Result<Option<GitHubTokenBundle>, String> {
            Ok(Some(GitHubTokenBundle {
                token: GH_TOKEN.into(),
                ..Default::default()
            }))
        }
        fn write_record(&self, _: &str, _: Value) -> Result<(), String> {
            Err("no".into())
        }
    }

    fn cf_ok(result: Value, total_pages: u64) -> (u16, String) {
        (
            200,
            json!({"success": true, "errors": [], "result": result,
                   "result_info": {"page": 1, "total_pages": total_pages}})
            .to_string(),
        )
    }

    fn cloudflare_stub() -> Stub {
        stub(Box::new(|path: &str| {
            let p = path.trim_start_matches("/client/v4");
            if p == format!("/accounts/{ACCOUNT}/workers/scripts") {
                return cf_ok(json!([{"id": "macron-dev", "tag": "abc123"}]), 1);
            }
            if p == format!("/accounts/{ACCOUNT}/builds/workers/abc123/builds?page=1") {
                // Three builds in November 2026 (10 + 5 + 2.5 min), one in October.
                return cf_ok(
                    json!([
                        {"created_on": "2026-11-02T10:00:00Z", "stopped_on": "2026-11-02T10:10:00Z"},
                        {"created_on": "2026-10-31T23:00:00Z", "stopped_on": "2026-10-31T23:40:00Z"},
                        {"created_on": "2026-11-01T09:00:00Z", "stopped_on": "2026-11-01T09:05:00Z"},
                        {"created_on": "2026-11-01T00:00:00Z", "completed_on": "2026-11-01T00:02:30Z"}
                    ]),
                    1,
                );
            }
            (404, "{}".into())
        }))
    }

    fn github_stub(billing_status: u16) -> Stub {
        stub(Box::new(move |path: &str| {
            let body = |v: Value| (200, v.to_string());
            match path {
                "/repos/8007342/tillandsias/actions/cache/usage" => body(json!({
                    "full_name": "8007342/tillandsias",
                    "active_caches_size_in_bytes": 2_147_483_648u64,
                    "active_caches_count": 7
                })),
                "/repos/8007342/macron.dev/actions/cache/usage" => body(json!({
                    "active_caches_size_in_bytes": 0, "active_caches_count": 0
                })),
                p if p.starts_with(
                    "/repos/8007342/tillandsias/actions/runs?created=2026-11-01..2026-11-30",
                ) =>
                {
                    body(json!({"total_count": 2, "workflow_runs": [{"id": 11}, {"id": 12}]}))
                }
                p if p.starts_with("/repos/8007342/macron.dev/actions/runs?") => {
                    body(json!({"total_count": 0, "workflow_runs": []}))
                }
                "/repos/8007342/tillandsias/actions/runs/11/timing" => {
                    body(json!({"run_duration_ms": 600_000}))
                }
                "/repos/8007342/tillandsias/actions/runs/12/timing" => {
                    body(json!({"run_duration_ms": 300_000}))
                }
                "/user" => body(json!({"login": "operator-u"})),
                "/users/operator-u/settings/billing/usage?year=2026&month=11" => {
                    if billing_status == 200 {
                        body(json!({"usageItems": [
                            {"product": "actions", "sku": "linux", "quantity": 15.0, "netAmount": 0.0},
                            {"product": "actions", "sku": "linux", "quantity": 5.0, "netAmount": 0.0}
                        ]}))
                    } else {
                        (
                            billing_status,
                            json!({"message": "Resource not accessible by integration"})
                                .to_string(),
                        )
                    }
                }
                _ => (404, "{}".into()),
            }
        }))
    }

    fn run(cf: &Stub, gh: &Stub) -> Value {
        let http = crate::cloudflare_oauth::ReqwestHttpClient::default();
        let freshen = || Ok(());
        let cf_base = format!("{}/client/v4", cf.base);
        let deps = Deps {
            http: &http,
            cf_store: &Cf,
            cf_freshen: &freshen,
            gh_store: &Gh,
            cf_api_base: &cf_base,
            gh_api_base: &gh.base,
            now: Utc.with_ymd_and_hms(2026, 11, 2, 18, 0, 0).unwrap(),
        };
        call(&deps, None).expect("cloud.usage answers")
    }

    fn find<'a>(v: &'a Value, provider: &str, metric: &str, repo: Option<&str>) -> &'a Value {
        v["providers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| {
                m["provider"] == provider
                    && m["metric"] == metric
                    && repo.is_none_or(|r| m["repo"] == r)
            })
            .unwrap_or_else(|| panic!("no {provider}/{metric} in {v}"))
    }

    #[test]
    fn cloud_usage_returns_per_provider_used_and_cap() {
        let cf = cloudflare_stub();
        let gh = github_stub(200);
        let v = run(&cf, &gh);

        let c = find(&v, "cloudflare", "workers_builds_minutes", None);
        assert_eq!(c["used"], json!(17.5), "the in-month sum only: {c}");
        assert_eq!(c["cap"], 3000);
        assert_eq!(c["concurrent_cap"], 1);
        assert_eq!(c["status"], "ok");
        assert_eq!(c["period"], json!({"year": 2026, "month": 11}));
        assert_eq!(c["as_of"], "2026-11-02T18:00:00Z");
        assert!(
            c["source"]
                .to_string()
                .contains("/builds/workers/{script_tag}/builds"),
            "{c}"
        );

        let cache = find(
            &v,
            "github",
            "actions_cache_bytes",
            Some("8007342/tillandsias"),
        );
        assert_eq!(cache["used"], 2_147_483_648u64);
        assert_eq!(cache["cap"], 10u64 * 1024 * 1024 * 1024);
        assert_eq!(cache["unit"], "bytes");

        let runs = find(
            &v,
            "github",
            "actions_run_minutes",
            Some("8007342/tillandsias"),
        );
        assert_eq!(runs["used"], json!(15.0), "{runs}");
        assert_eq!(runs["cap"], Value::Null, "public repo: not billed");

        let billing = find(&v, "github", "billing_usage", None);
        assert_eq!(billing["used"], json!(20.0), "{billing}");

        // Only GETs reached the stubs; the tokens were headers, never in a
        // path or in the result.
        for s in [&cf, &gh] {
            for (line, _) in s.seen.lock().unwrap().iter() {
                assert!(line.starts_with("GET "), "{line}");
                assert!(!line.contains(CF_TOKEN) && !line.contains(GH_TOKEN));
            }
        }
        assert!(
            cf.seen
                .lock()
                .unwrap()
                .iter()
                .all(|(_, a)| a.contains(CF_TOKEN))
        );
        assert!(
            gh.seen
                .lock()
                .unwrap()
                .iter()
                .all(|(_, a)| a.contains(GH_TOKEN))
        );
        let text = v.to_string();
        assert!(!text.contains(CF_TOKEN) && !text.contains(GH_TOKEN));
    }

    #[test]
    fn cloud_usage_names_the_missing_permission_on_403_not_zero() {
        let cf = cloudflare_stub();
        for code in [403u16, 404] {
            let gh = github_stub(code);
            let v = run(&cf, &gh);
            let billing = find(&v, "github", "billing_usage", None);
            assert_eq!(
                billing["status"], "unavailable: permission-missing:github:Plan: Read",
                "{billing}"
            );
            assert_eq!(
                billing["used"],
                Value::Null,
                "never a guessed zero: {billing}"
            );
            // The other metrics still fill.
            let cache = find(
                &v,
                "github",
                "actions_cache_bytes",
                Some("8007342/tillandsias"),
            );
            assert_eq!(cache["used"], 2_147_483_648u64);
            let c = find(&v, "cloudflare", "workers_builds_minutes", None);
            assert_eq!(c["used"], json!(17.5));
        }
        // A Cloudflare 403 on the builds list names its permission too.
        let cf403 = stub(Box::new(|path: &str| {
            if path.ends_with("/workers/scripts") {
                cf_ok(json!([{"id": "w", "tag": "abc123"}]), 1)
            } else {
                (
                    403,
                    json!({"success": false, "errors": [{"code": 10000}]}).to_string(),
                )
            }
        }));
        let gh = github_stub(200);
        let v = run(&cf403, &gh);
        let c = find(&v, "cloudflare", "workers_builds_minutes", None);
        assert_eq!(
            c["status"],
            "unavailable: permission-missing:cloudflare:Workers Builds Configuration: Read"
        );
        assert_eq!(c["used"], Value::Null);
        assert_eq!(
            c["refusal"],
            "refused:cloudflare-mcp:scope-missing:workers-ci.read"
        );
    }

    /// One live, read-only call against this host's Vault tokens:
    /// `cargo test ... cloud_usage::tests::live_cloud_usage -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn live_cloud_usage() {
        match call_live(None, std::env::var_os("TILLANDSIAS_DEBUG").is_some()) {
            Ok(v) => println!("{}", serde_json::to_string_pretty(&v).unwrap()),
            Err(e) => println!("ERR {e}"),
        }
    }
}

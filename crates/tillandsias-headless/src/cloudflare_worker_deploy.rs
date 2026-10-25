//! Host-side ensure / deploy for a GitHub-connected Cloudflare Worker (order
//! 1853-qr4h).
//!
//! @trace order:1853-qr4h, spec:mcp-tool-socket
//!
//! OPERATOR-APPROVED SCOPE (2026-10-24, in tlatoanis-macbook-air's session,
//! "Approve as scoped"): ensure a Worker exists or find it; connect the GitHub
//! repo ONCE with no build on push; deploy a named revision from the deploy
//! branch only on explicit request; read build status and logs. No generic
//! endpoint or method argument. A second ensure is a no-op. Credentials stay
//! host-side. Anything wider needs a fresh approval.
//!
//! - Every request is one [`Op`]; its method and path template are fixed here.
//!   Only the bound account and validated names and ids are interpolated.
//! - Cloudflare has no documented switch that stops a production-branch push
//!   from building. So the ONE trigger this module creates includes only
//!   `deploy/<worker>`: a push to main or a work
//!   branch matches nothing and builds nothing. The deploy branch moves only
//!   on purpose, and a deploy is a manual build of a named commit on it.
//! - Creating the Worker uploads a placeholder script (no build), and
//!   connecting the repo creates the connection and the trigger (no build).
//! - Results and errors pass through [`redact`] with the bearer token.
//!
//! OPEN (recorded on the 1853 row, not guessed): the Builds API keys a Worker
//! by `external_script_id`. This module reads it as the `tag` the scripts list
//! returns, as the shipped read-only tools (1772-irs3) already do; that is
//! unverified until a live probe with the operator present. The trigger's
//! `build_token_uuid` is likewise an input the caller supplies.

// Wired to the MCP socket in the next slice; until then only the fixture calls in.
#![cfg_attr(not(test), allow(dead_code))]

use crate::cloudflare_mcp::redact;
use crate::cloudflare_oauth::HttpResponse;

/// The closed set of requests this module can make.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Op {
    ScriptsList,
    ScriptUpload,
    TriggersList,
    RepoConnect,
    TriggerCreate,
    ManualBuild,
    BuildGet,
    BuildLogs,
}

impl Op {
    pub(crate) fn method(self) -> &'static str {
        match self {
            Op::ScriptsList | Op::TriggersList | Op::BuildGet | Op::BuildLogs => "GET",
            Op::ScriptUpload | Op::RepoConnect => "PUT",
            Op::TriggerCreate | Op::ManualBuild => "POST",
        }
    }

    fn template(self) -> &'static str {
        match self {
            Op::ScriptsList => "/accounts/{account}/workers/scripts",
            Op::ScriptUpload => "/accounts/{account}/workers/scripts/{worker}",
            Op::TriggersList => "/accounts/{account}/builds/workers/{tag}/triggers",
            Op::RepoConnect => "/accounts/{account}/builds/repos/connections",
            Op::TriggerCreate => "/accounts/{account}/builds/triggers",
            Op::ManualBuild => "/accounts/{account}/builds/triggers/{trigger}/builds",
            Op::BuildGet => "/accounts/{account}/builds/builds/{build}",
            Op::BuildLogs => "/accounts/{account}/builds/builds/{build}/logs",
        }
    }
}

/// One request on the wire. The transport sees only what an [`Op`] built.
pub(crate) struct Request<'a> {
    pub op: Op,
    pub url: String,
    pub bearer: &'a str,
    pub content_type: Option<String>,
    pub body: Option<String>,
}

/// The only way out of this module.
pub(crate) trait Wire {
    fn send(&self, req: &Request) -> Result<HttpResponse, String>;
}

/// The signed-in host session: the bearer and the tray-bound account.
pub(crate) struct Session<'a> {
    pub api_base: &'a str,
    pub account: &'a str,
    pub token: &'a str,
}

/// What a Worker is connected to and how it builds.
#[derive(Clone, Debug)]
pub(crate) struct Spec {
    pub worker: String,
    pub github_owner: String,
    pub github_owner_id: String,
    pub github_repo: String,
    pub github_repo_id: String,
    pub build_token_uuid: String,
    pub root_directory: String,
    pub build_command: String,
    pub deploy_command: String,
}

impl Spec {
    pub(crate) fn deploy_branch(&self) -> String {
        format!("deploy/{}", self.worker)
    }
}

fn name_ok(s: &str, max: usize, extra: &str) -> bool {
    !s.is_empty()
        && s.len() <= max
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || extra.contains(c))
}

fn validate(spec: &Spec) -> Result<(), String> {
    let lower = spec
        .worker
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-');
    if !lower || !name_ok(&spec.worker, 63, "-") {
        return Err("invalid-argument:worker".into());
    }
    for (k, v, max, extra) in [
        ("github_owner", &spec.github_owner, 39, "-"),
        ("github_repo", &spec.github_repo, 100, "-_."),
        ("github_owner_id", &spec.github_owner_id, 20, ""),
        ("github_repo_id", &spec.github_repo_id, 20, ""),
        ("build_token_uuid", &spec.build_token_uuid, 64, "-"),
    ] {
        if !name_ok(v, max, extra) {
            return Err(format!("invalid-argument:{k}"));
        }
    }
    let root_ok = spec.root_directory.is_empty()
        || name_ok(&spec.root_directory, 128, "-_./")
            && !spec.root_directory.split('/').any(|p| p == "..");
    if !root_ok {
        return Err("invalid-argument:root_directory".into());
    }
    for (k, v) in [
        ("build_command", &spec.build_command),
        ("deploy_command", &spec.deploy_command),
    ] {
        if v.len() > 256 || v.chars().any(char::is_control) {
            return Err(format!("invalid-argument:{k}"));
        }
    }
    Ok(())
}

fn url(s: &Session, op: Op, fill: &[(&str, &str)]) -> String {
    let mut path = op.template().replace("{account}", s.account);
    for (k, v) in fill {
        path = path.replace(&format!("{{{k}}}"), v);
    }
    format!("{}{path}", s.api_base.trim_end_matches('/'))
}

fn call(
    wire: &dyn Wire,
    s: &Session,
    op: Op,
    fill: &[(&str, &str)],
    query: Option<String>,
    body: Option<(String, String)>,
) -> Result<serde_json::Value, String> {
    let mut u = url(s, op, fill);
    if let Some(q) = query {
        u = format!("{u}?{q}");
    }
    let (content_type, body) = match body {
        Some((ct, b)) => (Some(ct), Some(b)),
        None => (None, None),
    };
    let resp = wire.send(&Request {
        op,
        url: u,
        bearer: s.token,
        content_type,
        body,
    })?;
    match resp.status {
        200..=299 => {}
        401 => return Err("unauthorized".into()),
        403 => return Err("scope-missing:workers-ci.write".into()),
        404 => return Err("not-found".into()),
        429 => return Err("rate-limited".into()),
        st => return Err(format!("http-{st}")),
    }
    let v: serde_json::Value =
        serde_json::from_str(&resp.body).map_err(|_| "response-unusable".to_string())?;
    if v.get("success").and_then(serde_json::Value::as_bool) != Some(true) {
        return Err("response-unusable".into());
    }
    Ok(v.get("result").cloned().unwrap_or(serde_json::Value::Null))
}

fn json_body(v: serde_json::Value) -> Option<(String, String)> {
    Some(("application/json".into(), v.to_string()))
}

/// A Worker that answers 503 until the first deploy replaces it.
fn placeholder_upload() -> (String, String) {
    let boundary = "tillandsias-1853-placeholder";
    let body = format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"metadata\"\r\nContent-Type: application/json\r\n\r\n{}\r\n\
         --{boundary}\r\nContent-Disposition: form-data; name=\"worker.js\"; filename=\"worker.js\"\r\nContent-Type: application/javascript+module\r\n\r\n{}\r\n\
         --{boundary}--\r\n",
        serde_json::json!({"main_module": "worker.js", "compatibility_date": "2026-01-01"}),
        "export default { fetch() { return new Response('not deployed yet', { status: 503 }); } };",
    );
    (format!("multipart/form-data; boundary={boundary}"), body)
}

fn str_list(v: &serde_json::Value, key: &str) -> Vec<String> {
    v.get(key)
        .and_then(serde_json::Value::as_array)
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

/// Is this trigger the deploy-branch-only one this module creates?
fn deploy_only(t: &serde_json::Value, branch: &str) -> bool {
    str_list(t, "branch_includes") == [branch.to_string()]
}

/// What an ensure did: each step either `created` or `found`.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Ensured {
    pub worker: &'static str,
    pub trigger: &'static str,
    pub trigger_uuid: String,
    pub deploy_branch: String,
}

fn ensure_inner(wire: &dyn Wire, s: &Session, spec: &Spec) -> Result<Ensured, String> {
    validate(spec)?;
    let branch = spec.deploy_branch();
    let find_tag = |wire: &dyn Wire| -> Result<Option<String>, String> {
        let scripts = call(wire, s, Op::ScriptsList, &[], None, None)?;
        Ok(scripts
            .as_array()
            .into_iter()
            .flatten()
            .find(|w| w["id"].as_str() == Some(spec.worker.as_str()))
            .and_then(|w| w["tag"].as_str().map(str::to_string)))
    };
    let (worker, tag) = match find_tag(wire)? {
        Some(tag) => ("found", tag),
        None => {
            let up = placeholder_upload();
            let made = call(
                wire,
                s,
                Op::ScriptUpload,
                &[("worker", &spec.worker)],
                None,
                Some(up),
            )?;
            let tag = made["tag"]
                .as_str()
                .map(str::to_string)
                .ok_or("external-script-id-unresolved")?;
            ("created", tag)
        }
    };
    if !name_ok(&tag, 64, "-") {
        return Err("external-script-id-unresolved".into());
    }
    let triggers = call(wire, s, Op::TriggersList, &[("tag", &tag)], None, None)?;
    let triggers = triggers.as_array().cloned().unwrap_or_default();
    if let Some(t) = triggers.iter().find(|t| deploy_only(t, &branch)) {
        let uuid = t["trigger_uuid"].as_str().ok_or("response-unusable")?;
        if triggers.len() > 1 {
            return Err("other-trigger-present".into());
        }
        return Ok(Ensured {
            worker,
            trigger: "found",
            trigger_uuid: uuid.to_string(),
            deploy_branch: branch,
        });
    }
    if !triggers.is_empty() {
        // Someone else's trigger may build on push. Changing it is outside
        // the approved scope; say so instead.
        return Err("other-trigger-present".into());
    }
    let conn = call(
        wire,
        s,
        Op::RepoConnect,
        &[],
        None,
        json_body(serde_json::json!({
            "provider_type": "github",
            "provider_account_id": spec.github_owner_id,
            "provider_account_name": spec.github_owner,
            "repo_id": spec.github_repo_id,
            "repo_name": spec.github_repo,
        })),
    )?;
    let conn_uuid = conn["repo_connection_uuid"]
        .as_str()
        .ok_or("response-unusable")?
        .to_string();
    let made = call(
        wire,
        s,
        Op::TriggerCreate,
        &[],
        None,
        json_body(serde_json::json!({
            "trigger_name": format!("explicit deploy from {branch}"),
            "external_script_id": tag,
            "repo_connection_uuid": conn_uuid,
            "build_token_uuid": spec.build_token_uuid,
            "branch_includes": [branch],
            "branch_excludes": [],
            "path_includes": ["*"],
            "path_excludes": [],
            "root_directory": spec.root_directory,
            "build_command": spec.build_command,
            "deploy_command": spec.deploy_command,
            "build_caching_enabled": false,
        })),
    )?;
    let uuid = made["trigger_uuid"].as_str().ok_or("response-unusable")?;
    Ok(Ensured {
        worker,
        trigger: "created",
        trigger_uuid: uuid.to_string(),
        deploy_branch: branch,
    })
}

fn out<T>(
    r: Result<T, String>,
    s: &Session,
    ok: impl Fn(T) -> serde_json::Value,
) -> Result<serde_json::Value, String> {
    match r {
        Ok(v) => {
            let text = redact(&ok(v).to_string(), &[s.token]);
            serde_json::from_str(&text)
                .map_err(|_| "refused:cloudflare-worker:response-unusable".into())
        }
        Err(e) => Err(redact(
            &format!("refused:cloudflare-worker:{e}"),
            &[s.token],
        )),
    }
}

/// Create or find the Worker and its deploy-branch-only trigger. A second call
/// changes nothing and starts nothing.
pub(crate) fn ensure(
    wire: &dyn Wire,
    s: &Session,
    spec: &Spec,
) -> Result<serde_json::Value, String> {
    out(ensure_inner(wire, s, spec), s, |e| {
        serde_json::json!({
            "worker": e.worker,
            "trigger": e.trigger,
            "trigger_uuid": e.trigger_uuid,
            "deploy_branch": e.deploy_branch,
            "builds_started": 0,
        })
    })
}

fn sha_ok(s: &str) -> bool {
    s.len() == 40
        && s.chars()
            .all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase())
}

/// Build and deploy `revision`, which must be the deploy branch's head as the
/// host sees it (`deploy_head`). Nothing else starts a build.
pub(crate) fn deploy(
    wire: &dyn Wire,
    s: &Session,
    spec: &Spec,
    revision: &str,
    deploy_head: &dyn Fn(&str) -> Result<String, String>,
) -> Result<serde_json::Value, String> {
    let r = (|| {
        if !sha_ok(revision) {
            return Err("invalid-argument:revision".to_string());
        }
        let branch = spec.deploy_branch();
        if deploy_head(&branch)? != revision {
            return Err("revision-not-deploy-branch-head".into());
        }
        let e = ensure_inner(wire, s, spec)?;
        let b = call(
            wire,
            s,
            Op::ManualBuild,
            &[("trigger", &e.trigger_uuid)],
            None,
            json_body(serde_json::json!({"branch": branch, "commit_hash": revision})),
        )?;
        let id = b["build_uuid"].as_str().ok_or("response-unusable")?;
        Ok(serde_json::json!({
            "build_uuid": id,
            "status": b["status"],
            "branch": branch,
            "commit_hash": revision,
        }))
    })();
    out(r, s, |v| v)
}

fn build_id_ok(id: &str) -> Result<(), String> {
    if name_ok(id, 64, "-") {
        Ok(())
    } else {
        Err("invalid-argument:build_uuid".into())
    }
}

/// One build's status and outcome.
pub(crate) fn status(
    wire: &dyn Wire,
    s: &Session,
    build: &str,
) -> Result<serde_json::Value, String> {
    let r = build_id_ok(build).and_then(|_| {
        let b = call(wire, s, Op::BuildGet, &[("build", build)], None, None)?;
        Ok(serde_json::json!({
            "build_uuid": build,
            "status": b["status"],
            "build_outcome": b["build_outcome"],
        }))
    });
    out(r, s, |v| v)
}

const LOG_PAGES_MAX: usize = 50;

/// A build's whole log, following the cursor while it is truncated.
pub(crate) fn logs(wire: &dyn Wire, s: &Session, build: &str) -> Result<serde_json::Value, String> {
    let r = build_id_ok(build).and_then(|_| {
        let mut lines = Vec::new();
        let mut cursor: Option<String> = None;
        for _ in 0..LOG_PAGES_MAX {
            let q = cursor.as_ref().map(|c| {
                let enc: String = c
                    .bytes()
                    .map(|b| {
                        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                            (b as char).to_string()
                        } else {
                            format!("%{b:02X}")
                        }
                    })
                    .collect();
                format!("cursor={enc}")
            });
            let page = call(wire, s, Op::BuildLogs, &[("build", build)], q, None)?;
            lines.extend(page["lines"].as_array().cloned().unwrap_or_default());
            let more = page["truncated"].as_bool() == Some(true);
            match page["cursor"].as_str() {
                Some(c) if more => cursor = Some(c.to_string()),
                _ => return Ok(serde_json::json!({"build_uuid": build, "lines": lines, "truncated": false})),
            }
        }
        Ok(serde_json::json!({"build_uuid": build, "lines": lines, "truncated": true}))
    });
    out(r, s, |v| v)
}

#[cfg(test)]
mod tests {
    //! The 1853 fixture: a stateful fake of the Workers + Builds API that
    //! models which pushes build, driven through this module's tools.
    use super::*;
    use std::cell::RefCell;

    const TOKEN: &str = "cf-test-bearer-0123456789abcdef";
    const ACCT: &str = "0123456789abcdef0123456789abcdef";

    #[derive(Default)]
    struct Fake {
        scripts: Vec<(String, String)>,
        connections: Vec<String>,
        triggers: Vec<serde_json::Value>,
        builds: Vec<serde_json::Value>,
        log: Vec<(Op, String)>,
        bodies: Vec<String>,
    }

    struct Api(RefCell<Fake>);

    fn ok(v: serde_json::Value) -> Result<HttpResponse, String> {
        Ok(HttpResponse {
            status: 200,
            body: serde_json::json!({"success": true, "errors": [], "result": v}).to_string(),
        })
    }

    fn glob(pat: &str, s: &str) -> bool {
        pat == "*" || pat == s || pat.strip_suffix('*').is_some_and(|p| s.starts_with(p))
    }

    impl Api {
        fn new() -> Self {
            Api(RefCell::new(Fake::default()))
        }

        /// GitHub delivers a push: every trigger whose branch filters match
        /// starts a build, as Workers Builds does.
        fn push(&self, branch: &str, sha: &str) {
            let mut f = self.0.borrow_mut();
            let hits: Vec<String> = f
                .triggers
                .iter()
                .filter(|t| {
                    str_list(t, "branch_includes")
                        .iter()
                        .any(|p| glob(p, branch))
                        && !str_list(t, "branch_excludes")
                            .iter()
                            .any(|p| glob(p, branch))
                })
                .map(|t| t["trigger_uuid"].as_str().unwrap().to_string())
                .collect();
            for t in hits {
                let n = f.builds.len();
                f.builds.push(serde_json::json!({
                    "build_uuid": format!("build-{n}"), "trigger": t, "branch": branch,
                    "commit_hash": sha, "source": "push_event", "status": "queued",
                }));
            }
        }

        fn builds(&self) -> usize {
            self.0.borrow().builds.len()
        }

        fn writes(&self) -> Vec<Op> {
            self.0
                .borrow()
                .log
                .iter()
                .map(|(o, _)| *o)
                .filter(|o| o.method() != "GET")
                .collect()
        }
    }

    impl Wire for Api {
        fn send(&self, req: &Request) -> Result<HttpResponse, String> {
            assert_eq!(req.bearer, TOKEN);
            let path = req
                .url
                .strip_prefix("https://api.test")
                .unwrap()
                .to_string();
            let path_only = path.split('?').next().unwrap().to_string();
            let mut f = self.0.borrow_mut();
            f.log.push((req.op, path.clone()));
            f.bodies.push(req.body.clone().unwrap_or_default());
            let body: serde_json::Value = req
                .body
                .as_deref()
                .and_then(|b| serde_json::from_str(b).ok())
                .unwrap_or_default();
            let seg: Vec<&str> = path_only.split('/').filter(|s| !s.is_empty()).collect();
            match (req.op.method(), seg.as_slice()) {
                ("GET", ["accounts", ACCT, "workers", "scripts"]) => ok(f
                    .scripts
                    .iter()
                    .map(|(n, t)| serde_json::json!({"id": n, "tag": t}))
                    .collect()),
                ("PUT", ["accounts", ACCT, "workers", "scripts", name]) => {
                    assert!(
                        req.content_type
                            .as_deref()
                            .unwrap()
                            .starts_with("multipart/form-data")
                    );
                    let tag = format!("tag{:030}", f.scripts.len());
                    f.scripts.push((name.to_string(), tag.clone()));
                    ok(serde_json::json!({"id": name, "tag": tag}))
                }
                ("GET", ["accounts", ACCT, "builds", "workers", tag, "triggers"]) => ok(f
                    .triggers
                    .iter()
                    .filter(|t| t["external_script_id"] == *tag)
                    .cloned()
                    .collect()),
                ("PUT", ["accounts", ACCT, "builds", "repos", "connections"]) => {
                    let id = format!("conn-{}", body["repo_id"].as_str().unwrap());
                    if !f.connections.contains(&id) {
                        f.connections.push(id.clone());
                    }
                    ok(serde_json::json!({"repo_connection_uuid": id}))
                }
                ("POST", ["accounts", ACCT, "builds", "triggers"]) => {
                    let mut t = body.clone();
                    t["trigger_uuid"] = format!("trig-{}", f.triggers.len()).into();
                    f.triggers.push(t.clone());
                    ok(t)
                }
                ("POST", ["accounts", ACCT, "builds", "triggers", uuid, "builds"]) => {
                    let n = f.builds.len();
                    let b = serde_json::json!({
                        "build_uuid": format!("build-{n}"), "trigger": uuid,
                        "branch": body["branch"], "commit_hash": body["commit_hash"],
                        "source": "manual", "status": "queued",
                    });
                    f.builds.push(b.clone());
                    ok(b)
                }
                ("GET", ["accounts", ACCT, "builds", "builds", id]) => {
                    match f.builds.iter().find(|b| b["build_uuid"] == *id) {
                        Some(b) => ok(
                            serde_json::json!({"build_uuid": id, "status": "stopped", "build_outcome": "success", "trigger": b["trigger"]}),
                        ),
                        None => Ok(HttpResponse {
                            status: 404,
                            body: "{}".into(),
                        }),
                    }
                }
                ("GET", ["accounts", ACCT, "builds", "builds", _, "logs"]) => {
                    if path.contains("cursor=p2") {
                        ok(
                            serde_json::json!({"lines": [[2, "Success: deployed"]], "truncated": false}),
                        )
                    } else {
                        ok(
                            serde_json::json!({"lines": [[1, "Cloning repository..."]], "truncated": true, "cursor": "p2"}),
                        )
                    }
                }
                _ => Ok(HttpResponse {
                    status: 404,
                    body: "{}".into(),
                }),
            }
        }
    }

    fn session() -> Session<'static> {
        Session {
            api_base: "https://api.test",
            account: ACCT,
            token: TOKEN,
        }
    }

    fn spec() -> Spec {
        Spec {
            worker: "observatorium".into(),
            github_owner: "8007342".into(),
            github_owner_id: "111".into(),
            github_repo: "arabiya".into(),
            github_repo_id: "222".into(),
            build_token_uuid: "bt-0001".into(),
            root_directory: "".into(),
            build_command: "npm run build".into(),
            deploy_command: "npx wrangler deploy".into(),
        }
    }

    const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

    #[test]
    fn ensure_connects_once_and_no_push_outside_the_deploy_branch_builds() {
        let api = Api::new();
        let s = session();
        let first = ensure(&api, &s, &spec()).unwrap();
        assert_eq!(first["worker"], "created");
        assert_eq!(first["trigger"], "created");
        assert_eq!(first["deploy_branch"], "deploy/observatorium");
        // Creating the Worker and connecting the repo start no build.
        assert_eq!(api.builds(), 0, "create + connect must not build");
        assert_eq!(
            api.writes(),
            [Op::ScriptUpload, Op::RepoConnect, Op::TriggerCreate]
        );
        let t = api.0.borrow().triggers[0].clone();
        assert_eq!(str_list(&t, "branch_includes"), ["deploy/observatorium"]);

        // A second ensure writes nothing and builds nothing.
        let second = ensure(&api, &s, &spec()).unwrap();
        assert_eq!(second["worker"], "found");
        assert_eq!(second["trigger"], "found");
        assert_eq!(second["trigger_uuid"], first["trigger_uuid"]);
        assert_eq!(api.writes().len(), 3);
        assert_eq!(api.0.borrow().connections.len(), 1);

        for b in [
            "main",
            "linux-next",
            "work/1853-cfw1",
            "deploy/other",
            "deploy/observatorium-x",
        ] {
            api.push(b, SHA);
        }
        assert_eq!(
            api.builds(),
            0,
            "pushes off the deploy branch must build nothing"
        );
        // Control: the fake's filter is live, so the zero above is a verdict.
        // (A push to the deploy branch builds; whether a deploy should move
        // the branch AND request a build is the row's open double-build
        // question.)
        api.push("deploy/observatorium", SHA);
        assert_eq!(api.builds(), 1);
    }

    #[test]
    fn a_build_happens_only_on_an_explicit_named_revision_from_the_deploy_branch() {
        let api = Api::new();
        let s = session();
        ensure(&api, &s, &spec()).unwrap();
        let head = |b: &str| -> Result<String, String> {
            assert_eq!(b, "deploy/observatorium");
            Ok(SHA.to_string())
        };
        let other = "fedcba9876543210fedcba9876543210fedcba98";
        let e = deploy(&api, &s, &spec(), other, &head).unwrap_err();
        assert!(e.contains("revision-not-deploy-branch-head"), "{e}");
        assert!(
            deploy(&api, &s, &spec(), "main", &head)
                .unwrap_err()
                .contains("invalid-argument:revision")
        );
        assert_eq!(api.builds(), 0);

        let d = deploy(&api, &s, &spec(), SHA, &head).unwrap();
        assert_eq!(api.builds(), 1);
        assert_eq!(d["branch"], "deploy/observatorium");
        assert_eq!(d["commit_hash"], SHA);
        let b = api.0.borrow().builds[0].clone();
        assert_eq!(b["source"], "manual");
        // The deploy reused the existing trigger rather than making another.
        assert_eq!(api.0.borrow().triggers.len(), 1);

        let id = d["build_uuid"].as_str().unwrap();
        let st = status(&api, &s, id).unwrap();
        assert_eq!(st["status"], "stopped");
        assert_eq!(st["build_outcome"], "success");
        let lg = logs(&api, &s, id).unwrap();
        assert_eq!(lg["lines"].as_array().unwrap().len(), 2);
        assert_eq!(lg["truncated"], false);
    }

    #[test]
    fn an_existing_worker_is_found_and_a_foreign_trigger_is_refused_not_changed() {
        let api = Api::new();
        api.0
            .borrow_mut()
            .scripts
            .push(("observatorium".into(), "tagexisting0001".into()));
        api.0.borrow_mut().triggers.push(serde_json::json!({
            "trigger_uuid": "foreign", "external_script_id": "tagexisting0001",
            "branch_includes": ["*"], "branch_excludes": [],
        }));
        let e = ensure(&api, &session(), &spec()).unwrap_err();
        assert!(e.contains("other-trigger-present"), "{e}");
        assert!(
            api.writes().is_empty(),
            "a foreign trigger is never modified"
        );
    }

    #[test]
    fn no_credential_reaches_any_result_or_refusal() {
        struct Echo;
        impl Wire for Echo {
            fn send(&self, req: &Request) -> Result<HttpResponse, String> {
                Err(format!("transport failed for bearer {}", req.bearer))
            }
        }
        let s = session();
        let api = Api::new();
        let mut outputs = vec![ensure(&api, &s, &spec()).unwrap().to_string()];
        outputs.push(
            deploy(&api, &s, &spec(), SHA, &|_| Ok(SHA.into()))
                .unwrap()
                .to_string(),
        );
        outputs.push(logs(&api, &s, "build-0").unwrap().to_string());
        outputs.push(ensure(&Echo, &s, &spec()).unwrap_err());
        outputs.push(status(&Echo, &s, "build-0").unwrap_err());
        for o in &outputs {
            assert!(!o.contains(TOKEN), "token leaked: {o}");
        }
        assert!(outputs[3].contains("<redacted>"));
        // Nothing the module sends carries the bearer in a body or URL.
        let f = api.0.borrow();
        assert!(
            f.bodies
                .iter()
                .chain(f.log.iter().map(|(_, p)| p))
                .all(|t| !t.contains(TOKEN))
        );
    }

    #[test]
    fn invalid_names_are_refused_before_any_request() {
        let api = Api::new();
        let mut bad = spec();
        bad.worker = "Observatorium/../x".into();
        assert!(
            ensure(&api, &session(), &bad)
                .unwrap_err()
                .contains("invalid-argument:worker")
        );
        let mut bad = spec();
        bad.root_directory = "../etc".into();
        assert!(
            ensure(&api, &session(), &bad)
                .unwrap_err()
                .contains("invalid-argument:root_directory")
        );
        assert!(
            status(&api, &session(), "../x")
                .unwrap_err()
                .contains("invalid-argument:build_uuid")
        );
        assert!(api.0.borrow().log.is_empty());
    }
}

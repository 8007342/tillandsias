//! Authenticated-lane local preview lifecycle. No host checkout fallback.
//! @trace spec:local-web-preview, spec:mcp-tool-socket

use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const OWNER: &str = "tillandsias.preview.lane";
const FORGE: &str = "tillandsias.preview.forge";
const PROFILE: &str = "tillandsias.preview.runtime";
const CONFIG: &str = "tillandsias.preview.config";

tokio::task_local! { static RPC_DEADLINE: Instant; }

fn command_budget(maximum: Duration) -> Result<Duration, String> {
    let remaining = RPC_DEADLINE
        .try_with(|deadline| deadline.saturating_duration_since(Instant::now()))
        .unwrap_or(maximum);
    if remaining.is_zero() {
        return Err(
            "runtime_not_ready: operation deadline expired; no further mutations allowed".into(),
        );
    }
    Ok(remaining.min(maximum))
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Profile {
    Static,
    Wrangler(String),
}

impl Profile {
    fn name(&self) -> &'static str {
        match self {
            Self::Static => "static",
            Self::Wrangler(_) => "wrangler",
        }
    }

    /// The INIT_IMAGES / image_specs name init builds this profile from.
    fn image_name(&self) -> &'static str {
        match self {
            Self::Static => "web",
            Self::Wrangler(_) => "web-wrangler",
        }
    }

    /// 1625-un54: exactly the version alias init (and ensure_image_exists)
    /// tags, the router's convention. The untagged name used to resolve to
    /// `:latest`, a tag nothing on the preview path ever promised to move.
    fn image(&self) -> String {
        crate::versioned_image_tag(self.image_name(), crate::VERSION.trim())
    }
}

/// 1625-un54: bound for building a missing profile image on the host during
/// publish_local. A cold web-wrangler build (base pull + `npm ci`) measured 12 s
/// on lenovinha (2026-10-12); 300 s leaves room for a slow link. It is spent
/// OUTSIDE the publish deadline, so a build never starves readiness or routing.
const IMAGE_ENSURE_BUDGET: Duration = Duration::from_secs(300);

/// The publish/reload operation deadline, excluding any IMAGE_ENSURE_BUDGET spent.
const PUBLISH_BUDGET: Duration = Duration::from_secs(90);

/// Build the profile's managed image host-side when it is absent. The name,
/// context and tag come from the profile alone; nothing from the MCP request
/// reaches the build.
async fn ensure_profile_image(profile: &Profile, debug: bool) -> Result<(), String> {
    let image = profile.image();
    // `image exists` answers absence with exit 1. Only that means "build it";
    // a transport failure or timeout is podman being unavailable (1625-6iwd).
    match podman_output(&["image", "exists", &image]) {
        Ok(out) if out.status.success() => return Ok(()),
        Ok(_) => {}
        Err(class) => return Err(podman_failure(Step::Image, class)),
    }
    let name = profile.image_name();
    let tag = image.clone();
    let build = tokio::task::spawn_blocking(move || {
        let root = crate::resolve_runtime_asset_root(crate::VERSION.trim(), debug)?;
        crate::ensure_image_exists(&root, name, &tag, debug)
    });
    match tokio::time::timeout(IMAGE_ENSURE_BUDGET, build).await {
        Ok(Ok(Ok(()))) => {}
        Ok(Ok(Err(_))) | Ok(Err(_)) => {
            return Err(
                "runtime_unavailable: image build failed on the host (exit); see the tray log"
                    .into(),
            );
        }
        // The build keeps running under its image lock; a retry finds the image.
        Err(_) => {
            return Err(format!(
                "runtime_not_ready: image still building on the host after {} s (timeout); retry publish_local",
                IMAGE_ENSURE_BUDGET.as_secs()
            ));
        }
    }
    podman_at(Step::Image, &["image", "exists", &image]).map(|_| ())
}

fn select_profile(runtime: &str, configs: &[String]) -> Result<Profile, String> {
    if !["auto", "static", "wrangler"].contains(&runtime) {
        return Err("invalid_runtime: expected auto, static or wrangler".into());
    }
    if runtime == "static" {
        return Ok(Profile::Static);
    }
    match configs {
        [] if runtime == "auto" => Ok(Profile::Static),
        [] => Err("invalid_runtime: Wrangler requires a root configuration".into()),
        [config] => Ok(Profile::Wrangler(config.clone())),
        _ => Err("invalid_runtime: ambiguous root Wrangler configurations".into()),
    }
}

fn validate_identity(project: &str, instance: &str) -> Result<(), String> {
    // Equality, not sanitization. A known cloud label is necessary but not
    // sufficient: resolve_live additionally proves the accepting lane's mount.
    crate::local_projects::validate_project_label(project)?;
    validate_components(project, instance)
}

fn validate_components(project: &str, instance: &str) -> Result<(), String> {
    let hostname_ok = !project.is_empty()
        && project.len() <= 200
        && project.split('.').all(|part| {
            !part.is_empty()
                && part.len() <= 63
                && !part.starts_with('-')
                && !part.ends_with('-')
                && part.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        });
    let instance_ok = !instance.is_empty()
        && instance.len() <= 128
        && instance
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if !hostname_ok || !instance_ok {
        return Err("live_worktree_unavailable: lane identity is not safely addressable".into());
    }
    Ok(())
}

/// 1625-6iwd: the step vocabulary of spec local-web-preview "Publish failures
/// name their step". Every podman call names one, so a failure says WHERE it
/// failed. It used to say "Podman operation failed" for all of them.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Step {
    /// Container listing (`ps`).
    List,
    Inspect,
    Image,
    /// Source mounts: probes inside the live forge, the RAM volume, the config.
    Source,
    Router,
    /// Container lifecycle: run, rename, remove.
    Run,
    Ready,
}

impl Step {
    fn name(self) -> &'static str {
        match self {
            Self::List => "list",
            Self::Inspect => "inspect",
            Self::Image => "image",
            Self::Source => "source",
            Self::Router => "router",
            Self::Run => "run",
            Self::Ready => "ready",
        }
    }
}

/// The failure class of one podman call. `Absent` is decided by callers that
/// ask an existence question; podman itself only reports the other three.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Class {
    Transport,
    Exit,
    Timeout,
}

impl Class {
    fn name(self) -> &'static str {
        match self {
            Self::Transport => "transport",
            Self::Exit => "exit",
            Self::Timeout => "timeout",
        }
    }
}

/// The stable reason for a failed podman call. It names the step and the
/// class and NOTHING else: inspect/log output can carry project secrets.
fn podman_failure(step: Step, class: Class) -> String {
    format!(
        "runtime_unavailable: podman failed at step {} ({})",
        step.name(),
        class.name()
    )
}

#[cfg(test)]
type FakePodman = Box<dyn Fn(&[&str]) -> std::io::Result<std::process::Output>>;

#[cfg(test)]
thread_local! {
    /// Fault-injection seam for this module's tests. It is THREAD-local on
    /// purpose: TILLANDSIAS_PODMAN_BIN is process-wide and parallel tests that
    /// swap it once reached the real podman (880-tdwn).
    static FAKE_PODMAN: std::cell::RefCell<Option<FakePodman>> =
        const { std::cell::RefCell::new(None) };
}

fn podman_output(args: &[&str]) -> Result<std::process::Output, Class> {
    #[cfg(test)]
    if let Some(out) = FAKE_PODMAN.with(|fake| fake.borrow().as_ref().map(|f| f(args))) {
        return out.map_err(|e| match e.kind() {
            std::io::ErrorKind::TimedOut => Class::Timeout,
            _ => Class::Transport,
        });
    }
    let mut cmd = crate::podman_command();
    cmd.args(args);
    let budget = command_budget(Duration::from_secs(5)).map_err(|_| Class::Timeout)?;
    cmd.output_bounded(budget).map_err(|e| match e.kind() {
        std::io::ErrorKind::TimedOut => Class::Timeout,
        _ => Class::Transport,
    })
}

/// Run one podman command for `step`. Never echo raw diagnostics.
fn podman_at(step: Step, args: &[&str]) -> Result<String, String> {
    let out = podman_output(args).map_err(|class| podman_failure(step, class))?;
    if !out.status.success() {
        return Err(podman_failure(step, Class::Exit));
    }
    String::from_utf8(out.stdout).map_err(|_| podman_failure(step, Class::Exit))
}

fn inspect(name: &str) -> Result<Option<Value>, String> {
    // PodmanClient::inspect_container currently turns EVERY failed command into
    // NotFound. Enumerate successfully first so a transport failure is unknown,
    // never proof of absence. Inspect races fail unknown rather than stopped.
    let names: Vec<String> = podman_at(
        Step::List,
        &[
            "ps",
            "--all",
            "--no-trunc",
            "--format",
            "{{.Names}} {{.ID}}",
        ],
    )?
    .lines()
    .flat_map(|line| line.split_whitespace().map(str::to_owned))
    .collect();
    if !names.iter().any(|n| n == name) {
        return Ok(None);
    }
    let text = podman_at(Step::Inspect, &["inspect", name])?;
    let rows: Vec<Value> = serde_json::from_str(&text)
        .map_err(|_| "runtime_unavailable: invalid inspect response".to_string())?;
    rows.into_iter()
        .next()
        .map(Some)
        .ok_or_else(|| "runtime_unavailable: empty inspect response".into())
}

fn label<'a>(inspect: &'a Value, key: &str) -> &'a str {
    inspect["Config"]["Labels"][key].as_str().unwrap_or("")
}

fn forge_names(project: &str, instance: &str) -> Vec<String> {
    let suffix = if instance == "default" {
        None
    } else {
        Some(instance)
    };
    [
        crate::ForgeAgentMode::OpenCode,
        crate::ForgeAgentMode::Claude,
        crate::ForgeAgentMode::Codex,
        crate::ForgeAgentMode::Antigravity,
        crate::ForgeAgentMode::Maintenance,
    ]
    .into_iter()
    .map(|mode| crate::forge_container_name_for_mode_with_instance(project, mode, suffix))
    .collect()
}

#[derive(Debug)]
struct LiveSource {
    forge_id: String,
    volume: String,
    generation: String,
    project: String,
    configs: Vec<String>,
}

fn attributed_forge(row: &Value, socket_dir: &Path) -> bool {
    row["State"]["Status"] == "running"
        && row["Mounts"].as_array().is_some_and(|mounts| {
            mounts.iter().any(|m| {
                m["Destination"] == "/run/host/tillandsias-mcp"
                    && m["Source"]
                        .as_str()
                        .is_some_and(|s| Path::new(s) == socket_dir)
            })
        })
}

/// 1637-5765: the live lane's forge and RAM source volume, for a toolchain
/// session (toolchain_exec) that must work on the same tree publish_local
/// serves. Same proofs as publish: one attributed forge, a bounded tmpfs volume.
pub(crate) struct LiveLane {
    pub(crate) forge_id: String,
    pub(crate) volume: String,
}

pub(crate) fn resolve_live_source(project: &str, instance: &str) -> Result<LiveLane, String> {
    resolve_live(project, instance).map(|l| LiveLane {
        forge_id: l.forge_id,
        volume: l.volume,
    })
}

fn resolve_live(project: &str, instance: &str) -> Result<LiveSource, String> {
    let socket_dir = crate::mcp_socket_host_dir(project, Some(instance));
    let mut matches = Vec::new();
    for name in forge_names(project, instance) {
        if let Some(row) = inspect(&name)?
            && attributed_forge(&row, &socket_dir)
        {
            matches.push(row);
        }
    }
    if matches.len() != 1 {
        return Err("live_worktree_unavailable: expected one live authenticated forge lane".into());
    }
    let row = &matches[0];
    let id = row["Id"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("live_worktree_unavailable: forge identity missing")?;
    let guest = format!("/home/forge/src/{project}");
    // Reject symlink roots, including a project redirect into the forge's home
    // or a sibling project. realpath runs in the LIVE forge, not on host disks.
    let actual = podman_at(Step::Source, &["exec", id, "realpath", "-e", "--", &guest])?;
    if actual.trim() != guest {
        return Err("live_worktree_unavailable: project root escapes its lane".into());
    }
    podman_at(Step::Source, &["exec", id, "test", "-d", &guest])?;
    let configs = ["wrangler.jsonc", "wrangler.json", "wrangler.toml"]
        .into_iter()
        .filter_map(|name| {
            let path = format!("{guest}/{name}");
            // Use a fixed script and positional arg; absence is successful
            // output, an exec failure is not silently treated as no config.
            let result = podman_at(
                Step::Source,
                &[
                    "exec",
                    id,
                    "sh",
                    "-c",
                    "if [ -f \"$1\" ]; then printf present; fi",
                    "sh",
                    &path,
                ],
            );
            match result {
                Ok(text) if text == "present" => Some(Ok(name.to_string())),
                Ok(_) => None,
                Err(e) => Some(Err(e)),
            }
        })
        .collect::<Result<Vec<_>, _>>()?;
    let volume = live_mount_source(row, project, instance)?;
    // Verify the configured RAM backing, not just a suggestive volume name.
    let info: Vec<Value> =
        serde_json::from_str(&podman_at(Step::Source, &["volume", "inspect", &volume])?)
            .map_err(|_| "live_worktree_unavailable: invalid source volume inspect")?;
    let options = &info
        .first()
        .ok_or("live_worktree_unavailable: missing RAM volume")?["Options"];
    // Launch preparation records the exact computed cap. Compare the real
    // driver options to that immutable launch generation, not merely `size=`.
    let expected = info[0]["Labels"]["tillandsias.source.options"]
        .as_str()
        .unwrap_or("");
    let canonical_cap = expected
        .strip_prefix("size=")
        .and_then(|s| s.strip_suffix("m,mode=0777"))
        .and_then(|s| s.parse::<u64>().ok())
        .is_some_and(|n| n > 0);
    if options["type"] != "tmpfs"
        || options["device"] != "tmpfs"
        || options["o"] != expected
        || !canonical_cap
        || info[0]["Labels"]["tillandsias.source"] != "ram-only"
    {
        return Err("live_worktree_unavailable: source volume is not bounded tmpfs".into());
    }
    let generation = info[0]["Labels"]["tillandsias.source.launch"]
        .as_str()
        .ok_or("live_worktree_unavailable: RAM volume launch ownership missing")?
        .to_string();
    let fs_type = podman_at(
        Step::Source,
        &["exec", id, "stat", "-f", "-c", "%T", "/home/forge/src"],
    )?;
    if fs_type.trim() != "tmpfs" {
        return Err("live_worktree_unavailable: source backing is not live tmpfs".into());
    }
    Ok(LiveSource {
        forge_id: id.to_string(),
        volume,
        generation,
        project: project.to_string(),
        configs,
    })
}

fn live_mount_source(row: &Value, project: &str, instance: &str) -> Result<String, String> {
    let mounts = row["Mounts"]
        .as_array()
        .ok_or("live_worktree_unavailable: forge mounts unavailable")?;
    let volume = crate::local_projects::ram_workspace_volume(project, instance);
    if !mounts.iter().any(|m| {
        m["Destination"] == "/home/forge/src" && m["Type"] == "volume" && m["Name"] == volume
    }) {
        return Err("live_worktree_unavailable: forge uses unshareable private tmpfs; recreate with bounded shared source".into());
    }
    Ok(volume)
}

pub(crate) fn unique_live_instance(project: &str) -> Result<String, String> {
    crate::local_projects::validate_project_label(project)?;
    let socket_root = crate::control_socket_host_dir().join("mcp");
    let names = podman_at(Step::List, &["ps", "--format", "{{.Names}}"])?;
    let mut lanes = std::collections::BTreeSet::new();
    for name in names.lines() {
        // Inspect only managed forge-name candidates; do not touch unrelated
        // containers or consume their environment as project attribution.
        if !name.starts_with(&format!("tillandsias-{project}-forge")) {
            continue;
        }
        let Some(row) = inspect(name)? else {
            continue;
        };
        for mount in row["Mounts"].as_array().into_iter().flatten() {
            if mount["Destination"] != "/run/host/tillandsias-mcp" {
                continue;
            }
            let Some(source) = mount["Source"].as_str() else {
                continue;
            };
            let path = Path::new(source);
            if path.parent() != Some(socket_root.as_path()) {
                continue;
            }
            if let Some(instance) = path
                .file_name()
                .and_then(|s| s.to_str())
                .and_then(|s| s.strip_prefix(&format!("{project}-")))
                && validate_components(project, instance).is_ok()
                && forge_names(project, instance).iter().any(|n| n == name)
            {
                lanes.insert(instance.to_string());
            }
        }
    }
    match lanes.len() {
        1 => Ok(lanes.into_iter().next().expect("one lane")),
        0 => Err("live_worktree_unavailable: no live forge lane".into()),
        _ => Err("live_worktree_unavailable: ambiguous live forge lanes".into()),
    }
}

fn check_owner(row: Option<&Value>, instance: &str, forge: Option<&str>) -> Result<(), String> {
    if let Some(row) = row {
        if label(row, OWNER) != instance {
            return Err("lane_conflict: preview belongs to another or an unrecorded lane".into());
        }
        if let Some(forge) = forge
            && label(row, FORGE) != forge
        {
            return Err("lane_conflict: preview belongs to a different forge launch".into());
        }
    }
    Ok(())
}

fn result(
    state: &str,
    profile: Option<&str>,
    url: Option<&str>,
    ready: bool,
    diagnostic: &str,
) -> Value {
    let mut value = json!({
        "state": state, "runtime": profile.unwrap_or("unknown"),
        "watch": profile == Some("wrangler"), "route_ready": ready,
        "tls": {"enabled": true, "host_trust": "unknown",
            "diagnostic": "Local CA transport verification is separate from host-browser trust; no host trust store was changed."},
        "diagnostic": diagnostic
    });
    if let Some(url) = url {
        value["url"] = json!(url);
    }
    if state == "running" {
        value["diagnostic"] = json!(format!("{diagnostic} Assets/Worker directories are live and watched. Config is pinned to the validated publication generation; config edits and atomic replacement of root-file mounts require service_reload.").trim());
    }
    value
}

fn build_local_preview_run_args(
    name: &str,
    live: &LiveSource,
    instance: &str,
    profile: &Profile,
    mounts: &[String],
) -> Vec<String> {
    let mut args = vec![
        "--detach".into(),
        "--name".into(),
        name.into(),
        "--network".into(),
        crate::ENCLAVE_NET.into(),
        "--network-alias".into(),
        name.into(),
        "--cap-drop=ALL".into(),
        "--security-opt=no-new-privileges".into(),
        "--security-opt=label=disable".into(),
        "--userns=keep-id".into(),
        "--read-only".into(),
        "--pids-limit=256".into(),
        "--tmpfs".into(),
        "/tmp:rw,nosuid,nodev,size=256m,mode=1777".into(),
        "--workdir".into(),
        if profile.name() == "wrangler" {
            "/srv/preview"
        } else {
            "/var/www"
        }
        .into(),
        "--label".into(),
        format!("{OWNER}={instance}"),
        "--label".into(),
        format!("{FORGE}={}", live.forge_id),
        "--label".into(),
        format!("{PROFILE}={}", profile.name()),
    ];
    let mut runtime_name: Option<&str> = None;
    for mount in mounts {
        if let Some(name) = mount.strip_prefix("approved-config-name:") {
            runtime_name = Some(name);
            continue;
        }
        if let Some(config) = mount.strip_prefix("approved-config:") {
            args.extend([
                "--env".into(),
                format!("TILLANDSIAS_APPROVED_CONFIG={config}"),
            ]);
            continue;
        }
        args.extend(["--mount".into(), mount.clone()]);
    }
    if let Profile::Wrangler(config) = profile {
        let runtime_config = runtime_name.unwrap_or(config);
        args.extend([
            "--label".into(),
            format!("{CONFIG}={config}"),
            "--env".into(),
            format!("TILLANDSIAS_WRANGLER_CONFIG={runtime_config}"),
            "--env".into(),
            "HOME=/tmp/home".into(),
            "--env".into(),
            "XDG_CACHE_HOME=/tmp/cache".into(),
            "--env".into(),
            "WRANGLER_SEND_METRICS=false".into(),
            "--tmpfs".into(),
            "/srv/preview:rw,nosuid,nodev,size=4m,mode=1777".into(),
            "--entrypoint".into(),
            "node".into(),
        ]);
    }
    args.push(profile.image());
    if let Profile::Wrangler(config) = profile {
        args.extend([
            "-e".into(),
            r#"const fs=require('fs'),cp=require('child_process'); const p='/srv/preview/'+process.env.TILLANDSIAS_WRANGLER_CONFIG; fs.writeFileSync(p,process.env.TILLANDSIAS_APPROVED_CONFIG,{mode:0o444}); delete process.env.TILLANDSIAS_APPROVED_CONFIG; const child=cp.spawn('/usr/local/bin/tillandsias-wrangler',process.argv.slice(1),{stdio:'inherit'}); for(const s of ['SIGTERM','SIGINT'])process.on(s,()=>child.kill(s)); child.on('exit',c=>process.exit(c??1));"#.into(),
            "dev".into(),
            "--local".into(),
            "--ip".into(),
            "0.0.0.0".into(),
            "--port".into(),
            "8080".into(),
            "--config".into(),
            format!("/srv/preview/{}", runtime_name.unwrap_or(config)),
            "--persist-to".into(),
            "/tmp/wrangler-state".into(),
        ]);
    }
    args
}

fn safe_relative(path: &str) -> Result<String, String> {
    let relative = path.strip_prefix("/srv/preview/").unwrap_or(path);
    let path = Path::new(relative);
    let parts: Vec<_> = path
        .components()
        .filter_map(|c| match c {
            std::path::Component::CurDir => None,
            std::path::Component::Normal(s) => Some(s.to_str().unwrap_or("")),
            _ => Some(""),
        })
        .collect();
    if parts.is_empty()
        || parts.iter().any(|s| {
            s.is_empty()
                || s.starts_with('.')
                || s.contains(',')
                || s.contains(':')
                || s.chars().any(char::is_control)
                || ["node_modules", "cache", "secrets", "credentials"].contains(s)
        })
    {
        return Err(
            "live_worktree_unavailable: source selection would expose private or unscoped paths"
                .into(),
        );
    }
    Ok(parts.join("/"))
}

fn subset_mount(live: &LiveSource, path: &str, destination: &str) -> Result<String, String> {
    let relative = safe_relative(path)?;
    Ok(format!(
        "type=volume,source={},target={destination},volume-subpath={}/{relative},readonly=true",
        live.volume, live.project
    ))
}

fn verify_subset(live: &LiveSource, path: &str) -> Result<(), String> {
    let relative = safe_relative(path)?;
    let expected = format!("/home/forge/src/{}/{relative}", live.project);
    let actual = podman_at(
        Step::Source,
        &["exec", &live.forge_id, "realpath", "-e", "--", &expected],
    )?;
    if actual.trim() != expected {
        return Err("live_worktree_unavailable: selected source is a symlink escape".into());
    }
    let forbidden = podman_at(
        Step::Source,
        &[
            "exec",
            &live.forge_id,
            "find",
            &expected,
            "(",
            "-type",
            "l",
            "-o",
            "-name",
            ".git",
            "-o",
            "-name",
            ".env*",
            "-o",
            "-name",
            "node_modules",
            "-o",
            "-name",
            ".cache",
            "-o",
            "-name",
            "credentials",
            ")",
            "-print",
            "-quit",
        ],
    )?;
    if !forbidden.trim().is_empty() {
        return Err(
            "live_worktree_unavailable: selected source contains private paths or symlinks".into(),
        );
    }
    Ok(())
}

// Use pinned Wrangler's own parser. JSONC/TOML/assets-only configuration is
// never reimplemented as serde_json or by a `main` requirement. Only the root
// configuration is visible to this no-network inspector. Operator-approved
// exception: plan/index.d/20261007t192318z-local-web-preview-adapter-approval-yoga.yaml.
// Selected paths and exact config bytes go privately to Rust to pin an approved
// generation; raw config must never enter MCP responses or diagnostics. This is
// not a generic JavaScript runner and introduces no extra npm dependency.
const CONFIG_INSPECTOR: &str = r#"
const fs = require('fs'), path = require('path');
const {unstable_readConfig} = require('/opt/tillandsias/wrangler/node_modules/wrangler');
const raw = fs.readFileSync(process.argv[1], 'utf8');
if (Buffer.byteLength(raw) > 65536) throw Error('config too large');
fs.mkdirSync('/tmp/approved', {recursive:true});
const snapshot = '/tmp/approved/' + path.basename(process.argv[1]);
fs.writeFileSync(snapshot, raw);
const c = unstable_readConfig({config: snapshot});
function remote(v) { return v && typeof v === 'object' && (v.remote === true || Object.values(v).some(remote)); }
function relative(p) { return p ? p.replace(/^\/tmp\/approved\//, '') : null; }
const build = typeof c.build?.command === 'string' && c.build.command.trim() ? c.build.command.trim() : null;
// 1663-6mns: `wrangler dev` RUNS build.command at startup (measured: "[custom
// build] Running: ..."), inside the preview container where only the assets
// subset is mounted and there is no network: the build fails and the runtime
// exits. The agent builds in its forge (assets_absent says so); the runtime
// must not run project commands. So the runtime gets the config WITHOUT
// build (top level and every env), as JSON; a TOML name gains .json.
const parsed = require('/opt/tillandsias/wrangler/node_modules/wrangler').experimental_readRawConfig({config: snapshot}).rawConfig;
const hasBuild = (o) => o && typeof o === 'object' && ('build' in o || Object.values(o.env || {}).some((e) => e && 'build' in e));
let runtime = raw, runtimeName = path.basename(process.argv[1]);
if (hasBuild(parsed)) {
  delete parsed.build;
  for (const e of Object.values(parsed.env || {})) if (e && typeof e === 'object') delete e.build;
  runtime = JSON.stringify(parsed);
  if (!/\.jsonc?$/.test(runtimeName)) runtimeName += '.json';
}
console.log(JSON.stringify({remote:remote(c), assets:relative(c.assets?.directory), main:relative(c.main), build, raw:runtime, runtime_name:runtimeName}));
"#;

/// 1625-6iwd: the static profile found nothing to serve. A SOURCE-SELECTION
/// failure (step source, class absent), never a runtime or podman error. On
/// yoga this used to surface as "Podman operation failed" because the root
/// index.html probe (`realpath -e`) exits 1 when the file is absent.
const NO_SERVABLE_ROOT: &str =
    "source_not_found: no servable root (looked at var/html, public, dist, index.html)";

/// Does `relative` exist under the live project root? Absence is an ANSWER
/// (Ok(false)); only a failed probe is an error.
fn source_exists(live: &LiveSource, relative: &str, test: &str) -> Result<bool, String> {
    let path = format!("/home/forge/src/{}/{relative}", live.project);
    let script = format!("if [ {test} \"$1\" ]; then printf present; fi");
    let answer = podman_at(
        Step::Source,
        &["exec", &live.forge_id, "sh", "-c", &script, "sh", &path],
    )?;
    Ok(answer == "present")
}

/// What the pinned Wrangler parser reports about the root configuration.
/// `raw` stays private to Rust: it never enters MCP responses or diagnostics.
struct WranglerConfig {
    remote: bool,
    assets: Option<String>,
    main: Option<String>,
    build: Option<String>,
    raw: String,
    /// The runtime config's file name: the project's, or `<name>.json` when
    /// the build had to be stripped from a TOML config (1663-6mns).
    runtime_name: String,
}

fn inspect_wrangler_config(live: &LiveSource, config: &str) -> Result<WranglerConfig, String> {
    verify_subset(live, config)?;
    let config_target = format!("/srv/preview/{config}");
    let config_mount = subset_mount(live, config, &config_target)?;
    let image = Profile::Wrangler(config.to_string()).image();
    let text = podman_at(
        Step::Source,
        &[
            "run",
            "--rm",
            "--pull=never",
            "--network=none",
            "--read-only",
            "--security-opt=label=disable",
            "--userns=keep-id",
            "--tmpfs",
            "/tmp:rw,mode=1777,size=64m",
            "--workdir",
            "/srv/preview",
            "--env",
            "HOME=/tmp",
            "--env",
            "WRANGLER_SEND_METRICS=false",
            "--mount",
            &config_mount,
            "--entrypoint",
            "node",
            &image,
            "-e",
            CONFIG_INSPECTOR,
            &config_target,
        ],
    )
    .map_err(|e| {
        // A parser that ran and refused is the config's fault; podman being
        // unreachable or slow keeps its own step reason.
        if e.ends_with("(exit)") {
            "invalid_runtime: pinned Wrangler rejected configuration".to_string()
        } else {
            e
        }
    })?;
    let parsed: Value = serde_json::from_str(text.trim().lines().last().unwrap_or(""))
        .map_err(|_| "invalid_runtime: Wrangler configuration parser unavailable")?;
    let text_field = |key: &str| parsed[key].as_str().map(str::to_owned);
    Ok(WranglerConfig {
        remote: parsed["remote"] == true,
        assets: text_field("assets"),
        main: text_field("main"),
        build: text_field("build"),
        raw: text_field("raw").ok_or("invalid_runtime: approved config unavailable")?,
        // Absent: the project's own name (nothing was stripped). Present: a
        // plain file name only, since it becomes a path under /srv/preview.
        runtime_name: match text_field("runtime_name") {
            None => config.to_string(),
            Some(n)
                if !n.is_empty()
                    && n.len() <= 64
                    && n.bytes()
                        .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
                    && !n.starts_with('.') =>
            {
                n
            }
            Some(_) => return Err("invalid_runtime: approved config name unavailable".into()),
        },
    })
}

/// A build command is echoed only when it is short and plainly a command.
/// Anything that looks like it could carry a credential is named by key only.
fn echoable_build_command(command: &str) -> bool {
    let lower = command.to_ascii_lowercase();
    command.len() <= 160
        && command
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || " ._/:@+,=-&|;".contains(c))
        && ![
            "token", "secret", "password", "passwd", "apikey", "api_key", "auth",
        ]
        .iter()
        .any(|w| lower.contains(w))
}

/// 1625-6iwd: the configured assets directory is not there (visual-chess:
/// `"assets": {"directory": "./dist"}` with dist/ never built). Say so, name
/// the directory and how to produce it, so the agent builds first.
fn assets_absent(directory: &str, config: &str, build: Option<&str>) -> String {
    let next = match build {
        Some(command) if echoable_build_command(command) => {
            format!("run its build.command first: {command}")
        }
        Some(_) => format!("run the build.command declared in {config} first"),
        None => format!("{config} declares no build.command; build the project first"),
    };
    format!(
        "source_not_found: assets directory {directory} (configured in {config}) does not exist yet; {next}"
    )
}

fn source_mounts(live: &LiveSource, profile: &Profile) -> Result<Vec<String>, String> {
    match profile {
        Profile::Static => {
            // Static compatibility selects a public document tree, never mounts
            // .git/.env/the forge root into a sibling. Assets-only layouts work
            // without a Wrangler config too. A root index is served individually.
            //
            // 1625-6iwd: a root Wrangler config's assets.directory comes FIRST.
            // Static runs no Worker, so its bindings (remote or not) are moot.
            if let [config] = live.configs.as_slice() {
                let parsed = inspect_wrangler_config(live, config)?;
                if let Some(assets) = parsed.assets {
                    let relative = safe_relative(&assets)?;
                    if !source_exists(live, &relative, "-d")? {
                        return Err(assets_absent(&relative, config, parsed.build.as_deref()));
                    }
                    verify_subset(live, &relative)?;
                    return Ok(vec![subset_mount(live, &relative, "/var/www")?]);
                }
            }
            for directory in ["var/html", "public", "dist"] {
                if source_exists(live, directory, "-d")? {
                    verify_subset(live, directory)?;
                    return Ok(vec![subset_mount(live, directory, "/var/www")?]);
                }
            }
            if !source_exists(live, "index.html", "-f")? {
                return Err(NO_SERVABLE_ROOT.into());
            }
            verify_subset(live, "index.html")?;
            let mut mounts = vec![subset_mount(live, "index.html", "/var/www/index.html")?];
            let root = format!("/home/forge/src/{}", live.project);
            let files = podman_at(
                Step::Source,
                &[
                    "exec",
                    &live.forge_id,
                    "find",
                    &root,
                    "-maxdepth",
                    "1",
                    "-type",
                    "f",
                ],
            )?;
            for path in files.lines() {
                let Some(file) = Path::new(path).file_name().and_then(|s| s.to_str()) else {
                    continue;
                };
                if file == "index.html" || file.starts_with('.') {
                    continue;
                }
                let extension = Path::new(file)
                    .extension()
                    .and_then(|s| s.to_str())
                    .unwrap_or("");
                if [
                    "html",
                    "css",
                    "js",
                    "svg",
                    "png",
                    "jpg",
                    "jpeg",
                    "gif",
                    "ico",
                    "webp",
                    "woff",
                    "woff2",
                    "webmanifest",
                ]
                .contains(&extension)
                {
                    verify_subset(live, file)?;
                    mounts.push(subset_mount(live, file, &format!("/var/www/{file}"))?);
                }
            }
            for directory in ["assets", "css", "js", "images"] {
                if source_exists(live, directory, "-d")? {
                    verify_subset(live, directory)?;
                    mounts.push(subset_mount(
                        live,
                        directory,
                        &format!("/var/www/{directory}"),
                    )?);
                }
            }
            Ok(mounts)
        }
        Profile::Wrangler(config) => {
            let parsed = inspect_wrangler_config(live, config)?;
            if parsed.remote {
                return Err(
                    "remote_binding_forbidden: local preview refuses remote bindings".into(),
                );
            }
            let mut mounts = vec![
                format!("approved-config:{}", parsed.raw),
                format!("approved-config-name:{}", parsed.runtime_name),
            ];
            if let Some(assets) = parsed.assets.as_deref() {
                let relative = safe_relative(assets)?;
                if !source_exists(live, &relative, "-d")? {
                    return Err(assets_absent(&relative, config, parsed.build.as_deref()));
                }
                verify_subset(live, &relative)?;
                mounts.push(subset_mount(
                    live,
                    &relative,
                    &format!("/srv/preview/{relative}"),
                )?);
            }
            if let Some(main) = parsed.main.as_deref() {
                let relative = safe_relative(main)?;
                if !source_exists(live, &relative, "-e")? {
                    return Err(format!(
                        "source_not_found: Worker entry {relative} (configured in {config}) does not exist"
                    ));
                }
                let parent = Path::new(&relative)
                    .parent()
                    .and_then(|s| s.to_str())
                    .unwrap_or("");
                // Non-root Worker source directory permits local imports while
                // excluding project-root credentials/config/cache. Root Workers
                // get only the entry file; missing imports fail explicitly.
                let selected = if parent.is_empty() {
                    relative.as_str()
                } else {
                    parent
                };
                verify_subset(live, selected)?;
                if !mounts
                    .iter()
                    .any(|m| m.contains(&format!("volume-subpath={}/{selected},", live.project)))
                {
                    mounts.push(subset_mount(
                        live,
                        selected,
                        &format!("/srv/preview/{selected}"),
                    )?);
                }
            }
            if mounts.len() == 1 {
                return Err("invalid_runtime: no local assets or Worker entrypoint".into());
            }
            Ok(mounts)
        }
    }
}

fn router_dir() -> PathBuf {
    crate::router_dynamic_caddyfile_host_path()
}

pub(crate) fn tls_port() -> Result<u16, String> {
    std::fs::read_to_string(router_dir().join("preview-tls-port"))
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .filter(|p| *p >= 1024)
        .ok_or_else(|| "router_not_ready: TLS listener unavailable".into())
}

fn url(project: &str) -> Result<String, String> {
    Ok(format!("https://www.{project}.localhost:{}", tls_port()?))
}

fn host_command(args: &[String]) -> Result<(), String> {
    let deadline = Instant::now() + command_budget(Duration::from_secs(15))?;
    let mut child = std::process::Command::new("openssl")
        .args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|_| "router_not_ready: certificate tool unavailable".to_string())?;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(_)) => return Err("router_not_ready: certificate generation failed".into()),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("router_not_ready: certificate generation timed out".into());
            }
        }
    }
}

fn certificate_args(
    host: &str,
    crt: &Path,
    csr: &Path,
    key: &Path,
    ca: &Path,
    ext: &Path,
) -> Vec<Vec<String>> {
    vec![
        vec![
            "req".into(),
            "-new".into(),
            "-newkey".into(),
            "rsa:2048".into(),
            "-nodes".into(),
            "-subj".into(),
            format!("/CN={host}"),
            "-keyout".into(),
            key.display().to_string(),
            "-out".into(),
            csr.display().to_string(),
        ],
        vec![
            "x509".into(),
            "-req".into(),
            "-in".into(),
            csr.display().to_string(),
            "-CA".into(),
            ca.join("intermediate.crt").display().to_string(),
            "-CAkey".into(),
            ca.join("intermediate.key").display().to_string(),
            "-set_serial".into(),
            format!(
                "{}",
                chrono::Utc::now()
                    .timestamp_nanos_opt()
                    .unwrap_or(1)
                    .unsigned_abs()
            ),
            "-days".into(),
            "7".into(),
            "-extfile".into(),
            ext.display().to_string(),
            "-out".into(),
            crt.display().to_string(),
        ],
    ]
}

fn prepare_tls(project: &str, ca: &Path) -> Result<(), String> {
    let root = router_dir();
    let tls = root.join("preview-tls");
    std::fs::create_dir_all(&tls).map_err(|_| "router_not_ready: TLS directory unavailable")?;
    let temporary =
        tempfile::tempdir_in(&tls).map_err(|_| "router_not_ready: TLS staging unavailable")?;
    let host = format!("www.{project}.localhost");
    let crt = temporary.path().join("leaf.crt");
    let key = temporary.path().join("leaf.key");
    let csr = temporary.path().join("leaf.csr");
    let ext = temporary.path().join("leaf.ext");
    std::fs::write(&ext, format!("subjectAltName=DNS:{host}\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n"))
        .map_err(|_| "router_not_ready: TLS extensions unavailable")?;
    for args in certificate_args(&host, &crt, &csr, &key, ca, &ext) {
        host_command(&args)?;
    }
    // Order 1649-xqet: the router serves the leaf as a FULL CHAIN (leaf, then
    // the enclave CA). A browser.open window trusts the CA through an SPKI pin,
    // and Chromium honours the pin only for a key in the chain the server
    // sends: a leaf-only chain fails with ERR_CERT_AUTHORITY_INVALID (measured
    // 2026-10-12). Pinning the CA rather than the leaf survives leaf rotation.
    let mut chain =
        std::fs::read(&crt).map_err(|_| "router_not_ready: leaf certificate unreadable")?;
    if !chain.ends_with(b"\n") {
        chain.push(b'\n');
    }
    chain.extend(
        std::fs::read(ca.join("intermediate.crt"))
            .map_err(|_| "router_not_ready: CA certificate unavailable")?,
    );
    std::fs::write(&crt, chain).map_err(|_| "router_not_ready: leaf chain unwritable")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "router_not_ready: leaf key permissions failed")?;
    }
    std::fs::rename(&key, tls.join(format!("{project}.key")))
        .map_err(|_| "router_not_ready: leaf key publication failed")?;
    std::fs::rename(&crt, tls.join(format!("{project}.crt")))
        .map_err(|_| "router_not_ready: leaf certificate publication failed")?;
    if tls_port().is_err() {
        let port = [18443, 28443, 38443, 48443, 58443]
            .into_iter()
            .find(|p| crate::port_is_available(*p))
            .ok_or("router_not_ready: no available loopback TLS port")?;
        std::fs::write(root.join("preview-tls-port"), port.to_string())
            .map_err(|_| "router_not_ready: TLS port publication failed")?;
    }
    Ok(())
}

async fn ensure_router(project: &str, debug: bool) -> Result<PathBuf, String> {
    let _lock = crate::resource_lock::acquire(
        "preview-router",
        command_budget(Duration::from_secs(5))?,
        debug,
    )?;
    // Forge startup owns CA/bootstrap/image provisioning. An MCP operation
    // cannot spend an unbounded bootstrap/build budget after its client exits.
    let ca = PathBuf::from(crate::ca_dir());
    if !ca.join("intermediate.crt").is_file() || !ca.join("intermediate.key").is_file() {
        return Err("router_not_ready: initialize the existing local CA before publication".into());
    }
    prepare_tls(project, &ca)?;
    let mut http_port = None;
    let mut router_image = crate::versioned_image_tag("router", crate::VERSION.trim());
    let mut running = false;
    if let Some(row) = inspect("tillandsias-router")? {
        // Adding a listener must not roll a newer shared router back to this
        // checkout's older VERSION. Retain its current managed image identity.
        if let Some(image) = row["ImageName"].as_str().filter(|s| !s.is_empty()) {
            router_image = image.to_string();
        }
        http_port = row["HostConfig"]["PortBindings"]["8080/tcp"]
            .as_array()
            .and_then(|p| p.first())
            .and_then(|p| p["HostPort"].as_str())
            .and_then(|p| p.parse::<u16>().ok());
        let bindings = &row["HostConfig"]["PortBindings"]["8443/tcp"];
        let expected = tls_port()?.to_string();
        let correct = bindings.as_array().is_some_and(|ports| {
            ports
                .iter()
                .any(|p| p["HostIp"] == "127.0.0.1" && p["HostPort"] == expected)
        });
        if !correct {
            podman_at(Step::Router, &["rm", "--force", "tillandsias-router"])?;
        } else {
            running = row["State"]["Status"] == "running";
        }
    }
    if !running {
        podman_at(Step::Router, &["image", "exists", &router_image]).map_err(
            |_| "router_not_ready: managed router image must be initialized before publication",
        )?;
        let port = http_port
            .map(Ok)
            .unwrap_or_else(|| crate::select_router_host_port(None, debug))?;
        let args = crate::build_router_run_args(&ca, &router_image, port);
        let mut command = vec!["run"];
        command.extend(args.iter().map(String::as_str));
        podman_at(Step::Router, &command)?;
    }
    Ok(ca)
}

fn strict_reload() -> Result<(), String> {
    podman_at(
        Step::Router,
        &[
            "exec",
            "tillandsias-router",
            "/usr/local/bin/router-reload.sh",
        ],
    )
    .map(|_| ())
    .map_err(|_| "router_not_ready: Caddy rejected or could not reload configuration".into())
}

/// 1637-5765: route `<service>.<project>` to a toolchain dev server (Flutter's
/// `run -d web-server`) for one session, over plain HTTP: the preview TLS leaf
/// is issued for `www.<project>` only. Returns the URL a browser opens.
pub(crate) fn add_dev_route(
    service: &str,
    project: &str,
    upstream: &str,
    port: u16,
    debug: bool,
) -> Result<String, String> {
    let _lock = crate::resource_lock::acquire(
        "preview-router",
        command_budget(Duration::from_secs(5))?,
        debug,
    )?;
    let route = crate::RouterRoute::public_service(format!("{service}.{project}"), upstream, port);
    let mut routes = read_routes(debug)?;
    routes.retain(|r| r.subdomain != route.subdomain);
    routes.push(route);
    crate::write_router_routes(&routes, debug)?;
    strict_reload()?;
    let published = podman_at(Step::Router, &["port", "tillandsias-router", "8080/tcp"])?;
    let host_port = published
        .lines()
        .find_map(|l| l.rsplit(':').next()?.trim().parse::<u16>().ok())
        .ok_or("router_not_ready: the router publishes no host port")?;
    Ok(crate::project_service_url(service, project, host_port))
}

/// Remove the session's route, only while it still points at `upstream`: a
/// newer session for the same lane replaced it and owns it now.
pub(crate) fn remove_dev_route(
    service: &str,
    project: &str,
    upstream: &str,
    debug: bool,
) -> Result<(), String> {
    let _lock = crate::resource_lock::acquire(
        "preview-router",
        command_budget(Duration::from_secs(5))?,
        debug,
    )?;
    let subdomain = format!("{service}.{project}");
    let mut routes = read_routes(debug)?;
    let count = routes.len();
    routes.retain(|r| !(r.subdomain == subdomain && r.upstream_host == upstream));
    if count != routes.len() {
        crate::write_router_routes(&routes, debug)?;
        strict_reload()?;
    }
    Ok(())
}

fn read_routes(debug: bool) -> Result<Vec<crate::RouterRoute>, String> {
    let path = crate::router_route_registry_path();
    if path.exists() {
        let text = std::fs::read_to_string(path)
            .map_err(|_| "router_not_ready: route registry unreadable")?;
        return serde_json::from_str(&text).map_err(|_| {
            "router_not_ready: malformed route registry; preserving unrelated routes".into()
        });
    }
    crate::read_router_routes(debug)
}

async fn probe_route(project: &str, ca: &Path) -> Result<(), String> {
    let route = read_routes(false)?
        .into_iter()
        .find(|r| r.subdomain == format!("www.{project}") && r.public && r.preview_tls)
        .ok_or("router_not_ready: preview route is absent")?;
    let cert = std::fs::read(ca.join("intermediate.crt"))
        .map_err(|_| "router_not_ready: CA certificate unavailable")?;
    let cert = reqwest::Certificate::from_pem(&cert)
        .map_err(|_| "router_not_ready: invalid CA certificate")?;
    let host = format!("www.{project}.localhost");
    let port = tls_port()?;
    let client = reqwest::Client::builder()
        .no_proxy()
        .add_root_certificate(cert)
        .resolve(&host, std::net::SocketAddr::from(([127, 0, 0, 1], port)))
        .redirect(reqwest::redirect::Policy::none())
        .timeout(command_budget(Duration::from_secs(2))?)
        .build()
        .map_err(|_| "router_not_ready: TLS verifier unavailable")?;
    let response = client
        .get(url(project)?)
        .send()
        .await
        .map_err(|_| "router_not_ready: exact-hostname CA-verified HTTPS probe failed")?;
    if response.status().is_server_error() {
        return Err("router_not_ready: HTTPS upstream unhealthy".into());
    }
    if response
        .headers()
        .get("X-Tillandsias-Preview")
        .and_then(|h| h.to_str().ok())
        != Some(route.upstream_host.as_str())
    {
        return Err("router_not_ready: effective HTTPS configuration is stale".into());
    }
    Ok(())
}

async fn ready_backend(name: &str) -> Result<(), String> {
    RPC_DEADLINE
        .scope(
            Instant::now() + command_budget(Duration::from_secs(30))?,
            ready_backend_inner(name),
        )
        .await
}

async fn ready_backend_inner(name: &str) -> Result<(), String> {
    let deadline = Instant::now() + Duration::from_secs(30);
    while Instant::now() < deadline {
        let Some(row) = inspect(name)? else {
            return Err("runtime_not_ready: preview disappeared".into());
        };
        if row["State"]["Status"] != "running" {
            // Surface the guard's stable refusal without returning config/log
            // contents. Every other failed start remains runtime_not_ready.
            if podman_at(Step::Ready, &["logs", "--tail", "20", name])
                .is_ok_and(|s| s.contains("remote_binding_forbidden"))
            {
                return Err(
                    "remote_binding_forbidden: local preview refuses remote bindings".into(),
                );
            }
            return Err("runtime_not_ready: managed runtime exited".into());
        }
        let endpoint = format!("http://{name}:8080/");
        if let Ok(code) = podman_at(
            Step::Ready,
            &[
                "exec",
                "tillandsias-router",
                "curl",
                "--noproxy",
                "*",
                "-s",
                "-o",
                "/dev/null",
                "--max-time",
                "2",
                "-w",
                "%{http_code}",
                &endpoint,
            ],
        ) && code
            .trim()
            .parse::<u16>()
            .is_ok_and(|c| (200..500).contains(&c))
        {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    Err("runtime_not_ready: preview did not become ready within 30 seconds".into())
}

fn remove_route(project: &str, debug: bool) -> Result<(), String> {
    let mut routes = read_routes(debug)?;
    let subdomain = format!("www.{project}");
    let count = routes.len();
    routes.retain(|r| r.subdomain != subdomain);
    if count != routes.len() {
        crate::write_router_routes(&routes, debug)?;
    }
    // Reconcile effective Caddy state even if an earlier failed reload already
    // removed the desired row. An absent router cannot retain an active route.
    if inspect("tillandsias-router")?.is_some() {
        strict_reload()?;
    }
    Ok(())
}

async fn publish_locked(
    project: &str,
    instance: &str,
    runtime: &str,
    debug: bool,
) -> Result<Value, String> {
    let live = resolve_live(project, instance)?;
    let profile = select_profile(runtime, &live.configs)?;
    let name = format!("tillandsias-{project}-web");
    let old = inspect(&name)?;
    check_owner(old.as_ref(), instance, Some(&live.forge_id))?;
    // Resolve source/profile/image/TLS before touching the previous runtime.
    // 1625-un54: a missing profile image is BUILT here, host-side and bounded,
    // instead of refused with an init step nothing ever ran. The build spends
    // its own budget; the rest of the publish keeps what it had left.
    let remaining = RPC_DEADLINE
        .try_with(|deadline| deadline.saturating_duration_since(Instant::now()))
        .unwrap_or(PUBLISH_BUDGET);
    ensure_profile_image(&profile, debug).await?;
    // 1625-6iwd: static reads a root Wrangler config's assets.directory through
    // the pinned Wrangler parser, so that image must exist for static too.
    if let (Profile::Static, [config]) = (&profile, live.configs.as_slice()) {
        ensure_profile_image(&Profile::Wrangler(config.clone()), debug).await?;
    }
    RPC_DEADLINE
        .scope(
            Instant::now() + remaining,
            publish_prepared(project, instance, debug, live, profile, old),
        )
        .await
}

async fn publish_prepared(
    project: &str,
    instance: &str,
    debug: bool,
    live: LiveSource,
    profile: Profile,
    old: Option<Value>,
) -> Result<Value, String> {
    let name = format!("tillandsias-{project}-web");
    let mounts = source_mounts(&live, &profile)?;
    let ca = ensure_router(project, debug).await?;
    let candidate = format!(
        "{name}-candidate-{}-{}",
        std::process::id(),
        chrono::Utc::now().timestamp_millis()
    );
    let args = build_local_preview_run_args(&candidate, &live, instance, &profile, &mounts);
    let mut command = vec!["run"];
    command.extend(args.iter().map(String::as_str));
    if let Err(e) = podman_at(Step::Run, &command) {
        let _ = podman_at(Step::Run, &["rm", "--force", &candidate]);
        return Err(e);
    }
    if let Err(e) = ready_backend(&candidate).await {
        let _ = podman_at(Step::Run, &["rm", "--force", &candidate]);
        return Err(e);
    }
    // Recheck the exact forge launch after candidate startup (PID reuse cannot
    // silently select a different forge). No source copy or commit is involved.
    if inspect(&live.forge_id)?
        .is_none_or(|r| !attributed_forge(&r, &crate::mcp_socket_host_dir(project, Some(instance))))
    {
        let _ = podman_at(Step::Run, &["rm", "--force", &candidate]);
        return Err("live_worktree_unavailable: source forge exited during startup".into());
    }
    let mut replacement_installed = false;
    let outcome = async {
        if old.is_some() {
            podman_at(Step::Run, &["rm", "--force", &name])?;
        }
        podman_at(Step::Run, &["rename", &candidate, &name])?;
        replacement_installed = true;
        let _router_lock = crate::resource_lock::acquire(
            "preview-router",
            command_budget(Duration::from_secs(5))?,
            debug,
        )?;
        // Explicit creation-time DNS alias survives the container rename.
        let mut route =
            crate::RouterRoute::public_service(format!("www.{project}"), &candidate, 8080);
        route.preview_tls = true;
        let mut routes = read_routes(debug)?;
        routes.retain(|r| r.subdomain != route.subdomain);
        routes.push(route);
        crate::write_router_routes(&routes, debug)?;
        strict_reload()?;
        probe_route(project, &ca).await?;
        Ok(result(
            "running",
            Some(profile.name()),
            Some(&url(project)?),
            true,
            "",
        ))
    }
    .await;
    if outcome.is_err() {
        let _ = podman_at(Step::Run, &["rm", "--force", &candidate]);
        if replacement_installed {
            let _ = podman_at(Step::Run, &["rm", "--force", &name]);
        }
        let _lock = crate::resource_lock::acquire(
            "preview-router",
            command_budget(Duration::from_secs(5))?,
            debug,
        )?;
        if replacement_installed || inspect(&name)?.is_none() {
            remove_route(project, debug)?;
        }
    } else {
        watch_source_lifetime(
            project.to_string(),
            instance.to_string(),
            live.forge_id,
            live.volume,
            live.generation,
        );
    }
    outcome
}

/// 1625-6iwd: the last failed publish/reload of each lane, for service_status.
/// In memory: it belongs to the process serving that lane's MCP socket.
static LAST_FAILURE: std::sync::Mutex<std::collections::BTreeMap<(String, String), Value>> =
    std::sync::Mutex::new(std::collections::BTreeMap::new());

/// Who can act on a reason: the host by retrying, the agent by changing the
/// project, or the operator. And which step/class it belongs to.
fn classify_failure(reason: &str) -> (&'static str, &'static str, &'static str) {
    if let Some(rest) = reason.strip_prefix("runtime_unavailable: podman failed at step ") {
        let step = [
            Step::List,
            Step::Inspect,
            Step::Image,
            Step::Source,
            Step::Router,
            Step::Run,
            Step::Ready,
        ]
        .into_iter()
        .find(|s| rest.starts_with(&format!("{} (", s.name())))
        .map(Step::name)
        .unwrap_or("publish");
        let (class, remedy) = if rest.ends_with("(transport)") {
            ("transport", "host-retry")
        } else if rest.ends_with("(timeout)") {
            ("timeout", "host-retry")
        } else {
            ("exit", "operator")
        };
        return (step, class, remedy);
    }
    let head = reason.split(':').next().unwrap_or("");
    match head {
        "source_not_found" => ("source", "absent", "agent"),
        "invalid_runtime" | "remote_binding_forbidden" => ("source", "exit", "agent"),
        "live_worktree_unavailable"
            if reason.contains("symlink")
                || reason.contains("private paths")
                || reason.contains("escapes") =>
        {
            ("source", "exit", "agent")
        }
        "live_worktree_unavailable" => ("source", "exit", "operator"),
        "router_not_ready" => ("router", "exit", "operator"),
        "runtime_not_ready" if reason.contains("image still building") => {
            ("image", "timeout", "host-retry")
        }
        "runtime_not_ready" => ("ready", "timeout", "host-retry"),
        "runtime_unavailable" if reason.contains("image build failed") => {
            ("image", "exit", "operator")
        }
        _ => ("publish", "exit", "operator"),
    }
}

fn record_outcome(project: &str, instance: &str, outcome: &Result<Value, String>) {
    let key = (project.to_string(), instance.to_string());
    let Ok(mut failures) = LAST_FAILURE.lock() else {
        return;
    };
    match outcome {
        Ok(_) => {
            failures.remove(&key);
        }
        Err(reason) => {
            let (step, class, remedy) = classify_failure(reason);
            failures.insert(
                key,
                json!({
                    "step": step, "class": class, "reason": reason,
                    "at": chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
                    "remedy": remedy,
                }),
            );
        }
    }
}

fn last_failure(project: &str, instance: &str) -> Option<Value> {
    LAST_FAILURE
        .lock()
        .ok()?
        .get(&(project.to_string(), instance.to_string()))
        .cloned()
}

pub(crate) async fn publish(
    project: &str,
    instance: &str,
    runtime: &str,
    debug: bool,
) -> Result<Value, String> {
    let outcome = RPC_DEADLINE
        .scope(
            Instant::now() + PUBLISH_BUDGET,
            publish_inner(project, instance, runtime, debug),
        )
        .await;
    record_outcome(project, instance, &outcome);
    outcome
}

pub(crate) async fn status(project: &str, instance: &str) -> Result<Value, String> {
    let mut value = RPC_DEADLINE
        .scope(
            Instant::now() + Duration::from_secs(30),
            status_inner(project, instance),
        )
        .await?;
    // 1625-6iwd: a failed publish leaves no container, so status used to say
    // nothing. Report the last failure: step, class, reason, time, remedy.
    if let Some(failure) = last_failure(project, instance) {
        value["last_failure"] = failure;
    }
    Ok(value)
}

pub(crate) async fn stop(project: &str, instance: &str, debug: bool) -> Result<Value, String> {
    RPC_DEADLINE
        .scope(
            Instant::now() + Duration::from_secs(30),
            stop_inner(project, instance, debug),
        )
        .await
}

pub(crate) async fn reload(project: &str, instance: &str, debug: bool) -> Result<Value, String> {
    let outcome = RPC_DEADLINE
        .scope(
            Instant::now() + PUBLISH_BUDGET,
            reload_inner(project, instance, debug),
        )
        .await;
    record_outcome(project, instance, &outcome);
    outcome
}

async fn publish_inner(
    project: &str,
    instance: &str,
    runtime: &str,
    debug: bool,
) -> Result<Value, String> {
    validate_identity(project, instance)?;
    // Reject invalid profile before any runtime or router mutation.
    if !["auto", "static", "wrangler"].contains(&runtime) {
        return Err("invalid_runtime: expected auto, static or wrangler".into());
    }
    if !crate::runtime_phase::container_mutations_allowed() {
        return Err(crate::runtime_phase::refusal("publish local preview"));
    }
    let _lock = crate::resource_lock::acquire(
        &format!("preview-{project}"),
        command_budget(Duration::from_secs(5))?,
        debug,
    )?;
    publish_locked(project, instance, runtime, debug).await
}

async fn status_inner(project: &str, instance: &str) -> Result<Value, String> {
    validate_identity(project, instance)?;
    let row = match inspect(&format!("tillandsias-{project}-web")) {
        Ok(Some(row)) => row,
        Ok(None) => return Ok(result("stopped", None, None, false, "")),
        Err(reason) => return Ok(result("unknown", None, None, false, &reason)),
    };
    let runtime = label(&row, PROFILE);
    if check_owner(Some(&row), instance, None).is_err() {
        return Ok(result(
            "unknown",
            Some(runtime),
            None,
            false,
            "lane_conflict: preview is owned by another lane",
        ));
    }
    let state = match row["State"]["Status"].as_str() {
        Some("running") => "running",
        Some("created") => "starting",
        Some("exited" | "dead") => "failed",
        Some("stopped") => "stopped",
        _ => "unknown",
    };
    let ca = PathBuf::from(crate::ca_dir());
    let ready = state == "running" && probe_route(project, &ca).await.is_ok();
    let preview_url = url(project).ok();
    Ok(result(
        state,
        Some(runtime),
        preview_url.as_deref(),
        ready,
        if ready {
            ""
        } else {
            "router_not_ready: HTTPS route is not verified ready"
        },
    ))
}

async fn stop_inner(project: &str, instance: &str, debug: bool) -> Result<Value, String> {
    validate_identity(project, instance)?;
    if !crate::runtime_phase::container_mutations_allowed() {
        return Err(crate::runtime_phase::refusal("stop local preview"));
    }
    let _lock = crate::resource_lock::acquire(
        &format!("preview-{project}"),
        command_budget(Duration::from_secs(5))?,
        debug,
    )?;
    let name = format!("tillandsias-{project}-web");
    let row = inspect(&name)?;
    check_owner(row.as_ref(), instance, None)?;
    if row.is_some() {
        podman_at(Step::Run, &["rm", "--force", &name])?;
    }
    let _router_lock = crate::resource_lock::acquire(
        "preview-router",
        command_budget(Duration::from_secs(5))?,
        debug,
    )?;
    remove_route(project, debug)?;
    Ok(result(
        "stopped",
        row.as_ref().map(|r| label(r, PROFILE)),
        None,
        false,
        "",
    ))
}

async fn reload_inner(project: &str, instance: &str, debug: bool) -> Result<Value, String> {
    validate_identity(project, instance)?;
    if !crate::runtime_phase::container_mutations_allowed() {
        return Err(crate::runtime_phase::refusal("reload local preview"));
    }
    let _lock = crate::resource_lock::acquire(
        &format!("preview-{project}"),
        command_budget(Duration::from_secs(5))?,
        debug,
    )?;
    let row = inspect(&format!("tillandsias-{project}-web"))?
        .ok_or("not_running: no preview to reload")?;
    check_owner(Some(&row), instance, None)?;
    if row["State"]["Status"] != "running" {
        return Err("not_running: preview is not running".into());
    }
    let runtime = label(&row, PROFILE);
    if !["static", "wrangler"].contains(&runtime) {
        return Err("invalid_runtime: recorded profile is unavailable".into());
    }
    publish_locked(project, instance, runtime, debug).await
}

/// Called only after the launcher proves no forge remains for this lane. This
/// also releases sibling volume-subpath mounts before the RAM source disappears.
pub(crate) fn cleanup_departed_lane(
    project: &str,
    instance: &str,
    debug: bool,
) -> Result<(), String> {
    let _lock = crate::resource_lock::acquire(
        &format!("preview-{project}"),
        Duration::from_secs(120),
        debug,
    )?;
    let name = format!("tillandsias-{project}-web");
    if let Some(row) = inspect(&name)? {
        if label(&row, OWNER) != instance {
            return Ok(());
        }
        podman_at(Step::Run, &["rm", "--force", &name])?;
    }
    let _router_lock =
        crate::resource_lock::acquire("preview-router", Duration::from_secs(120), debug)?;
    remove_route(project, debug)
}

fn watch_source_lifetime(
    project: String,
    instance: String,
    forge_id: String,
    volume: String,
    generation: String,
) {
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_secs(2));
            let Ok(text) = podman_at(Step::List, &["ps", "--no-trunc", "--format", "{{.ID}}"])
            else {
                continue;
            };
            if text.lines().any(|id| id == forge_id) {
                continue;
            }
            let Ok(_source) =
                crate::resource_lock::acquire(&volume, Duration::from_secs(120), false)
            else {
                continue;
            };
            // Another forge may have replaced this launch. Never delete its
            // preview/source; old launch ownership is checked under the lock.
            let Ok(_lock) = crate::resource_lock::acquire(
                &format!("preview-{project}"),
                Duration::from_secs(120),
                false,
            ) else {
                continue;
            };
            let name = format!("tillandsias-{project}-web");
            match inspect(&name) {
                Ok(Some(row))
                    if label(&row, OWNER) == instance && label(&row, FORGE) == forge_id =>
                {
                    if podman_at(Step::Run, &["rm", "--force", &name]).is_err() {
                        continue;
                    }
                }
                Ok(Some(_)) => break, // a replacement owns this project now
                Ok(None) => {}
                Err(_) => continue,
            }
            let Ok(_router) =
                crate::resource_lock::acquire("preview-router", Duration::from_secs(5), false)
            else {
                continue;
            };
            if remove_route(&project, false).is_err() {
                continue;
            }
            let Ok(volumes) = podman_at(Step::Source, &["volume", "ls", "--format", "{{.Name}}"])
            else {
                continue;
            };
            if !volumes.lines().any(|name| name == volume) {
                break;
            }
            let Ok(text) = podman_at(Step::Source, &["volume", "inspect", &volume]) else {
                continue;
            };
            let Ok(info) = serde_json::from_str::<Vec<Value>>(&text) else {
                continue;
            };
            if !info
                .first()
                .is_some_and(|row| row["Labels"]["tillandsias.source.launch"] == generation)
            {
                break; // a new launch's volume must never be removed
            }
            // Non-force removal refuses if a replacement forge still uses it.
            if podman_at(Step::Source, &["volume", "rm", &volume]).is_err() {
                continue;
            }
            break;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::process::ExitStatusExt;

    /// The ignored live fixture below drives real podman directly.
    fn podman(args: &[&str]) -> Result<String, String> {
        podman_at(Step::Run, args)
    }

    fn output(code: i32, stdout: &str, stderr: &str) -> std::io::Result<std::process::Output> {
        Ok(std::process::Output {
            status: std::process::ExitStatus::from_raw(code << 8),
            stdout: stdout.as_bytes().to_vec(),
            stderr: stderr.as_bytes().to_vec(),
        })
    }

    /// Install a fake podman for THIS thread only; removed on drop.
    struct Fake;
    impl Fake {
        fn install(f: impl Fn(&[&str]) -> std::io::Result<std::process::Output> + 'static) -> Self {
            FAKE_PODMAN.with(|fake| *fake.borrow_mut() = Some(Box::new(f)));
            Fake
        }
    }
    impl Drop for Fake {
        fn drop(&mut self) {
            FAKE_PODMAN.with(|fake| *fake.borrow_mut() = None);
        }
    }

    const SECRET: &str = "CLOUDFLARE_API_TOKEN=s3cr3t-from-podman-stderr";

    /// 1625-6iwd criterion 1: podman failing at listing, inspection, image,
    /// run and router start yields a DIFFERENT reason per step, and none of
    /// them carries podman's output. Trunk before this change mapped every one
    /// of these to the single literal "runtime_unavailable: Podman operation failed".
    #[test]
    fn each_podman_step_fails_with_its_own_reason_and_withholds_output() {
        let _fake = Fake::install(|_| output(125, SECRET, SECRET));
        let reasons: Vec<String> = [
            Step::List,
            Step::Inspect,
            Step::Image,
            Step::Source,
            Step::Router,
            Step::Run,
            Step::Ready,
        ]
        .into_iter()
        .map(|step| podman_at(step, &["anything"]).unwrap_err())
        .collect();
        let distinct: std::collections::BTreeSet<_> = reasons.iter().collect();
        assert_eq!(distinct.len(), reasons.len(), "{reasons:?}");
        for reason in &reasons {
            assert!(
                !reason.contains("s3cr3t") && !reason.contains("CLOUDFLARE"),
                "{reason}"
            );
            assert!(reason.ends_with("(exit)"), "{reason}");
        }
        assert_eq!(
            reasons[0],
            "runtime_unavailable: podman failed at step list (exit)"
        );
        let source = include_str!("local_web_preview.rs");
        assert!(
            !source.contains(&format!("{}{}", "Podman operation ", "failed\".into()")),
            "the one-string-for-every-step literal is gone"
        );
    }

    /// The real call sites carry their step: `inspect` lists first (list), then
    /// inspects (inspect); classes separate transport, timeout and exit.
    #[test]
    fn call_sites_name_their_step_and_class() {
        {
            let _fake = Fake::install(|args| {
                if args[0] == "ps" {
                    Err(std::io::Error::other("socket gone"))
                } else {
                    output(0, "", "")
                }
            });
            assert_eq!(
                inspect("tillandsias-p-web").unwrap_err(),
                "runtime_unavailable: podman failed at step list (transport)"
            );
        }
        {
            let _fake = Fake::install(|args| {
                if args[0] == "ps" {
                    output(0, "tillandsias-p-web abc\n", "")
                } else {
                    Err(std::io::Error::from(std::io::ErrorKind::TimedOut))
                }
            });
            assert_eq!(
                inspect("tillandsias-p-web").unwrap_err(),
                "runtime_unavailable: podman failed at step inspect (timeout)"
            );
        }
        {
            // `image exists` unreachable is NOT "absent, so build it".
            let _fake = Fake::install(|_| Err(std::io::Error::other("no podman")));
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap();
            assert_eq!(
                rt.block_on(ensure_profile_image(&Profile::Static, false))
                    .unwrap_err(),
                "runtime_unavailable: podman failed at step image (transport)"
            );
        }
    }

    /// 1625-6iwd criterion 2: the last failure survives for service_status, with
    /// step, class, reason, time and remedy; a later success clears it.
    #[test]
    fn last_failure_is_recorded_with_step_and_remedy_and_cleared_by_success() {
        let (project, instance) = ("rec-6iwd", "inst");
        record_outcome(
            project,
            instance,
            &Err("runtime_unavailable: podman failed at step run (exit)".into()),
        );
        let failure = last_failure(project, instance).expect("recorded");
        assert_eq!(failure["step"], "run");
        assert_eq!(failure["class"], "exit");
        assert_eq!(failure["remedy"], "operator");
        assert!(failure["at"].as_str().is_some_and(|t| t.ends_with('Z')));
        record_outcome(project, instance, &Err(NO_SERVABLE_ROOT.into()));
        let failure = last_failure(project, instance).unwrap();
        assert_eq!(
            (
                failure["step"].as_str(),
                failure["class"].as_str(),
                failure["remedy"].as_str()
            ),
            (Some("source"), Some("absent"), Some("agent"))
        );
        record_outcome(project, instance, &Ok(json!({"state": "running"})));
        assert!(last_failure(project, instance).is_none());
        for (reason, expected) in [
            (
                "runtime_unavailable: podman failed at step list (transport)",
                ("list", "transport", "host-retry"),
            ),
            (
                "runtime_unavailable: podman failed at step ready (timeout)",
                ("ready", "timeout", "host-retry"),
            ),
            (
                "router_not_ready: initialize the existing local CA before publication",
                ("router", "exit", "operator"),
            ),
            (
                "runtime_not_ready: image still building on the host after 300 s (timeout); retry publish_local",
                ("image", "timeout", "host-retry"),
            ),
            (
                "remote_binding_forbidden: local preview refuses remote bindings",
                ("source", "exit", "agent"),
            ),
        ] {
            assert_eq!(classify_failure(reason), expected, "{reason}");
        }
    }

    /// A fake live forge: `present` lists project-relative paths that exist;
    /// `inspector` is the pinned-Wrangler parser's JSON line.
    fn fake_forge(present: &'static [&'static str], inspector: &'static str) -> (Fake, LiveSource) {
        let fake = Fake::install(move |args| {
            let root = "/home/forge/src/proj/";
            match args {
                ["exec", _, "sh", "-c", script, "sh", path] => {
                    let rel = path.strip_prefix(root).unwrap_or("");
                    let is_dir = present.iter().any(|p| p.starts_with(&format!("{rel}/")));
                    let is_file = present.contains(&rel);
                    let hit = if script.contains("-d") {
                        is_dir
                    } else if script.contains("-f") {
                        is_file
                    } else {
                        is_dir || is_file
                    };
                    output(0, if hit { "present" } else { "" }, "")
                }
                // verify_subset: realpath -e exits 1 on a missing path, which
                // is exactly what trunk turned into "Podman operation failed".
                ["exec", _, "realpath", "-e", "--", path] => {
                    let rel = path.strip_prefix(root).unwrap_or("");
                    if present
                        .iter()
                        .any(|p| *p == rel || p.starts_with(&format!("{rel}/")))
                    {
                        output(0, path, "")
                    } else {
                        output(1, "", "realpath: No such file or directory")
                    }
                }
                ["exec", _, "find", ..] => output(0, "", ""),
                ["run", ..] => output(0, inspector, ""),
                _ => output(125, "", SECRET),
            }
        });
        let live = LiveSource {
            forge_id: "forge".into(),
            volume: "vol".into(),
            generation: "g".into(),
            project: "proj".into(),
            configs: vec![],
        };
        (fake, live)
    }

    /// 1625-6iwd criteria 3 and 4: the visual-chess static failure, replayed.
    /// No var/html, public, dist or root index.html -> a source-selection
    /// reason. Trunk reached `realpath -e .../index.html`, which exits 1.
    #[test]
    fn static_without_a_servable_root_is_source_not_found() {
        let (_fake, live) = fake_forge(&["README.md", "src/main.rs"], "");
        assert_eq!(
            source_mounts(&live, &Profile::Static).unwrap_err(),
            NO_SERVABLE_ROOT
        );
        // The exact exec trunk ran for this tree still exits non-zero here,
        // and podman_at names it (it no longer says "Podman operation failed").
        assert_eq!(
            verify_subset(&live, "index.html").unwrap_err(),
            "runtime_unavailable: podman failed at step source (exit)"
        );
    }

    /// 1625-6iwd criterion 6: visual-chess's own shape. wrangler.jsonc says
    /// assets.directory ./dist and dist/ was never built. Static AND Wrangler
    /// both say so and point at the build, instead of a podman error.
    #[test]
    fn configured_assets_directory_absent_names_the_build_step() {
        let (_fake, mut live) = fake_forge(
            &["wrangler.jsonc", "src/lib.rs"],
            r#"{"remote":false,"assets":"dist","main":null,"build":null,"raw":"{}"}"#,
        );
        live.configs = vec!["wrangler.jsonc".into()];
        let expected = "source_not_found: assets directory dist (configured in wrangler.jsonc) does not exist yet; wrangler.jsonc declares no build.command; build the project first";
        assert_eq!(
            source_mounts(&live, &Profile::Static).unwrap_err(),
            expected
        );
        assert_eq!(
            source_mounts(&live, &Profile::Wrangler("wrangler.jsonc".into())).unwrap_err(),
            expected
        );
        assert_eq!(
            assets_absent("dist", "wrangler.toml", Some("npm run build")),
            "source_not_found: assets directory dist (configured in wrangler.toml) does not exist yet; run its build.command first: npm run build"
        );
        // A command that could carry a credential is named by key, never echoed.
        assert_eq!(
            assets_absent("dist", "wrangler.toml", Some("API_TOKEN=x npm run build")),
            "source_not_found: assets directory dist (configured in wrangler.toml) does not exist yet; run the build.command declared in wrangler.toml first"
        );
    }

    /// 1625-6iwd criterion 5: static serves a root Wrangler config's
    /// assets.directory ahead of the fixed list (www/ is none of them).
    #[test]
    fn static_honors_the_wrangler_assets_directory() {
        let (_fake, mut live) = fake_forge(
            &["wrangler.jsonc", "www/index.html", "public/old.html"],
            r#"{"remote":true,"assets":"www","main":null,"build":null,"raw":"{}"}"#,
        );
        live.configs = vec!["wrangler.jsonc".into()];
        // remote bindings are moot for static (no Worker runs); www wins over public.
        assert_eq!(
            source_mounts(&live, &Profile::Static).unwrap(),
            vec!["type=volume,source=vol,target=/var/www,volume-subpath=proj/www,readonly=true"]
        );
        assert_eq!(
            source_mounts(&live, &Profile::Wrangler("wrangler.jsonc".into())).unwrap_err(),
            "remote_binding_forbidden: local preview refuses remote bindings"
        );
    }

    /// 1625-un54: the image publish_local checks (and builds on a miss) is the
    /// exact version alias init tags, never an untagged `:latest` resolution,
    /// and the build name is one image_specs knows. The ensure takes no MCP
    /// input: its only argument is the profile.
    #[test]
    fn profile_images_are_the_init_version_aliases() {
        let version = crate::VERSION.trim();
        assert_eq!(
            Profile::Static.image(),
            format!("localhost/tillandsias-web:v{version}")
        );
        assert_eq!(
            Profile::Wrangler("wrangler.jsonc".into()).image(),
            format!("localhost/tillandsias-web-wrangler:v{version}")
        );
        assert_eq!(Profile::Static.image_name(), "web");
        assert_eq!(Profile::Wrangler("x".into()).image_name(), "web-wrangler");
        assert!(IMAGE_ENSURE_BUDGET > PUBLISH_BUDGET);
        let source = include_str!("local_web_preview.rs");
        assert!(
            !source.contains(&format!(
                "{}{}",
                "initialize the managed runtime image ", "before publication"
            )),
            "the init refusal names a step nothing runs; publish builds instead"
        );
    }

    /// Explicit operator-authorized fallback when the normal launcher cannot
    /// pass its version/auth gates. Uses the REAL confirmed project cache,
    /// production bounded-source preparation and per-lane MCP listener. Only
    /// the fixture mirror gets the read-only seed; the forge clones from it.
    /// No seed/host checkout is mounted into the forge or preview.
    #[test]
    #[ignore = "live opt-in fixture; creates labeled disposable mirror/forge and holds MCP listener until stop file"]
    fn live_target_fixture_1552() {
        assert_eq!(
            std::env::var("TILLANDSIAS_PREVIEW_FIXTURE_OK").as_deref(),
            Ok("1552-238z")
        );
        let _seam = crate::runtime_assets::podman_seam_lock();
        let _env = crate::test_support::env_lock();
        let project = "tillandsias.org";
        let instance = "sol1552";
        crate::local_projects::validate_project_label(project)
            .expect("real confirmed host attribution required; no fixture cache approval");
        let seed = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../../tillandsias.org")
            .canonicalize()
            .expect("sibling tillandsias.org checkout required for live fixture");
        let mirror = "tillandsias-preview-fixture-mirror-sol1552";
        let forge = crate::forge_container_name_for_mode_with_instance(
            project,
            crate::ForgeAgentMode::Maintenance,
            Some(instance),
        );
        assert!(
            inspect(mirror).unwrap().is_none(),
            "fixture mirror already exists; refuse to overwrite"
        );
        assert!(
            inspect(&forge).unwrap().is_none(),
            "fixture forge already exists; refuse to overwrite"
        );
        assert!(
            inspect(&format!("tillandsias-{project}-web"))
                .unwrap()
                .is_none(),
            "existing user preview must not be disturbed"
        );
        unsafe {
            std::env::set_var("TILLANDSIAS_FORGE_INSTANCE", instance);
        }
        let _source_guard = crate::prepare_forge_ram_workspace(project, false, false).unwrap();
        let volume = crate::local_projects::ram_workspace_volume(project, instance);
        let mirror_mount = format!(
            "type=bind,source={},target=/seed,readonly=true",
            seed.display()
        );
        podman(&["run", "--detach", "--pull=never", "--name", mirror, "--label", "tillandsias.fixture=1552-238z",
            "--network", crate::ENCLAVE_NET, "--security-opt=label=disable", "--userns=keep-id",
            "--tmpfs", "/srv/git:rw,size=64m,mode=1777", "--mount", &mirror_mount,
            "--entrypoint", "/bin/sh", "localhost/tillandsias-git:latest", "-c",
            "git clone --bare /seed /srv/git/tillandsias.org && exec git daemon --reuseaddr --export-all --base-path=/srv/git --listen=0.0.0.0 --port=9418"]).unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if podman(&[
                "exec",
                mirror,
                "test",
                "-f",
                "/srv/git/tillandsias.org/HEAD",
            ])
            .is_ok()
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "fixture mirror clone readiness timed out"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
        let source = format!("{volume}:/home/forge/src:rw,z");
        let socket_dir = crate::mcp_socket_host_dir(project, Some(instance));
        let socket_mount = format!(
            "type=bind,source={},target=/run/host/tillandsias-mcp,readonly=true",
            socket_dir.display()
        );
        let mut spec = tillandsias_podman::ContainerSpec::new("localhost/tillandsias-forge:latest")
            .name(&forge)
            .network(crate::ENCLAVE_NET)
            .memory_budget(tillandsias_core::forge_budget::ForgeBudget::for_this_host());
        spec = spec
            .tmpfs("/tmp:rw,size=256m,mode=1777")
            .tmpfs("/run/user/1000:rw,size=64m,mode=0700")
            .tmpfs("/opt/cheatsheets:rw,size=8m,mode=0755")
            .tmpfs(crate::FORGE_SSH_QUARANTINE_TMPFS)
            .tmpfs(crate::FORGE_GH_QUARANTINE_TMPFS)
            .entrypoint("/bin/sh");
        let mut args = vec![
            "run".to_string(),
            "--detach".into(),
            "--pull=never".into(),
            "--label".into(),
            "tillandsias.fixture=1552-238z".into(),
            "--security-opt=label=disable".into(),
            "--userns=keep-id".into(),
            "-v".into(),
            source,
            "--mount".into(),
            socket_mount,
        ];
        args.extend(spec.build_run_args());
        args.extend([
            "-c".into(),
            format!(
                "git clone git://{mirror}/{project} /home/forge/src/{project} && exec sleep 7200"
            ),
        ]);
        podman(&args.iter().map(String::as_str).collect::<Vec<_>>()).unwrap();
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            if podman(&[
                "exec",
                &forge,
                "test",
                "-f",
                "/home/forge/src/tillandsias.org/wrangler.jsonc",
            ])
            .is_ok()
            {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "fixture forge mirror clone readiness timed out"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
        let live = resolve_live(project, instance).unwrap();
        let profile = select_profile("auto", &live.configs).unwrap();
        let slices =
            source_mounts(&live, &profile).expect("pinned official parser and safe source slicing");
        let ca = crate::ensure_ca_bundle(false)
            .unwrap()
            .join("intermediate.crt");
        let receipt = json!({"packet":"1552-238z", "fixture":true,
            "attribution":"existing confirmed cloud project cache; real accepting lane listener",
            "forge":forge,"mirror":mirror,"volume":volume,"socket":socket_dir.join("mcp.sock"),
            "ca":ca,"source_mount_count":slices.len(),"stop_file":"/tmp/opencode/sol-preview-fixture.stop"});
        std::fs::write(
            "/tmp/opencode/sol-preview-fixture.json",
            serde_json::to_vec_pretty(&receipt).unwrap(),
        )
        .unwrap();
        println!("READY: {receipt}");
        let hold_deadline = Instant::now() + Duration::from_secs(7200);
        while !Path::new("/tmp/opencode/sol-preview-fixture.stop").exists()
            && Instant::now() < hold_deadline
        {
            std::thread::sleep(Duration::from_secs(1));
        }
        let _ = podman(&["rm", "--force", &forge]);
        crate::cleanup_forge_ram_workspace(project, false).unwrap();
        let _ = podman(&["rm", "--force", mirror]);
    }

    fn with_stub<T>(script: &str, test: impl FnOnce(&Path) -> T) -> T {
        let _seam = crate::runtime_assets::podman_seam_lock();
        let _env = crate::test_support::env_lock();
        let temp = tempfile::tempdir().unwrap();
        let stub = temp.path().join("podman-stub");
        let log = temp.path().join("calls");
        std::fs::write(
            &stub,
            format!(
                "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\n{script}\n",
                log.display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::create_dir(temp.path().join("proj")).unwrap();
        struct Restore(Vec<(&'static str, Option<std::ffi::OsString>)>);
        impl Drop for Restore {
            fn drop(&mut self) {
                for (name, value) in &self.0 {
                    unsafe {
                        match value {
                            Some(v) => std::env::set_var(name, v),
                            None => std::env::remove_var(name),
                        }
                    }
                }
            }
        }
        let vars = [
            "TILLANDSIAS_PODMAN_BIN",
            crate::local_projects::HOST_PROJECT_ROOT_ENV,
            crate::local_projects::CLOUD_LABEL_CACHE_ENV,
            "XDG_RUNTIME_DIR",
        ];
        let _restore = Restore(
            vars.into_iter()
                .map(|name| (name, std::env::var_os(name)))
                .collect(),
        );
        unsafe {
            std::env::set_var("TILLANDSIAS_PODMAN_BIN", &stub);
            std::env::set_var(crate::local_projects::HOST_PROJECT_ROOT_ENV, temp.path());
            std::env::set_var(
                crate::local_projects::CLOUD_LABEL_CACHE_ENV,
                temp.path().join("cloud-cache"),
            );
            std::env::set_var("XDG_RUNTIME_DIR", temp.path());
        }
        test(&log)
    }

    /// 1626-r4xm: the preview's validation sites (validate_identity behind
    /// publish/status/stop, and unique_live_instance) admit the project a lane
    /// was launched for outside the root, and still refuse any other outside
    /// label before Podman is asked anything.
    #[test]
    fn preview_admits_the_launched_outside_project_and_no_other() {
        let elsewhere = tempfile::tempdir().unwrap();
        let launched = elsewhere.path().join("r4xm-preview");
        std::fs::create_dir_all(&launched).unwrap();
        std::fs::create_dir_all(elsewhere.path().join("r4xm-preview-other")).unwrap();
        let launched = launched.canonicalize().unwrap();
        with_stub("exit 0", |log| {
            let refused = validate_identity("r4xm-preview", "default").unwrap_err();
            assert!(refused.contains("is not a known project"), "RED: {refused}");

            crate::local_projects::bind_launched_project("r4xm-preview", &launched).unwrap();
            validate_identity("r4xm-preview", "default").expect("GREEN: admitted");
            let rt = tokio::runtime::Runtime::new().unwrap();
            assert_eq!(
                rt.block_on(status("r4xm-preview", "default")).unwrap()["state"],
                "stopped"
            );
            let live = unique_live_instance("r4xm-preview").unwrap_err();
            assert!(
                live.contains("no live forge lane"),
                "past the label guard: {live}"
            );

            let calls_before = std::fs::read_to_string(log).unwrap_or_default();
            for err in [
                validate_identity("r4xm-preview-other", "default").unwrap_err(),
                unique_live_instance("r4xm-preview-other").unwrap_err(),
            ] {
                assert!(err.contains("is not a known project"), "NEGATIVE: {err}");
            }
            assert_eq!(
                std::fs::read_to_string(log).unwrap_or_default(),
                calls_before,
                "a refused label never reaches Podman"
            );
        });
    }

    #[test]
    fn inspect_failure_is_unknown_not_confirmed_absence() {
        with_stub("exit 125", |_| {
            assert!(inspect("tillandsias-proj-web").is_err());
            let rt = tokio::runtime::Runtime::new().unwrap();
            let value = rt.block_on(status("proj", "default")).unwrap();
            assert_eq!(value["state"], "unknown");
        });
        with_stub("exit 0", |_| {
            assert!(inspect("tillandsias-proj-web").unwrap().is_none());
            let rt = tokio::runtime::Runtime::new().unwrap();
            assert_eq!(
                rt.block_on(status("proj", "default")).unwrap()["state"],
                "stopped"
            );
        });
    }

    #[test]
    fn invalid_missing_and_conflicting_mutations_do_not_replace_runtime() {
        with_stub("exit 0", |log| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            assert!(
                rt.block_on(publish("proj", "default", "deploy", false))
                    .unwrap_err()
                    .starts_with("invalid_runtime:")
            );
            assert!(
                rt.block_on(publish("proj", "default", "auto", false))
                    .unwrap_err()
                    .starts_with("live_worktree_unavailable:")
            );
            assert!(
                rt.block_on(reload("proj", "default", false))
                    .unwrap_err()
                    .starts_with("not_running:")
            );
            assert_eq!(
                rt.block_on(stop("proj", "default", false)).unwrap()["state"],
                "stopped"
            );
            let calls = std::fs::read_to_string(log).unwrap();
            assert!(
                !calls
                    .lines()
                    .any(|l| l.starts_with("run ") || l.starts_with("rm "))
            );
        });
        with_stub(
            "case \"$1\" in\nps) echo tillandsias-proj-web;;\ninspect) echo '[{\"State\":{\"Status\":\"running\"},\"Config\":{\"Labels\":{\"tillandsias.preview.lane\":\"other\"}}}]';;\nesac",
            |log| {
                let rt = tokio::runtime::Runtime::new().unwrap();
                assert!(
                    rt.block_on(stop("proj", "default", false))
                        .unwrap_err()
                        .starts_with("lane_conflict:")
                );
                assert!(
                    rt.block_on(reload("proj", "default", false))
                        .unwrap_err()
                        .starts_with("lane_conflict:")
                );
                assert!(
                    !std::fs::read_to_string(log)
                        .unwrap()
                        .lines()
                        .any(|l| l.starts_with("rm "))
                );
            },
        );
    }

    #[test]
    fn source_tuple_names_do_not_alias_and_tls_publish_is_loopback_only() {
        assert_ne!(
            crate::local_projects::ram_workspace_volume("a-b", "c"),
            crate::local_projects::ram_workspace_volume("a", "b-c")
        );
        with_stub("exit 0", |_| {
            let root = router_dir();
            std::fs::create_dir_all(root.join("preview-tls")).unwrap();
            std::fs::write(root.join("preview-tls-port"), "18443").unwrap();
            let args = crate::build_router_run_args(Path::new("/ca"), "managed-router", 18080);
            assert!(args.contains(&"127.0.0.1:18443:8443".into()));
            assert!(!args.iter().any(|a| a.contains("0.0.0.0:")
                || a.ends_with(":2019")
                || a.contains("intermediate.key")));
        });
    }

    #[test]
    fn profiles_accept_assets_only_and_refuse_ambiguity() {
        assert_eq!(select_profile("auto", &[]).unwrap(), Profile::Static);
        assert_eq!(
            select_profile("auto", &["wrangler.jsonc".into()]).unwrap(),
            Profile::Wrangler("wrangler.jsonc".into())
        );
        assert!(select_profile("auto", &["wrangler.json".into(), "wrangler.toml".into()]).is_err());
        assert!(select_profile("wrangler", &[]).is_err());
        assert!(
            select_profile("deploy", &[])
                .unwrap_err()
                .starts_with("invalid_runtime:")
        );
    }

    #[test]
    fn lane_and_launch_ownership_fail_closed() {
        let row = json!({"Config":{"Labels":{OWNER:"w1", FORGE:"launch-a"}}});
        assert!(check_owner(Some(&row), "w1", Some("launch-a")).is_ok());
        assert!(
            check_owner(Some(&row), "w2", None)
                .unwrap_err()
                .starts_with("lane_conflict:")
        );
        assert!(check_owner(Some(&row), "w1", Some("launch-b")).is_err());
        assert!(check_owner(Some(&json!({})), "w1", None).is_err());
        assert!(validate_components("../../secret", "default").is_err());
        assert!(validate_components("project", "../other").is_err());
        assert!(validate_components("tillandsias.org", "default").is_ok());
    }

    #[test]
    fn live_identity_requires_exact_listener_mount() {
        let row = json!({"State":{"Status":"running"},"Mounts":[{"Destination":"/run/host/tillandsias-mcp","Source":"/lane/proj-w1"}]});
        assert!(attributed_forge(&row, Path::new("/lane/proj-w1")));
        assert!(!attributed_forge(&row, Path::new("/lane/proj-w2")));
        assert!(!attributed_forge(
            &json!({"State":{"Status":"running"}}),
            Path::new("/lane/proj-w1")
        ));
    }

    #[test]
    fn live_tmpfs_reference_is_project_scoped_not_host_checkout() {
        let volume = crate::local_projects::ram_workspace_volume("proj", "w1");
        let row =
            json!({"Mounts":[{"Type":"volume","Name":volume,"Destination":"/home/forge/src"}]});
        assert_eq!(live_mount_source(&row, "proj", "w1").unwrap(), volume);
        assert!(live_mount_source(&row, "proj", "w2").is_err());
        assert!(
            live_mount_source(
                &json!({"Mounts":[{"Type":"tmpfs","Destination":"/home/forge/src"}]}),
                "proj",
                "w1"
            )
            .is_err()
        );
    }

    #[test]
    fn launch_is_read_only_private_and_has_no_host_port_or_token() {
        let live = LiveSource {
            forge_id: "launch-a".into(),
            volume: "ram-volume".into(),
            generation: "launch-generation".into(),
            project: "proj".into(),
            configs: vec![],
        };
        let mount = subset_mount(&live, "var/html", "/srv/preview/var/html").unwrap();
        let args = build_local_preview_run_args(
            "tillandsias-proj-web",
            &live,
            "w1",
            &Profile::Wrangler("wrangler.jsonc".into()),
            &[
                mount,
                "approved-config:{\"assets\":{\"directory\":\"./var/html\"}}".into(),
            ],
        );
        let joined = args.join(" ");
        assert!(joined.contains("volume-subpath=proj/var/html,readonly=true"));
        assert!(joined.contains("TILLANDSIAS_WRANGLER_CONFIG=wrangler.jsonc"));
        assert!(joined.contains("HOME=/tmp/home"));
        assert!(joined.contains("TILLANDSIAS_APPROVED_CONFIG="));
        assert!(!joined.contains("experimental-remote-bindings"));
        assert!(!joined.contains("volume-subpath=proj/wrangler"));
        assert!(!args.iter().any(|s| s == "-p"
            || s.starts_with("--publish")
            || s.contains("TOKEN")
            || s == "deploy"));
        assert!(args.contains(&crate::versioned_image_tag(
            "web-wrangler",
            crate::VERSION.trim()
        )));
        assert!(joined.contains("dev --local --ip 0.0.0.0 --port 8080"));
        assert!(safe_relative(".").is_err());
        assert!(safe_relative("../other").is_err());
        assert!(safe_relative(".env").is_err());
    }

    /// Order 1663-6mns: a config whose build had to be stripped runs under
    /// the inspector's runtime name, for both the written file and --config;
    /// the label keeps the project's own name.
    #[test]
    fn a_stripped_runtime_config_runs_under_its_runtime_name() {
        let live = LiveSource {
            forge_id: "launch-a".into(),
            volume: "ram-volume".into(),
            generation: "launch-generation".into(),
            project: "proj".into(),
            configs: vec![],
        };
        let mount = subset_mount(
            &live,
            "arkanoid-web-game/public",
            "/srv/preview/arkanoid-web-game/public",
        )
        .unwrap();
        let args = build_local_preview_run_args(
            "tillandsias-proj-web",
            &live,
            "w1",
            &Profile::Wrangler("wrangler.toml".into()),
            &[
                mount,
                "approved-config:{\"assets\":{\"directory\":\"arkanoid-web-game/public\"}}".into(),
                "approved-config-name:wrangler.toml.json".into(),
            ],
        );
        let joined = args.join(" ");
        assert!(
            joined.contains("TILLANDSIAS_WRANGLER_CONFIG=wrangler.toml.json"),
            "{joined}"
        );
        assert!(
            joined.contains("--config /srv/preview/wrangler.toml.json"),
            "{joined}"
        );
        assert!(
            !joined.contains("approved-config-name"),
            "the name is not a mount: {joined}"
        );
        assert!(
            joined.contains("volume-subpath=proj/arkanoid-web-game/public,readonly=true"),
            "{joined}"
        );
    }

    /// The inspector strips build from the runtime config (wrangler dev runs
    /// build.command at startup, measured) and names a TOML runtime .json.
    #[test]
    fn the_inspector_strips_build_from_the_runtime_config() {
        assert!(CONFIG_INSPECTOR.contains("experimental_readRawConfig"));
        assert!(CONFIG_INSPECTOR.contains("delete parsed.build;"));
        assert!(CONFIG_INSPECTOR.contains("delete e.build;"));
        assert!(CONFIG_INSPECTOR.contains("raw:runtime, runtime_name:runtimeName"));
    }

    #[test]
    fn tls_is_exact_san_and_preserves_http_and_private_routes() {
        let mut preview =
            crate::RouterRoute::public_service("www.proj", "tillandsias-proj-web", 8080);
        preview.preview_tls = true;
        let private = crate::RouterRoute::new("opencode.other", "tillandsias-other-forge", 4096);
        let rendered = crate::generate_dynamic_caddyfile(&[preview, private]);
        assert!(rendered.contains("https://www.proj.localhost:8443"));
        assert!(rendered.contains("http://www.proj.localhost:8080"));
        assert!(rendered.contains("forward_auth localhost:9090"));
        assert!(rendered.contains("proj.crt /etc/tillandsias/preview/proj.key"));
        let mut dotted = crate::RouterRoute::public_service("www.tillandsias.org", "preview", 8080);
        dotted.preview_tls = true;
        assert!(
            crate::generate_dynamic_caddyfile(&[dotted]).contains(
                "preview/tillandsias.org.crt /etc/tillandsias/preview/tillandsias.org.key"
            )
        );
        let args = certificate_args(
            "www.proj.localhost",
            Path::new("leaf.crt"),
            Path::new("leaf.csr"),
            Path::new("leaf.key"),
            Path::new("ca"),
            Path::new("leaf.ext"),
        );
        assert!(args[0].contains(&"/CN=www.proj.localhost".into()));
        assert!(
            !args
                .iter()
                .flatten()
                .any(|s| s.contains("trust") || s == "-CAcreateserial")
        );
    }

    #[test]
    fn unknown_is_not_stopped_and_host_trust_is_honest() {
        let value = result(
            "unknown",
            None,
            None,
            false,
            "runtime_unavailable: inspection failed",
        );
        assert_eq!(value["state"], "unknown");
        assert_eq!(value["tls"]["host_trust"], "unknown");
        assert_eq!(value["route_ready"], false);
    }
}

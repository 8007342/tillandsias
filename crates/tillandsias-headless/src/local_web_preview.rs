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

    fn image(&self) -> &'static str {
        match self {
            Self::Static => "tillandsias-web",
            Self::Wrangler(_) => "tillandsias-web-wrangler",
        }
    }
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

fn podman(args: &[&str]) -> Result<String, String> {
    let mut cmd = crate::podman_command();
    cmd.args(args);
    // Never echo raw diagnostics: inspect/log output can carry project secrets.
    let out = cmd
        .output_bounded(command_budget(Duration::from_secs(5))?)
        .map_err(|_| "runtime_unavailable: Podman transport failed".to_string())?;
    if !out.status.success() {
        return Err("runtime_unavailable: Podman operation failed".into());
    }
    String::from_utf8(out.stdout)
        .map_err(|_| "runtime_unavailable: invalid response encoding".into())
}

fn inspect(name: &str) -> Result<Option<Value>, String> {
    // PodmanClient::inspect_container currently turns EVERY failed command into
    // NotFound. Enumerate successfully first so a transport failure is unknown,
    // never proof of absence. Inspect races fail unknown rather than stopped.
    let names: Vec<String> = podman(&[
        "ps",
        "--all",
        "--no-trunc",
        "--format",
        "{{.Names}} {{.ID}}",
    ])?
    .lines()
    .flat_map(|line| line.split_whitespace().map(str::to_owned))
    .collect();
    if !names.iter().any(|n| n == name) {
        return Ok(None);
    }
    let text = podman(&["inspect", name])?;
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
    let actual = podman(&["exec", id, "realpath", "-e", "--", &guest])?;
    if actual.trim() != guest {
        return Err("live_worktree_unavailable: project root escapes its lane".into());
    }
    podman(&["exec", id, "test", "-d", &guest])?;
    let configs = ["wrangler.jsonc", "wrangler.json", "wrangler.toml"]
        .into_iter()
        .filter_map(|name| {
            let path = format!("{guest}/{name}");
            // Use a fixed script and positional arg; absence is successful
            // output, an exec failure is not silently treated as no config.
            let result = podman(&[
                "exec",
                id,
                "sh",
                "-c",
                "if [ -f \"$1\" ]; then printf present; fi",
                "sh",
                &path,
            ]);
            match result {
                Ok(text) if text == "present" => Some(Ok(name.to_string())),
                Ok(_) => None,
                Err(e) => Some(Err(e)),
            }
        })
        .collect::<Result<Vec<_>, _>>()?;
    let volume = live_mount_source(row, project, instance)?;
    // Verify the configured RAM backing, not just a suggestive volume name.
    let info: Vec<Value> = serde_json::from_str(&podman(&["volume", "inspect", &volume])?)
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
    let fs_type = podman(&["exec", id, "stat", "-f", "-c", "%T", "/home/forge/src"])?;
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
    let names = podman(&["ps", "--format", "{{.Names}}"])?;
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
    for mount in mounts {
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
        args.extend([
            "--label".into(),
            format!("{CONFIG}={config}"),
            "--env".into(),
            format!("TILLANDSIAS_WRANGLER_CONFIG={config}"),
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
    args.push(profile.image().into());
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
            format!("/srv/preview/{config}"),
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
    let actual = podman(&["exec", &live.forge_id, "realpath", "-e", "--", &expected])?;
    if actual.trim() != expected {
        return Err("live_worktree_unavailable: selected source is a symlink escape".into());
    }
    let forbidden = podman(&[
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
    ])?;
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
if (remote(c)) { console.log(JSON.stringify({error:'remote_binding_forbidden'})); process.exit(0); }
function relative(p) { return p ? p.replace(/^\/tmp\/approved\//, '') : null; }
console.log(JSON.stringify({assets:relative(c.assets?.directory), main:relative(c.main), raw}));
"#;

fn source_mounts(live: &LiveSource, profile: &Profile) -> Result<Vec<String>, String> {
    match profile {
        Profile::Static => {
            // Static compatibility selects a public document tree, never mounts
            // .git/.env/the forge root into a sibling. Assets-only layouts work
            // without a Wrangler config too. A root index is served individually.
            for directory in ["var/html", "public", "dist"] {
                let path = format!("/home/forge/src/{}/{directory}", live.project);
                let exists = podman(&[
                    "exec",
                    &live.forge_id,
                    "sh",
                    "-c",
                    "if [ -d \"$1\" ]; then printf present; fi",
                    "sh",
                    &path,
                ])?;
                if exists == "present" {
                    verify_subset(live, directory)?;
                    return Ok(vec![subset_mount(live, directory, "/var/www")?]);
                }
            }
            verify_subset(live, "index.html")?;
            let mut mounts = vec![subset_mount(live, "index.html", "/var/www/index.html")?];
            let root = format!("/home/forge/src/{}", live.project);
            let files = podman(&[
                "exec",
                &live.forge_id,
                "find",
                &root,
                "-maxdepth",
                "1",
                "-type",
                "f",
            ])?;
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
                let path = format!("{root}/{directory}");
                let exists = podman(&[
                    "exec",
                    &live.forge_id,
                    "sh",
                    "-c",
                    "if [ -d \"$1\" ]; then printf present; fi",
                    "sh",
                    &path,
                ])?;
                if exists == "present" {
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
            verify_subset(live, config)?;
            let config_target = format!("/srv/preview/{config}");
            let config_mount = subset_mount(live, config, &config_target)?;
            let text = podman(&[
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
                profile.image(),
                "-e",
                CONFIG_INSPECTOR,
                &config_target,
            ])
            .map_err(|_| "invalid_runtime: pinned Wrangler rejected configuration".to_string())?;
            let parsed: Value = serde_json::from_str(text.trim().lines().last().unwrap_or(""))
                .map_err(|_| "invalid_runtime: Wrangler configuration parser unavailable")?;
            if parsed["error"] == "remote_binding_forbidden" {
                return Err(
                    "remote_binding_forbidden: local preview refuses remote bindings".into(),
                );
            }
            let raw = parsed["raw"]
                .as_str()
                .ok_or("invalid_runtime: approved config unavailable")?;
            let mut mounts = vec![format!("approved-config:{raw}")];
            if let Some(assets) = parsed["assets"].as_str() {
                let relative = safe_relative(assets)?;
                verify_subset(live, &relative)?;
                mounts.push(subset_mount(
                    live,
                    &relative,
                    &format!("/srv/preview/{relative}"),
                )?);
            }
            if let Some(main) = parsed["main"].as_str() {
                let relative = safe_relative(main)?;
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

fn tls_port() -> Result<u16, String> {
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
            podman(&["rm", "--force", "tillandsias-router"])?;
        } else {
            running = row["State"]["Status"] == "running";
        }
    }
    if !running {
        podman(&["image", "exists", &router_image]).map_err(
            |_| "router_not_ready: managed router image must be initialized before publication",
        )?;
        let port = http_port
            .map(Ok)
            .unwrap_or_else(|| crate::select_router_host_port(None, debug))?;
        let args = crate::build_router_run_args(&ca, &router_image, port);
        let mut command = vec!["run"];
        command.extend(args.iter().map(String::as_str));
        podman(&command)?;
    }
    Ok(ca)
}

fn strict_reload() -> Result<(), String> {
    podman(&[
        "exec",
        "tillandsias-router",
        "/usr/local/bin/router-reload.sh",
    ])
    .map(|_| ())
    .map_err(|_| "router_not_ready: Caddy rejected or could not reload configuration".into())
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
            if podman(&["logs", "--tail", "20", name])
                .is_ok_and(|s| s.contains("remote_binding_forbidden"))
            {
                return Err(
                    "remote_binding_forbidden: local preview refuses remote bindings".into(),
                );
            }
            return Err("runtime_not_ready: managed runtime exited".into());
        }
        let endpoint = format!("http://{name}:8080/");
        if let Ok(code) = podman(&[
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
        ]) && code
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
    podman(&["image", "exists", profile.image()]).map_err(
        |_| "runtime_unavailable: initialize the managed runtime image before publication",
    )?;
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
    if podman(&command).is_err() {
        let _ = podman(&["rm", "--force", &candidate]);
        return Err("live_worktree_unavailable: cannot launch sibling on live source".into());
    }
    if let Err(e) = ready_backend(&candidate).await {
        let _ = podman(&["rm", "--force", &candidate]);
        return Err(e);
    }
    // Recheck the exact forge launch after candidate startup (PID reuse cannot
    // silently select a different forge). No source copy or commit is involved.
    if inspect(&live.forge_id)?
        .is_none_or(|r| !attributed_forge(&r, &crate::mcp_socket_host_dir(project, Some(instance))))
    {
        let _ = podman(&["rm", "--force", &candidate]);
        return Err("live_worktree_unavailable: source forge exited during startup".into());
    }
    let mut replacement_installed = false;
    let outcome = async {
        if old.is_some() {
            podman(&["rm", "--force", &name])?;
        }
        podman(&["rename", &candidate, &name])?;
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
        let _ = podman(&["rm", "--force", &candidate]);
        if replacement_installed {
            let _ = podman(&["rm", "--force", &name]);
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

pub(crate) async fn publish(
    project: &str,
    instance: &str,
    runtime: &str,
    debug: bool,
) -> Result<Value, String> {
    RPC_DEADLINE
        .scope(
            Instant::now() + Duration::from_secs(90),
            publish_inner(project, instance, runtime, debug),
        )
        .await
}

pub(crate) async fn status(project: &str, instance: &str) -> Result<Value, String> {
    RPC_DEADLINE
        .scope(
            Instant::now() + Duration::from_secs(30),
            status_inner(project, instance),
        )
        .await
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
    RPC_DEADLINE
        .scope(
            Instant::now() + Duration::from_secs(90),
            reload_inner(project, instance, debug),
        )
        .await
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
        Err(_) => {
            return Ok(result(
                "unknown",
                None,
                None,
                false,
                "runtime_unavailable: inspection failed",
            ));
        }
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
        podman(&["rm", "--force", &name])?;
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
        podman(&["rm", "--force", &name])?;
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
            let Ok(text) = podman(&["ps", "--no-trunc", "--format", "{{.ID}}"]) else {
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
                    if podman(&["rm", "--force", &name]).is_err() {
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
            let Ok(volumes) = podman(&["volume", "ls", "--format", "{{.Name}}"]) else {
                continue;
            };
            if !volumes.lines().any(|name| name == volume) {
                break;
            }
            let Ok(text) = podman(&["volume", "inspect", &volume]) else {
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
            if podman(&["volume", "rm", &volume]).is_err() {
                continue;
            }
            break;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

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
            .tmpfs("/home/forge/.ssh:rw,size=1m,mode=0700")
            .tmpfs("/home/forge/.config/gh:rw,size=1m,mode=0700")
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
        assert!(args.contains(&"tillandsias-web-wrangler".into()));
        assert!(joined.contains("dev --local --ip 0.0.0.0 --port 8080"));
        assert!(safe_relative(".").is_err());
        assert!(safe_relative("../other").is_err());
        assert!(safe_relative(".env").is_err());
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

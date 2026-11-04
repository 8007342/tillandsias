//! 1874-zry8: the optional ComfyUI studio, a forge sibling.
//!
//! 1969-cfyt (operator ruling 2026-11-02): the studio is an on-demand
//! appliance. Nothing starts it at forge launch; the forge agent starts it
//! with `studio.start` (or a human with `--studio comfyui`), and it stops with
//! the forge. The old `[imagegen] studio = true` switch is read by nothing. The
//! studio mounts the shared model cache (`cache_root()/models/imagegen`, the
//! same files image.generate fetched through the licence register) read-only,
//! reaches no network beyond the internal enclave (no proxy is configured, so
//! nothing egresses), and is sized to be reclaimed before the forge.
//! @trace order:1874-zry8 (spec: openspec/changes/local-image-generation, not yet archived)

use std::path::{Path, PathBuf};

/// The image name `image_specs` and `runtime_assets` resolve.
pub const STUDIO_IMAGE: &str = "imagegen-studio";
/// ComfyUI's HTTP port inside the container (read by the studio tools,
/// which only host-services builds carry).
#[cfg_attr(not(feature = "host-services"), allow(dead_code))]
pub const STUDIO_PORT: u16 = 8188;

/// What a studio launch needs, resolved only for an opted-in project.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StudioPlan {
    pub image: &'static str,
    /// The shared model cache, mounted read-only at /models.
    pub models_dir: PathBuf,
}

/// The image's `studio` user (images/imagegen-studio/Containerfile useradd).
pub const STUDIO_UID: u32 = 1001;

/// 1921-2krx: the plan for an EXPLICIT `--studio comfyui` launch. Asking for
/// the studio by name is the opt-in, so the project config is not consulted.
pub fn plan_explicit(cache_root: &Path) -> StudioPlan {
    StudioPlan {
        image: STUDIO_IMAGE,
        models_dir: crate::imagegen_models::models_dir_under(cache_root),
    }
}

/// ORDER 1985-stdu: the project's own internal studio network. The studio
/// runs on it alone (never the shared enclave), and only the router and this
/// project's forges are connected to it, so another project's forge cannot
/// reach this studio.
pub fn network_name(project: &str) -> String {
    format!("tillandsias-studio-{project}")
}

/// Run `podman <args>`; Ok(stdout) on success.
fn podman_out(args: &[&str]) -> Result<String, String> {
    let mut cmd = tillandsias_podman::podman_cmd_sync();
    cmd.args(args);
    let o = cmd
        .output_bounded(std::time::Duration::from_secs(30))
        .map_err(|e| format!("podman {}: {e}", args.join(" ")))?;
    if o.status.success() {
        Ok(String::from_utf8_lossy(&o.stdout).trim().to_string())
    } else {
        Err(format!(
            "podman {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&o.stderr).trim()
        ))
    }
}

/// Create the project's studio network when absent (`--internal`: no
/// egress); return its subnet, which the window route admits.
pub fn ensure_network(project: &str) -> Result<String, String> {
    let net = network_name(project);
    if podman_out(&["network", "exists", &net]).is_err() {
        let label = format!("tillandsias.studio.project={project}");
        podman_out(&["network", "create", "--internal", "--label", &label, &net])?;
    }
    let subnet = podman_out(&[
        "network",
        "inspect",
        "--format",
        "{{range .Subnets}}{{.Subnet}} {{end}}",
        &net,
    ])?;
    subnet
        .split_whitespace()
        .find(|s| s.contains('.'))
        .map(str::to_string)
        .ok_or_else(|| format!("{net} has no IPv4 subnet"))
}

/// Connect `container` to the project's studio network; already connected
/// is fine.
#[cfg_attr(not(feature = "host-services"), allow(dead_code))]
pub fn connect(project: &str, container: &str) -> Result<(), String> {
    match podman_out(&["network", "connect", &network_name(project), container]) {
        Ok(_) => Ok(()),
        Err(e) if e.contains("already") => Ok(()),
        Err(e) => Err(e),
    }
}

/// The running containers that are this project's forges (every agent
/// mode and instance is named `tillandsias-<project>-forge…`).
#[cfg_attr(not(feature = "host-services"), allow(dead_code))]
pub fn project_forges(project: &str, running: &[String]) -> Vec<String> {
    let prefix = format!("tillandsias-{project}-forge");
    running
        .iter()
        .filter(|n| n.as_str() == prefix || n.starts_with(&format!("{prefix}-")))
        .cloned()
        .collect()
}

/// 1987-smnt: the studio's model-folder map, from THIS tray (not baked into
/// the image): a changed map needs a tray rebuild and studio.restart, never a
/// studio image rebuild.
pub const MODEL_PATHS_YAML: &str =
    include_str!("../../../images/imagegen-studio/extra_model_paths.yaml");

/// Where ComfyUI reads its folder map (the baked copy it replaces).
pub const MODEL_PATHS_IN_CONTAINER: &str = "/opt/comfyui/extra_model_paths.yaml";

/// The host file the studio mounts: under the model cache's parent, written
/// at every start from [`MODEL_PATHS_YAML`].
pub fn model_paths_file(models_dir: &Path) -> PathBuf {
    models_dir
        .parent()
        .unwrap_or(models_dir)
        .join("imagegen-studio")
        .join("extra_model_paths.yaml")
}

/// Write the folder map the studio will mount (atomic rename).
pub fn write_model_paths(models_dir: &Path) -> Result<PathBuf, String> {
    let path = model_paths_file(models_dir);
    let dir = path.parent().expect("a parent");
    std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let tmp = path.with_extension("yaml.tmp");
    std::fs::write(&tmp, MODEL_PATHS_YAML).map_err(|e| format!("{}: {e}", tmp.display()))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(path)
}

pub fn container_name(project: &str) -> String {
    format!("tillandsias-{project}-studio")
}

/// The podman run argv (without `run` and the image tag). `out_volume` is the
/// lane's per-forge scratch volume; `gpu` adds the CDI device when the host
/// has a container-reachable NVIDIA card.
pub fn run_args(
    plan: &StudioPlan,
    project: &str,
    out_volume: &str,
    gpu: bool,
    budget: &StudioBudget,
) -> Vec<String> {
    let mut args = vec![
        "--detach".to_string(),
        "--rm".to_string(),
        "--replace".to_string(),
        "--name".to_string(),
        container_name(project),
        "--hostname".to_string(),
        "studio".to_string(),
        // 1985-stdu: its own project's network, never the shared enclave.
        // 1986-snpx: `studio` on the project's network, one name per project
        // network, so the forge reaches it by a name no_proxy can list.
        format!("--network={}:alias=studio", network_name(project)),
        "--cap-drop=ALL".to_string(),
        "--security-opt=no-new-privileges".to_string(),
        "--security-opt=label=disable".to_string(),
        // 1969-cfyt: map the host user to the image's studio uid, so files the
        // studio writes are the forge's own and the forge-owned volume root
        // (0755) is writable. Plain keep-id ran studio as an unmapped uid:
        // SaveImage got EACCES creating /out/studio (Kumbia trial).
        format!("--userns=keep-id:uid={STUDIO_UID},gid={STUDIO_UID}"),
        "--oom-score-adj=1000".to_string(),
        "--label".to_string(),
        format!("tillandsias.studio.project={project}"),
        "-v".to_string(),
        format!("{}:/models:ro", plan.models_dir.display()),
        // 1987-smnt: the folder map comes from the tray, read-only.
        "-v".to_string(),
        format!(
            "{}:{MODEL_PATHS_IN_CONTAINER}:ro",
            model_paths_file(&plan.models_dir).display()
        ),
        "-v".to_string(),
        format!("{out_volume}:/out"),
    ];
    args.extend(budget.podman_args());
    if gpu {
        args.extend(["--device".to_string(), "nvidia.com/gpu=all".to_string()]);
    }
    args
}

/// ORDER 1921-q7q3: a studio's memory and CPU budget, computed from this
/// host's RAM at launch. ComfyUI needs far more than a forge sibling's share
/// (1911-3dqo), so the budget comes from what the host has free:
/// `memory.high` about 60% of MemAvailable (throttle and reclaim),
/// `memory.max` about 75% (the OOM backstop, never above 75% of MemTotal),
/// swap equal to `memory.max`, and half the cores. It reserves nothing
/// (`memory.low` 0) and runs at `oom_score_adj` 1000, while the forge keeps
/// its `memory.low`: under pressure the kernel reclaims from and then kills
/// the studio, never the forge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StudioBudget {
    pub memory_high_mib: u64,
    pub memory_max_mib: u64,
    pub swap_max_mib: u64,
    pub cpus: u32,
}

/// Floor so a busy host still gets a studio that can load a small model.
const STUDIO_FLOOR_MIB: u64 = 1024;

impl StudioBudget {
    pub fn for_host(mem_total_mib: u64, mem_available_mib: u64, nproc: u32) -> Self {
        let cap = mem_total_mib.saturating_mul(3) / 4;
        let max = (mem_available_mib.saturating_mul(3) / 4)
            .min(cap)
            .max(STUDIO_FLOOR_MIB);
        let high = (mem_available_mib.saturating_mul(3) / 5)
            .min(max.saturating_sub(1))
            .max(STUDIO_FLOOR_MIB.min(max.saturating_sub(1)));
        StudioBudget {
            memory_high_mib: high,
            memory_max_mib: max,
            swap_max_mib: max,
            cpus: (nproc / 2).max(1),
        }
    }

    /// Read MemTotal and MemAvailable from /proc/meminfo. A host whose
    /// memory cannot be read gets the floor, never a guess upward.
    pub fn for_this_host() -> Self {
        let nproc = std::thread::available_parallelism().map_or(1, |n| n.get() as u32);
        let meminfo = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
        let field = |key: &str| {
            meminfo
                .lines()
                .find(|l| l.starts_with(key))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|v| v.parse::<u64>().ok())
                .map(|kib| kib / 1024)
        };
        let total = field("MemTotal:").unwrap_or(0);
        let available = field("MemAvailable:").unwrap_or(0);
        Self::for_host(total, available, nproc)
    }

    /// Each cgroup file written exactly (see forge_budget on `--memory-swap`).
    pub fn podman_args(&self) -> Vec<String> {
        vec![
            format!("--memory={}m", self.memory_max_mib),
            "--memory-reservation=0".to_string(),
            format!(
                "--cgroup-conf=memory.high={}",
                self.memory_high_mib * 1024 * 1024
            ),
            format!(
                "--cgroup-conf=memory.swap.max={}",
                self.swap_max_mib * 1024 * 1024
            ),
            format!("--cpus={}", self.cpus),
        ]
    }

    pub fn describe(&self) -> String {
        format!(
            "memory.high={} MiB, memory.max={} MiB, swap={} MiB, cpus={}, oom_score_adj=1000",
            self.memory_high_mib, self.memory_max_mib, self.swap_max_mib, self.cpus
        )
    }
}

/// Whether this host's containers can reach an NVIDIA card through CDI.
fn host_has_cdi_gpu() -> bool {
    ["/etc/cdi/nvidia.yaml", "/var/run/cdi/nvidia.yaml"]
        .iter()
        .any(|p| Path::new(p).is_file())
}

#[cfg(feature = "host-services")]
/// Whether the studio container of `project` is running.
pub fn is_running(project: &str) -> bool {
    let mut cmd = tillandsias_podman::podman_cmd_sync();
    cmd.args([
        "inspect",
        "--format",
        "{{.State.Running}}",
        &container_name(project),
    ]);
    cmd.output_bounded(std::time::Duration::from_secs(15))
        .ok()
        .filter(|o| o.status.success())
        .is_some_and(|o| String::from_utf8_lossy(&o.stdout).trim() == "true")
}

/// Forge teardown: the studio goes with the forge (its output volume is the
/// default lane's, which cannot be removed while the studio mounts it).
pub fn stop(project: &str) {
    let _ = podman_out(&["rm", "-f", "--time", "5", &container_name(project)]);
    // 1985-stdu: the window route and the network go with it.
    #[cfg(feature = "host-services")]
    let _ = crate::local_web_preview::remove_dev_route(
        WINDOW_SERVICE,
        project,
        &container_name(project),
        false,
    );
    let net = network_name(project);
    let _ = podman_out(&["network", "disconnect", "-f", &net, "tillandsias-router"]);
    let _ = podman_out(&["network", "rm", "-f", &net]);
}

/// 1985-stdu: a studio already running still connects this project's forges
/// that started after it, and refreshes its window route.
#[cfg(feature = "host-services")]
pub fn reattach(project: &str, debug: bool) -> Result<String, String> {
    let cidr = ensure_network(project)?;
    attach(project, &cidr, debug)
}

/// 1985-stdu: the URL the project's window opens the studio at.
#[cfg(feature = "host-services")]
pub fn window_url(project: &str) -> Option<String> {
    crate::local_web_preview::tls_port().ok().map(|port| {
        format!(
            "https://{WINDOW_SERVICE}.{}.localhost:{port}/",
            crate::local_web_preview::host_label(project)
        )
    })
}

/// 1985-stdu: the studio window's route service (`comfyui.<project>`); the
/// `--studio` lane's OTP route holds `studio.<project>`.
#[cfg_attr(not(feature = "host-services"), allow(dead_code))]
pub const WINDOW_SERVICE: &str = "comfyui";

/// 1985-stdu: after the container is up, put the router and this project's
/// running forges on its network, then route the window (network-limited).
/// Returns the window URL when the router serves it.
#[cfg(feature = "host-services")]
fn attach(project: &str, cidr: &str, debug: bool) -> Result<String, String> {
    connect(project, "tillandsias-router")?;
    let running: Vec<String> = podman_out(&["ps", "--format", "{{.Names}}"])?
        .lines()
        .map(str::to_string)
        .collect();
    for forge in project_forges(project, &running) {
        connect(project, &forge)?;
    }
    crate::local_web_preview::add_network_limited_route(
        WINDOW_SERVICE,
        project,
        &container_name(project),
        STUDIO_PORT,
        cidr,
        debug,
    )
}

#[cfg(feature = "host-services")]
/// `studio.status {}`: what the forge agent needs to use the studio.
pub fn status_json(project: &str, running: bool) -> serde_json::Value {
    serde_json::json!({
        "running": running,
        "container": container_name(project),
        "url": running.then(|| format!("http://studio:{STUDIO_PORT}")),
        // 1985-stdu: the shared window: browser.open {url: window_url, dev: true}.
        "window_url": running.then(|| window_url(project)).flatten(),
        "how": if running {
            "studio.run_workflow queues on it; it stops with the forge."
        } else {
            "Not running. Call studio.start {} (nothing starts it at forge launch)."
        },
    })
}

#[cfg(feature = "host-services")]
/// ORDER 1969-cfyt: `studio.start {}`. Idempotent: a running studio is left as
/// it is; otherwise `launch` runs exactly once. `running` and `launch` are the
/// podman seams (production: [`is_running`] and [`start`]).
pub fn start_on_demand(
    project: &str,
    running: &dyn Fn() -> bool,
    launch: &mut dyn FnMut() -> Result<(), String>,
) -> Result<serde_json::Value, String> {
    let already = running();
    if !already {
        launch().map_err(|e| format!("studio_start_failed: {e}"))?;
    }
    let mut v = status_json(project, already || running());
    v["started"] = serde_json::json!(!already);
    Ok(v)
}

#[cfg(feature = "host-services")]
/// The tool descriptors for `studio.start` and `studio.status`.
pub fn tool_descriptors() -> Vec<serde_json::Value> {
    let empty = serde_json::json!({ "type": "object", "properties": {} });
    vec![
        serde_json::json!({
            "name": "studio.start",
            "description": "Start this project's ComfyUI studio on demand: an appliance on this project's own network (no host port, no egress; another project cannot reach it). Idempotent; builds the image on first use; a call while it runs connects this forge to it. It stops with the forge. The result's window_url opens the SAME studio for the operator and you together: browser.open {url: window_url, dev: true}. studio.run_workflow needs it running.",
            "inputSchema": empty,
        }),
        serde_json::json!({
            "name": "studio.restart",
            "description": "Restart this project's ComfyUI studio: a fresh container that reads the tray's current model-folder map (and any change since start), same network and window route. Use it after a pin or folder-map change; no image rebuild.",
            "inputSchema": empty.clone(),
        }),
        serde_json::json!({
            "name": "studio.status",
            "description": "Whether this project's ComfyUI studio is running, and its enclave URL.",
            "inputSchema": empty,
        }),
    ]
}

/// Build (on first use) and start the studio container for `project_name`.
/// It publishes no host port: the only way in is the router's OTP route.
pub async fn start(
    client: &tillandsias_podman::PodmanClient,
    plan: &StudioPlan,
    project_name: &str,
    version: &str,
    debug: bool,
) -> Result<(), String> {
    std::fs::create_dir_all(&plan.models_dir)
        .map_err(|e| format!("{}: {e}", plan.models_dir.display()))?;
    let root = crate::resolve_runtime_asset_root(version, debug)?;
    let tag = crate::versioned_image_tag(STUDIO_IMAGE, version);
    crate::ensure_image_exists(&root, STUDIO_IMAGE, &tag, debug)?;
    let out_volume = format!("tillandsias-imagegen-{project_name}-default");
    let budget = StudioBudget::for_this_host();
    eprintln!(
        "[tillandsias] studio budget for {project_name} from host RAM: {}",
        budget.describe()
    );
    // 1985-stdu: the project's own network exists before the studio joins it.
    let cidr = ensure_network(project_name)?;
    // 1987-smnt: the tray's folder map, written fresh before every start.
    write_model_paths(&plan.models_dir)?;
    let mut args = run_args(plan, project_name, &out_volume, host_has_cdi_gpu(), &budget);
    // 1913-ebv8: in the forge's slice, ranked before it.
    args.extend(crate::oom_slice_args());
    args.push(tag);
    client
        .run_container_observed(
            "imagegen-studio",
            &container_name(project_name),
            &args,
            debug,
        )
        .await
        .map(|_| ())?;
    #[cfg(feature = "host-services")]
    attach(project_name, &cidr, debug)?;
    let _ = cidr;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 1874-zry8 exit criterion. Pre-fix: FAILS, imagegen-studio is not a
    /// known image and the config has no switch.
    #[test]
    fn the_studio_is_absent_by_default_and_resolves_with_the_shared_cache_when_enabled() {
        let cache =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let p = plan_explicit(cache.path());
        assert_eq!(p.image, "imagegen-studio");
        assert_eq!(p.models_dir, cache.path().join("models").join("imagegen"));
        assert!(
            !crate::imagegen_models::is_volatile(cache.path()),
            "the cache is not tmpfs"
        );

        // The image resolves from the embedded assets, and is never INIT.
        let root = Path::new(&std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"))
            .join("../..");
        let (cf, ctx) = crate::image_specs(&root, STUDIO_IMAGE).expect("imagegen-studio is known");
        assert!(ctx.ends_with("images/imagegen-studio") && cf.is_file());
        assert!(!crate::INIT_IMAGES.contains(&STUDIO_IMAGE));
        let containerfile = std::fs::read_to_string(&cf).unwrap();
        assert!(!containerfile.contains("pip install comfyui-manager"));
        assert!(containerfile.contains("COMFYUI_SHA="));

        // The run argv: shared cache read-only, no egress, below the forge.
        let budget = StudioBudget::for_host(13_811, 9_000, 16);
        let a = run_args(&p, "proj", "tillandsias-imagegen-proj-a", true, &budget);
        let mount = format!("{}:/models:ro", p.models_dir.display());
        assert!(a.contains(&mount), "{a:?}");
        // 1985-stdu: its own project network, never the shared enclave.
        assert!(
            a.contains(&"--network=tillandsias-studio-proj:alias=studio".to_string()),
            "{a:?}"
        );
        assert!(
            !a.iter().any(|x| x.contains("tillandsias-enclave")),
            "{a:?}"
        );
        assert!(
            !a.iter().any(|s| s.to_ascii_lowercase().contains("proxy")),
            "{a:?}"
        );
        assert!(a.contains(&"--oom-score-adj=1000".to_string()));
        assert!(a.contains(&"nvidia.com/gpu=all".to_string()));
        let high: u64 = a
            .iter()
            .find_map(|s| s.strip_prefix("--cgroup-conf=memory.high="))
            .unwrap()
            .parse()
            .unwrap();
        assert_eq!(high, budget.memory_high_mib * 1024 * 1024);
        assert!(
            !run_args(&p, "proj", "v", false, &budget).contains(&"nvidia.com/gpu=all".to_string())
        );
        // 1921-2krx: no host listener. The router's OTP route is the only way
        // in, so the argv publishes nothing, and an explicit launch resolves
        // the same read-only model mount without the config opt-in.
        assert!(
            !a.iter()
                .any(|s| s == "-p" || s.starts_with("--publish") || s.starts_with("-p=")),
            "{a:?}"
        );
    }

    /// ORDER 1987-smnt: the studio reads the tray's folder map through a
    /// read-only mount over the baked copy, written fresh at start. Pre-fix:
    /// FAILS, the map was baked into the image (a change needed a rebuild).
    #[test]
    fn the_studio_mounts_the_trays_folder_map() {
        let cache =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        let p = plan_explicit(cache.path());
        let a = run_args(
            &p,
            "proj",
            "v",
            false,
            &StudioBudget::for_host(13_811, 9_000, 16),
        );
        let host = model_paths_file(&p.models_dir);
        let mount = format!("{}:{MODEL_PATHS_IN_CONTAINER}:ro", host.display());
        assert!(a.contains(&mount), "{a:?}");
        let written = write_model_paths(&p.models_dir).unwrap();
        assert_eq!(written, host);
        assert_eq!(std::fs::read_to_string(&host).unwrap(), MODEL_PATHS_YAML);
        assert!(
            host.starts_with(cache.path()),
            "under the cache, never the image"
        );
    }

    /// ORDER 1985-stdu: only THIS project's forges join its studio network;
    /// a project whose name extends this one's is not matched.
    #[test]
    fn only_this_projects_forges_join_its_studio_network() {
        let running: Vec<String> = [
            "tillandsias-kumbia-forge",
            "tillandsias-kumbia-forge-claude-2",
            "tillandsias-kumbia-kombat-forge",
            "tillandsias-other-forge",
            "tillandsias-kumbia-studio",
            "tillandsias-router",
        ]
        .iter()
        .map(|s| s.to_string())
        .collect();
        assert_eq!(
            project_forges("kumbia", &running),
            vec![
                "tillandsias-kumbia-forge",
                "tillandsias-kumbia-forge-claude-2"
            ]
        );
        assert_eq!(
            project_forges("kumbia-kombat", &running),
            vec!["tillandsias-kumbia-kombat-forge"]
        );
        assert_eq!(
            network_name("kumbia-kombat"),
            "tillandsias-studio-kumbia-kombat"
        );
    }

    /// ORDER 1969-cfyt: nothing at forge launch starts a studio. Pre-fix:
    /// FAILS, the forge launch path called ensure_if_enabled, which started
    /// one for `[imagegen] studio = true`.
    #[test]
    fn a_forge_launch_starts_no_studio() {
        let main = include_str!("main.rs");
        let call = ["ensure_if_", "enabled("].concat();
        assert!(
            !main.contains(&call),
            "the forge launch still starts a studio"
        );
        assert!(!include_str!("imagegen_studio.rs").contains(&["fn ", &call].concat()));
    }

    /// ORDER 1969-cfyt: studio.start starts exactly one studio, and a second
    /// call while it runs starts none. Pre-fix: FAILS, there is no studio.start.
    #[test]
    #[cfg(feature = "host-services")]
    fn studio_start_launches_exactly_once_and_is_idempotent() {
        let up = std::cell::Cell::new(false);
        let launches = std::cell::Cell::new(0);
        let mut launch = || {
            launches.set(launches.get() + 1);
            up.set(true);
            Ok(())
        };
        let r = start_on_demand("p", &|| up.get(), &mut launch).unwrap();
        assert_eq!(
            (r["started"].as_bool(), r["running"].as_bool()),
            (Some(true), Some(true))
        );
        let r = start_on_demand("p", &|| up.get(), &mut launch).unwrap();
        assert_eq!(r["started"], false);
        assert_eq!(launches.get(), 1, "exactly one studio");
        assert_eq!(r["url"], "http://studio:8188");
        let mut fails = || Err("no image".to_string());
        let e = start_on_demand("q", &|| false, &mut fails).unwrap_err();
        assert!(e.starts_with("studio_start_failed:"), "{e}");
    }

    /// ORDER 1981-kidm: the REAL studio launch argv (run_args + the OOM
    /// slice + the image, exactly what `start` hands run_container_observed)
    /// passes the podman launch policy. Pre-fix: FAILS, the policy matched
    /// only the bare `--userns=keep-id` and refused studio.start on the live
    /// tray; nothing put this argv through the policy before.
    #[test]
    fn the_real_studio_launch_argv_passes_the_launch_policy() {
        let p = plan_explicit(Path::new("/c"));
        for gpu in [false, true] {
            let mut argv = vec!["run".to_string()];
            argv.extend(run_args(
                &p,
                "proj",
                "tillandsias-imagegen-proj-default",
                gpu,
                &StudioBudget::for_host(13_811, 9_000, 16),
            ));
            argv.extend(crate::oom_slice_args());
            argv.push(crate::versioned_image_tag(STUDIO_IMAGE, "1.2.3"));
            assert_eq!(
                tillandsias_podman::policy::validate_launch_argv(&argv),
                Ok(()),
                "{argv:?}"
            );
        }
    }

    /// ORDER 1969-cfyt: the studio runs as the forge's own user, so SaveImage
    /// can create /out/studio in the forge-owned volume. Pre-fix: FAILS, plain
    /// keep-id (the trial's EACCES; reproduced live on lenovinha with the
    /// production flags: keep-id -> Permission denied, keep-id:uid=1001 -> ok).
    #[test]
    fn the_studio_maps_the_host_user_to_its_own_uid() {
        let p = plan_explicit(Path::new("/c"));
        let a = run_args(
            &p,
            "proj",
            "v",
            false,
            &StudioBudget::for_host(13_811, 9_000, 16),
        );
        assert!(
            a.contains(&"--userns=keep-id:uid=1001,gid=1001".to_string()),
            "{a:?}"
        );
        assert!(!a.contains(&"--userns=keep-id".to_string()), "{a:?}");
    }

    /// 1921-q7q3: the studio budget is computed from host RAM: high about
    /// 60% and max about 75% of MemAvailable, max never above 75% of
    /// MemTotal, swap equal to max, half the cores, and a floor on a busy
    /// host. Pre-fix the studio got three quarters of the forge's high and
    /// no max, swap or CPU limit at all.
    #[test]
    fn the_studio_budget_derives_from_host_ram() {
        // lenovinha-like: 13.5 GiB total, 9 GiB available, 16 threads.
        let b = StudioBudget::for_host(13_811, 9_000, 16);
        assert_eq!(b.memory_max_mib, 6_750);
        assert_eq!(b.memory_high_mib, 5_400);
        assert_eq!(b.swap_max_mib, b.memory_max_mib);
        assert_eq!(b.cpus, 8);
        // Never above 75% of total, even when "available" reads high.
        let b = StudioBudget::for_host(8_000, 8_000, 4);
        assert_eq!(b.memory_max_mib, 6_000);
        assert!(b.memory_high_mib < b.memory_max_mib);
        // A busy host gets the floor, and high stays below max.
        let b = StudioBudget::for_host(16_000, 200, 1);
        assert_eq!(b.memory_max_mib, STUDIO_FLOOR_MIB);
        assert!(b.memory_high_mib < b.memory_max_mib);
        assert_eq!(b.cpus, 1);
        // Unreadable meminfo: the floor, never a guess upward.
        assert_eq!(
            StudioBudget::for_host(0, 0, 8).memory_max_mib,
            STUDIO_FLOOR_MIB
        );
    }

    /// Under pressure the studio is reclaimed from and killed first: it
    /// reserves nothing and its OOM score is the maximum, while the forge
    /// keeps its memory.low and default score. Each limit is written exactly.
    #[test]
    fn the_studio_ranks_below_the_forge_under_pressure() {
        let forge = tillandsias_core::forge_budget::ForgeBudget::for_host(16, 13_811);
        assert!(
            forge.memory_low_mib > 0,
            "the forge protects its working set"
        );
        let budget = StudioBudget::for_host(13_811, 9_000, 16);
        let p = plan_explicit(std::path::Path::new("/nonexistent-cache"));
        let a = run_args(&p, "proj", "v", false, &budget);
        for flag in [
            "--oom-score-adj=1000".to_string(),
            "--memory-reservation=0".to_string(),
            "--memory=6750m".to_string(),
            format!("--cgroup-conf=memory.high={}", 5_400u64 * 1024 * 1024),
            format!("--cgroup-conf=memory.swap.max={}", 6_750u64 * 1024 * 1024),
            "--cpus=8".to_string(),
        ] {
            assert!(a.contains(&flag), "missing {flag}: {a:?}");
        }
        assert!(!a.iter().any(|s| s.starts_with("--memory-swap")), "{a:?}");
        assert!(budget.describe().contains("memory.max=6750 MiB"));
    }
}

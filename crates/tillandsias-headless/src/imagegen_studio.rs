//! 1874-zry8: the optional ComfyUI studio, a forge sibling.
//!
//! A project opts in with `[imagegen] studio = true`. Without it nothing here
//! resolves, so no studio image is built and no container runs. With it, the
//! studio mounts the shared model cache (`cache_root()/models/imagegen`, the
//! same files image.generate fetched through the licence register) read-only,
//! reaches no network beyond the internal enclave (no proxy is configured, so
//! nothing egresses), and is sized to be reclaimed before the forge.
//! @trace order:1874-zry8 (spec: openspec/changes/local-image-generation, not yet archived)

use std::path::{Path, PathBuf};

use tillandsias_core::config::ProjectConfig;

/// The image name `image_specs` and `runtime_assets` resolve.
pub const STUDIO_IMAGE: &str = "imagegen-studio";
/// ComfyUI's HTTP port inside the container.
pub const STUDIO_PORT: u16 = 8188;

/// What a studio launch needs, resolved only for an opted-in project.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StudioPlan {
    pub image: &'static str,
    /// The shared model cache, mounted read-only at /models.
    pub models_dir: PathBuf,
}

/// `Some` only when the project enabled the studio.
pub fn plan(config: &ProjectConfig, cache_root: &Path) -> Option<StudioPlan> {
    config
        .imagegen
        .as_ref()
        .filter(|c| c.studio)
        .map(|_| StudioPlan {
            image: STUDIO_IMAGE,
            models_dir: crate::imagegen_models::models_dir_under(cache_root),
        })
}

/// 1921-2krx: the plan for an EXPLICIT `--studio comfyui` launch. Asking for
/// the studio by name is the opt-in, so the project config is not consulted.
pub fn plan_explicit(cache_root: &Path) -> StudioPlan {
    StudioPlan {
        image: STUDIO_IMAGE,
        models_dir: crate::imagegen_models::models_dir_under(cache_root),
    }
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
        format!("--network={}", crate::ENCLAVE_NET),
        "--cap-drop=ALL".to_string(),
        "--security-opt=no-new-privileges".to_string(),
        "--security-opt=label=disable".to_string(),
        "--userns=keep-id".to_string(),
        "--oom-score-adj=1000".to_string(),
        "--label".to_string(),
        format!("tillandsias.studio.project={project}"),
        "-v".to_string(),
        format!("{}:/models:ro", plan.models_dir.display()),
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

/// Start the studio beside the forge when, and only when, the project enabled
/// it. Best effort: a studio that cannot start is reported and the forge
/// launches anyway.
pub async fn ensure_if_enabled(
    client: &tillandsias_podman::PodmanClient,
    project_name: &str,
    project_path: Option<&Path>,
    version: &str,
    debug: bool,
) {
    let Some(path) = project_path else { return };
    let config = tillandsias_core::config::load_project_config(path);
    let Some(plan) = plan(&config, &tillandsias_core::cache_root::cache_root()) else {
        return;
    };
    match start(client, &plan, project_name, version, debug).await {
        Ok(()) => eprintln!(
            "[tillandsias] imagegen studio up for {project_name} (http://studio:{STUDIO_PORT} inside the enclave)"
        ),
        Err(e) => eprintln!("[tillandsias] imagegen studio NOT started for {project_name}: {e}"),
    }
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
        .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tillandsias_core::config::ImagegenConfig;

    /// 1874-zry8 exit criterion. Pre-fix: FAILS, imagegen-studio is not a
    /// known image and the config has no switch.
    #[test]
    fn the_studio_is_absent_by_default_and_resolves_with_the_shared_cache_when_enabled() {
        let cache =
            tempfile::tempdir_in(std::env::current_exe().unwrap().parent().unwrap()).unwrap();
        // Default: no plan, so no build and no container.
        assert_eq!(plan(&ProjectConfig::default(), cache.path()), None);
        let off = ProjectConfig {
            imagegen: Some(ImagegenConfig { studio: false }),
            ..Default::default()
        };
        assert_eq!(plan(&off, cache.path()), None);
        let parsed: ProjectConfig = toml::from_str("[imagegen]\nstudio = true\n").unwrap();
        let p = plan(&parsed, cache.path()).expect("enabled");
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
        assert!(a.contains(&"--network=tillandsias-enclave".to_string()));
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
        assert_eq!(plan_explicit(cache.path()), p);
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

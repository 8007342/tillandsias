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
use tillandsias_core::forge_budget::ForgeBudget;

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
    forge: &ForgeBudget,
) -> Vec<String> {
    // Below the forge: under pressure the studio is throttled and killed first.
    let high_mib = forge.memory_high_mib.saturating_mul(3) / 4;
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
        format!("--cgroup-conf=memory.high={}", high_mib * 1024 * 1024),
        "--oom-score-adj=1000".to_string(),
        "--label".to_string(),
        format!("tillandsias.studio.project={project}"),
        "-v".to_string(),
        format!("{}:/models:ro", plan.models_dir.display()),
        "-v".to_string(),
        format!("{out_volume}:/out"),
    ];
    if gpu {
        args.extend(["--device".to_string(), "nvidia.com/gpu=all".to_string()]);
    }
    args
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
    let started = async {
        std::fs::create_dir_all(&plan.models_dir)
            .map_err(|e| format!("{}: {e}", plan.models_dir.display()))?;
        let root = crate::resolve_runtime_asset_root(version, debug)?;
        let tag = crate::versioned_image_tag(STUDIO_IMAGE, version);
        crate::ensure_image_exists(&root, STUDIO_IMAGE, &tag, debug)?;
        let out_volume = format!("tillandsias-imagegen-{project_name}-default");
        let mut args = run_args(
            &plan,
            project_name,
            &out_volume,
            host_has_cdi_gpu(),
            &ForgeBudget::for_this_host(),
        );
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
    };
    match started.await {
        Ok(()) => eprintln!(
            "[tillandsias] imagegen studio up for {project_name} (http://studio:{STUDIO_PORT} inside the enclave)"
        ),
        Err(e) => eprintln!("[tillandsias] imagegen studio NOT started for {project_name}: {e}"),
    }
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
        let forge = ForgeBudget::for_host(16, 13_811);
        let a = run_args(&p, "proj", "tillandsias-imagegen-proj-a", true, &forge);
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
        assert!(high < forge.memory_high_mib * 1024 * 1024);
        assert!(
            !run_args(&p, "proj", "v", false, &forge).contains(&"nvidia.com/gpu=all".to_string())
        );
    }
}

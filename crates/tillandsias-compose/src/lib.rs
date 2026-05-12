//! Podman Compose orchestration for the Tillandsias enclave.
//!
//! Drives a declarative four-service enclave (forge, proxy, git, inference)
//! by shelling out to `podman-compose`. Compose YAML and per-service support
//! files are embedded via [`rust_embed`] and materialized to
//! `$XDG_RUNTIME_DIR/tillandsias/compose/<project>/` at
//! [`Compose::materialize`] time.
//!
//! See `src-tauri/assets/compose/README.md` for the multi-environment contract
//! and `openspec/changes/migrate-enclave-orchestration-to-compose/` for the
//! full spec.
//!
//! @trace spec:enclave-compose-migration

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;

use rust_embed::RustEmbed;
use thiserror::Error;
use tokio::process::{Child, Command};

#[derive(RustEmbed)]
#[folder = "../../src-tauri/assets/compose/"]
#[include = "*.yaml"]
#[include = "*.yml"]
#[include = "services/*/Containerfile"]
#[include = "services/*/*.sh"]
#[include = "services/*/*.conf"]
#[include = "services/*/*.template"]
#[include = "services/*/*.txt"]
#[include = "services/*/*.json"]
struct ComposeAssets;

/// Selected orchestration environment.
///
/// Maps to the overlay files under `src-tauri/assets/compose/` and to the
/// suffix appended to the Compose project name for namespace isolation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ComposeProfile {
    /// Default tray operation. Forge offline, secrets external.
    Prod,
    /// Live source bind-mounts on top of [`ComposeProfile::Prod`].
    Dev,
    /// Single-forge scratchpad: only `forge` starts, default rootless network,
    /// host source bind-mounted, no secrets. Mirrors `run-forge-standalone.sh`.
    Local,
}

impl ComposeProfile {
    pub fn overlay_filename(self) -> Option<&'static str> {
        match self {
            ComposeProfile::Prod => None,
            ComposeProfile::Dev => Some("compose.dev.yaml"),
            ComposeProfile::Local => Some("compose.local.yaml"),
        }
    }

    pub fn project_suffix(self) -> &'static str {
        match self {
            ComposeProfile::Prod => "",
            ComposeProfile::Dev => "-dev",
            ComposeProfile::Local => "-local",
        }
    }
}

#[derive(Debug, Error)]
pub enum ComposeError {
    #[error("XDG_RUNTIME_DIR not set and dirs::runtime_dir() returned None")]
    NoRuntimeDir,
    #[error("embedded asset not found: {0}")]
    MissingAsset(String),
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("podman-compose exited {code}: {stderr}")]
    ComposeFailed { code: i32, stderr: String },
    #[error("podman-compose not installed or not on PATH")]
    ComposeNotFound,
    #[error("json: {0}")]
    Json(#[from] serde_json::Error),
}

/// One row of `podman-compose ps --format json` output.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct ServiceState {
    #[serde(alias = "Service", alias = "service")]
    pub service: String,
    #[serde(alias = "State", alias = "state")]
    pub state: String,
    #[serde(alias = "Health", alias = "health", default)]
    pub health: Option<String>,
}

/// Materialized compose project ready to drive lifecycle.
pub struct Compose {
    project: String,
    profile: ComposeProfile,
    workdir: PathBuf,
}

impl Compose {
    /// Extract embedded assets to `$XDG_RUNTIME_DIR/tillandsias/compose/<project>/`
    /// and return a handle. Safe to call repeatedly; existing files are
    /// overwritten.
    pub fn materialize(
        project_slug: &str,
        profile: ComposeProfile,
    ) -> Result<Self, ComposeError> {
        let project = format!("tillandsias-{}{}", project_slug, profile.project_suffix());
        let workdir = runtime_workdir(&project)?;
        std::fs::create_dir_all(&workdir)?;
        extract_assets(&workdir)?;
        tracing::debug!(
            project = %project,
            workdir = %workdir.display(),
            "compose: materialized"
        );
        Ok(Self { project, profile, workdir })
    }

    pub fn project(&self) -> &str {
        &self.project
    }

    pub fn profile(&self) -> ComposeProfile {
        self.profile
    }

    pub fn workdir(&self) -> &Path {
        &self.workdir
    }

    fn base_argv(&self) -> Vec<String> {
        let mut argv = vec![
            "-f".into(),
            self.workdir.join("compose.yaml").to_string_lossy().into_owned(),
        ];
        if let Some(overlay) = self.profile.overlay_filename() {
            argv.push("-f".into());
            argv.push(self.workdir.join(overlay).to_string_lossy().into_owned());
        }
        argv.push("-p".into());
        argv.push(self.project.clone());
        argv
    }

    /// `podman-compose -f ... -p <project> up -d [services...]`
    pub async fn up(&self, services: &[&str]) -> Result<(), ComposeError> {
        let mut argv = self.base_argv();
        argv.push("up".into());
        argv.push("-d".into());
        for s in services {
            argv.push((*s).into());
        }
        run_compose(&argv).await
    }

    /// `podman-compose -f ... -p <project> down [-v]`
    pub async fn down(&self, volumes: bool) -> Result<(), ComposeError> {
        let mut argv = self.base_argv();
        argv.push("down".into());
        if volumes {
            argv.push("-v".into());
        }
        run_compose(&argv).await
    }

    pub async fn restart(&self, service: &str) -> Result<(), ComposeError> {
        let mut argv = self.base_argv();
        argv.push("restart".into());
        argv.push(service.into());
        run_compose(&argv).await
    }

    /// Spawn `podman-compose logs -f <service>` and return the child for
    /// streaming. Caller owns the stdout pipe.
    pub fn logs(&self, service: &str) -> Result<Child, ComposeError> {
        let mut argv = self.base_argv();
        argv.push("logs".into());
        argv.push("-f".into());
        argv.push(service.into());
        spawn_compose(&argv)
    }

    /// Parse `podman-compose ps --format json` output. podman-compose emits
    /// one JSON object per line; tolerant of either layout.
    pub async fn ps(&self) -> Result<Vec<ServiceState>, ComposeError> {
        let mut argv = self.base_argv();
        argv.push("ps".into());
        argv.push("--format".into());
        argv.push("json".into());
        let out = capture_compose(&argv).await?;
        let trimmed = out.trim();
        if trimmed.is_empty() {
            return Ok(Vec::new());
        }
        if trimmed.starts_with('[') {
            return Ok(serde_json::from_str(trimmed)?);
        }
        let mut services = Vec::new();
        for line in trimmed.lines() {
            let line = line.trim();
            if line.is_empty() {
                continue;
            }
            services.push(serde_json::from_str(line)?);
        }
        Ok(services)
    }

    pub async fn exec(
        &self,
        service: &str,
        cmd: &[&str],
    ) -> Result<std::process::ExitStatus, ComposeError> {
        let mut argv = self.base_argv();
        argv.push("exec".into());
        argv.push(service.into());
        for c in cmd {
            argv.push((*c).into());
        }
        let status = Command::new("podman-compose")
            .args(&argv)
            .status()
            .await
            .map_err(map_spawn_err)?;
        Ok(status)
    }
}

fn runtime_workdir(project: &str) -> Result<PathBuf, ComposeError> {
    let base = std::env::var_os("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .or_else(dirs::runtime_dir)
        .ok_or(ComposeError::NoRuntimeDir)?;
    Ok(base.join("tillandsias").join("compose").join(project))
}

fn extract_assets(target: &Path) -> Result<(), ComposeError> {
    for path in ComposeAssets::iter() {
        let file = ComposeAssets::get(&path)
            .ok_or_else(|| ComposeError::MissingAsset(path.to_string()))?;
        let dest = target.join(path.as_ref());
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let mut f = std::fs::File::create(&dest)?;
        f.write_all(&file.data)?;
    }
    Ok(())
}

async fn run_compose(argv: &[String]) -> Result<(), ComposeError> {
    tracing::debug!(argv = ?argv, "compose: invoking podman-compose");
    let output = Command::new("podman-compose")
        .args(argv)
        .stdout(Stdio::inherit())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(map_spawn_err)?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        let code = output.status.code().unwrap_or(-1);
        return Err(ComposeError::ComposeFailed { code, stderr });
    }
    Ok(())
}

async fn capture_compose(argv: &[String]) -> Result<String, ComposeError> {
    let output = Command::new("podman-compose")
        .args(argv)
        .output()
        .await
        .map_err(map_spawn_err)?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        let code = output.status.code().unwrap_or(-1);
        return Err(ComposeError::ComposeFailed { code, stderr });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn spawn_compose(argv: &[String]) -> Result<Child, ComposeError> {
    Command::new("podman-compose")
        .args(argv)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(map_spawn_err)
}

fn map_spawn_err(e: std::io::Error) -> ComposeError {
    if e.kind() == std::io::ErrorKind::NotFound {
        ComposeError::ComposeNotFound
    } else {
        ComposeError::Io(e)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_overlay_paths() {
        assert_eq!(ComposeProfile::Prod.overlay_filename(), None);
        assert_eq!(
            ComposeProfile::Dev.overlay_filename(),
            Some("compose.dev.yaml")
        );
        assert_eq!(
            ComposeProfile::Local.overlay_filename(),
            Some("compose.local.yaml")
        );
    }

    #[test]
    fn profile_project_suffixes() {
        assert_eq!(ComposeProfile::Prod.project_suffix(), "");
        assert_eq!(ComposeProfile::Dev.project_suffix(), "-dev");
        assert_eq!(ComposeProfile::Local.project_suffix(), "-local");
    }

    #[test]
    fn assets_include_compose_yaml() {
        let paths: Vec<String> = ComposeAssets::iter().map(|p| p.into_owned()).collect();
        assert!(
            paths.iter().any(|p| p == "compose.yaml"),
            "compose.yaml not embedded; got: {paths:?}"
        );
        assert!(
            paths.iter().any(|p| p == "compose.dev.yaml"),
            "compose.dev.yaml not embedded; got: {paths:?}"
        );
        assert!(
            paths.iter().any(|p| p == "compose.local.yaml"),
            "compose.local.yaml not embedded; got: {paths:?}"
        );
    }

    #[test]
    fn assets_exclude_readme() {
        let paths: Vec<String> = ComposeAssets::iter().map(|p| p.into_owned()).collect();
        assert!(
            !paths.iter().any(|p| p.ends_with("README.md")),
            "README.md files must not be embedded; got: {paths:?}"
        );
    }
}

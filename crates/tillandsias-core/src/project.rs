use std::path::PathBuf;

use crate::genus::TillandsiaGenus;

/// Detected project type based on standard file markers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum ProjectType {
    Node,
    Rust,
    Python,
    Go,
    Nix,
    Unknown,
}

/// What artifacts are present in the project directory.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct ArtifactStatus {
    pub has_containerfile: bool,
    pub has_dockerfile: bool,
    pub has_flake_nix: bool,
    pub has_runtime_config: bool,
}

impl ArtifactStatus {
    pub fn is_buildable(&self) -> bool {
        self.has_containerfile || self.has_dockerfile || self.has_flake_nix
    }

    pub fn has_any_artifact(&self) -> bool {
        self.is_buildable() || self.has_runtime_config
    }
}

/// A discovered project in the watch directory.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct Project {
    pub name: String,
    pub path: PathBuf,
    pub project_type: ProjectType,
    pub artifacts: ArtifactStatus,
    /// Genus assigned when environment is attached (None if not running).
    pub assigned_genus: Option<TillandsiaGenus>,
}

/// Filesystem scanner emits these when projects change.
#[derive(Debug, Clone)]
pub enum ProjectChange {
    Discovered(Project),
    Updated(Project),
    Removed { path: PathBuf },
}

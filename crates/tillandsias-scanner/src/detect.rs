use std::path::Path;

use tracing::debug;

use tillandsias_core::project::{ArtifactStatus, Project, ProjectType};

/// Detect project type from standard file markers (priority order).
pub fn detect_project_type(project_path: &Path) -> ProjectType {
    if project_path.join(".tillandsias").join("config.toml").exists() {
        // Explicit config — still try to detect type from project files
        return detect_from_project_files(project_path);
    }
    detect_from_project_files(project_path)
}

fn detect_from_project_files(project_path: &Path) -> ProjectType {
    // Check in priority order
    if project_path.join("Cargo.toml").exists() {
        ProjectType::Rust
    } else if project_path.join("package.json").exists() {
        ProjectType::Node
    } else if project_path.join("pyproject.toml").exists()
        || project_path.join("requirements.txt").exists()
    {
        ProjectType::Python
    } else if project_path.join("go.mod").exists() {
        ProjectType::Go
    } else if project_path.join("flake.nix").exists() {
        ProjectType::Nix
    } else {
        ProjectType::Unknown
    }
}

/// Detect which artifacts are present in a project directory.
pub fn detect_artifacts(project_path: &Path) -> ArtifactStatus {
    let has_runtime_config = project_path
        .join(".tillandsias")
        .join("config.toml")
        .exists()
        && has_runtime_section(project_path);

    ArtifactStatus {
        has_containerfile: project_path.join("Containerfile").exists(),
        has_dockerfile: project_path.join("Dockerfile").exists(),
        has_flake_nix: project_path.join("flake.nix").exists(),
        has_runtime_config,
    }
}

/// Check if the project's .tillandsias/config.toml has a [runtime] section.
fn has_runtime_section(project_path: &Path) -> bool {
    let config_path = project_path.join(".tillandsias").join("config.toml");
    match std::fs::read_to_string(config_path) {
        Ok(contents) => contents.contains("[runtime]"),
        Err(_) => false,
    }
}

/// Full project scan: detect type and artifacts.
pub fn scan_project(project_path: &Path) -> Option<Project> {
    let name = project_path.file_name()?.to_string_lossy().to_string();

    // Skip hidden directories
    if name.starts_with('.') {
        return None;
    }

    // Must be a directory
    if !project_path.is_dir() {
        return None;
    }

    let project_type = detect_project_type(project_path);
    let artifacts = detect_artifacts(project_path);

    debug!(
        name = %name,
        project_type = ?project_type,
        has_containerfile = artifacts.has_containerfile,
        "Scanned project"
    );

    Some(Project {
        name,
        path: project_path.to_path_buf(),
        project_type,
        artifacts,
        assigned_genus: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn setup_dir() -> TempDir {
        tempfile::tempdir().unwrap()
    }

    #[test]
    fn detect_rust_project() {
        let dir = setup_dir();
        fs::write(dir.path().join("Cargo.toml"), "[package]").unwrap();
        assert_eq!(detect_project_type(dir.path()), ProjectType::Rust);
    }

    #[test]
    fn detect_node_project() {
        let dir = setup_dir();
        fs::write(dir.path().join("package.json"), "{}").unwrap();
        assert_eq!(detect_project_type(dir.path()), ProjectType::Node);
    }

    #[test]
    fn detect_python_project() {
        let dir = setup_dir();
        fs::write(dir.path().join("pyproject.toml"), "").unwrap();
        assert_eq!(detect_project_type(dir.path()), ProjectType::Python);
    }

    #[test]
    fn detect_python_requirements_txt() {
        let dir = setup_dir();
        fs::write(dir.path().join("requirements.txt"), "flask").unwrap();
        assert_eq!(detect_project_type(dir.path()), ProjectType::Python);
    }

    #[test]
    fn detect_go_project() {
        let dir = setup_dir();
        fs::write(dir.path().join("go.mod"), "module example").unwrap();
        assert_eq!(detect_project_type(dir.path()), ProjectType::Go);
    }

    #[test]
    fn detect_nix_project() {
        let dir = setup_dir();
        fs::write(dir.path().join("flake.nix"), "{}").unwrap();
        assert_eq!(detect_project_type(dir.path()), ProjectType::Nix);
    }

    #[test]
    fn detect_unknown_project() {
        let dir = setup_dir();
        fs::write(dir.path().join("readme.md"), "hello").unwrap();
        assert_eq!(detect_project_type(dir.path()), ProjectType::Unknown);
    }

    #[test]
    fn rust_takes_priority_over_node() {
        let dir = setup_dir();
        fs::write(dir.path().join("Cargo.toml"), "[package]").unwrap();
        fs::write(dir.path().join("package.json"), "{}").unwrap();
        assert_eq!(detect_project_type(dir.path()), ProjectType::Rust);
    }

    #[test]
    fn detect_containerfile_artifact() {
        let dir = setup_dir();
        fs::write(dir.path().join("Containerfile"), "FROM alpine").unwrap();
        let artifacts = detect_artifacts(dir.path());
        assert!(artifacts.has_containerfile);
        assert!(artifacts.is_buildable());
    }

    #[test]
    fn detect_dockerfile_artifact() {
        let dir = setup_dir();
        fs::write(dir.path().join("Dockerfile"), "FROM alpine").unwrap();
        let artifacts = detect_artifacts(dir.path());
        assert!(artifacts.has_dockerfile);
        assert!(artifacts.is_buildable());
    }

    #[test]
    fn detect_runtime_config() {
        let dir = setup_dir();
        let config_dir = dir.path().join(".tillandsias");
        fs::create_dir_all(&config_dir).unwrap();
        fs::write(
            config_dir.join("config.toml"),
            "[runtime]\ncommand = \"npm start\"\n",
        )
        .unwrap();
        let artifacts = detect_artifacts(dir.path());
        assert!(artifacts.has_runtime_config);
    }

    #[test]
    fn scan_project_skips_hidden() {
        let dir = setup_dir();
        let hidden = dir.path().join(".hidden");
        fs::create_dir_all(&hidden).unwrap();
        assert!(scan_project(&hidden).is_none());
    }

    #[test]
    fn scan_project_full() {
        let dir = setup_dir();
        let project = dir.path().join("my-app");
        fs::create_dir_all(&project).unwrap();
        fs::write(project.join("package.json"), "{}").unwrap();
        fs::write(project.join("Containerfile"), "FROM node").unwrap();

        let p = scan_project(&project).unwrap();
        assert_eq!(p.name, "my-app");
        assert_eq!(p.project_type, ProjectType::Node);
        assert!(p.artifacts.has_containerfile);
        assert!(p.assigned_genus.is_none());
    }
}

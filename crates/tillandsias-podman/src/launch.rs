use tracing::{debug, info};

use tillandsias_core::config::ResolvedConfig;
#[cfg(test)]
use tillandsias_core::config::SecurityConfig;
use tillandsias_core::genus::TillandsiaGenus;
use tillandsias_core::state::ContainerInfo;

use crate::client::{PodmanClient, PodmanError};
use crate::gpu::detect_gpu_devices;

/// Builds and executes container launch commands with security hardening.
pub struct ContainerLauncher {
    client: PodmanClient,
}

impl ContainerLauncher {
    pub fn new(client: PodmanClient) -> Self {
        Self { client }
    }

    /// Build the full argument list for `podman run`.
    pub fn build_run_args(
        &self,
        container_name: &str,
        config: &ResolvedConfig,
        project_path: &std::path::Path,
        cache_dir: &std::path::Path,
        port_range: (u16, u16),
    ) -> Vec<String> {
        let mut args = vec![
            "-d".to_string(),
            "--rm".to_string(),
            "--name".to_string(),
            container_name.to_string(),
            "--userns=keep-id".to_string(),
            "--cap-drop=ALL".to_string(),
            "--security-opt=no-new-privileges".to_string(),
            "--security-opt=label=disable".to_string(),
        ];

        // GPU passthrough (Linux only, silent when absent)
        if cfg!(target_os = "linux") {
            for device_flag in detect_gpu_devices() {
                args.push(device_flag);
            }
        }

        // Port range mapping
        let port_mapping = format!(
            "{}-{}:{}-{}",
            port_range.0, port_range.1, port_range.0, port_range.1
        );
        args.push("-p".to_string());
        args.push(port_mapping);

        // Volume mounts
        // Project directory → container workspace (rw)
        let project_mount = format!("{}:/var/home/forge/src", project_path.display());
        args.push("-v".to_string());
        args.push(project_mount);

        // Cache directory → container cache
        let cache_mount = format!("{}:/var/home/forge/.cache/tillandsias", cache_dir.display());
        args.push("-v".to_string());
        args.push(cache_mount);

        // Shared Nix cache
        let nix_cache = cache_dir.join("nix");
        if nix_cache.exists() || cfg!(target_os = "linux") {
            let nix_mount = format!(
                "{}:/var/home/forge/.cache/tillandsias/nix",
                nix_cache.display()
            );
            args.push("-v".to_string());
            args.push(nix_mount);
        }

        // Custom mounts from project config
        for mount in &config.mounts {
            let mount_str = format!("{}:{}:{}", mount.host, mount.container, mount.mode);
            args.push("-v".to_string());
            args.push(mount_str);
        }

        // Container image (always last)
        args.push(config.image.clone());

        args
    }

    /// Launch a container environment for a project.
    pub async fn launch(
        &self,
        project_name: &str,
        genus: TillandsiaGenus,
        config: &ResolvedConfig,
        project_path: &std::path::Path,
        cache_dir: &std::path::Path,
        port_range: (u16, u16),
    ) -> Result<ContainerInfo, PodmanError> {
        let container_name = ContainerInfo::container_name(project_name, genus);

        info!(
            container = %container_name,
            image = %config.image,
            port_range = ?port_range,
            "Launching container"
        );

        // Ensure image exists, pull if needed
        if !self.client.image_exists(&config.image).await {
            debug!(image = %config.image, "Image not found locally, pulling...");
            self.client.pull_image(&config.image).await?;
        }

        // Ensure cache directories exist
        std::fs::create_dir_all(cache_dir).ok();
        std::fs::create_dir_all(cache_dir.join("nix")).ok();

        let args =
            self.build_run_args(&container_name, config, project_path, cache_dir, port_range);

        self.client.run_container(&args).await?;

        Ok(ContainerInfo {
            name: container_name,
            project_name: project_name.to_string(),
            genus,
            state: tillandsias_core::event::ContainerState::Creating,
            port_range,
        })
    }

    /// Graceful stop: SIGTERM → 10s grace → SIGKILL.
    pub async fn stop(&self, container_name: &str) -> Result<(), PodmanError> {
        // First try graceful stop with 10s timeout
        match tokio::time::timeout(
            std::time::Duration::from_secs(12),
            self.client.stop_container(container_name, 10),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => {
                // Timeout — force kill
                self.client.kill_container(container_name).await
            }
        }
    }

    /// Destroy: stop + remove cache for the project.
    pub async fn destroy(
        &self,
        container_name: &str,
        cache_dir: &std::path::Path,
        project_name: &str,
    ) -> Result<(), PodmanError> {
        self.stop(container_name).await?;
        self.client.remove_container(container_name).await?;

        // Remove project-specific cache (never touch ~/src!)
        let project_cache = cache_dir.join(project_name);
        if project_cache.exists() {
            std::fs::remove_dir_all(&project_cache).ok();
        }

        Ok(())
    }
}

/// Query port mappings from running tillandsias containers via podman.
///
/// Returns a list of `(start, end)` port ranges currently occupied by
/// tillandsias containers on the host. Falls back to an empty list if
/// podman is unavailable or returns an error.
pub fn query_occupied_ports() -> Vec<(u16, u16)> {
    let output = std::process::Command::new("podman")
        .args([
            "ps",
            "--filter",
            "name=tillandsias-",
            "--format",
            "{{.Ports}}",
        ])
        .output();

    match output {
        Ok(out) if out.status.success() => {
            let stdout = String::from_utf8_lossy(&out.stdout);
            parse_port_output(&stdout)
        }
        _ => vec![],
    }
}

/// Parse podman port output like "0.0.0.0:3000-3019->3000-3019/tcp, 3000-3019/tcp"
///
/// Only extracts host-side port mappings (the part before `->`) so we know
/// which host ports are actually bound.
fn parse_port_output(output: &str) -> Vec<(u16, u16)> {
    let mut ranges = vec![];
    for line in output.lines() {
        for part in line.split(", ") {
            // Look for host port mappings: "0.0.0.0:3000-3019->3000-3019/tcp"
            if let Some(host_part) = part.split("->").next() {
                // Strip IP prefix: "0.0.0.0:3000-3019" -> "3000-3019"
                let port_part = host_part.rsplit(':').next().unwrap_or(host_part);
                if let Some((start, end)) = port_part.split_once('-') {
                    if let (Ok(s), Ok(e)) = (start.parse::<u16>(), end.parse::<u16>()) {
                        ranges.push((s, e));
                    }
                }
            }
        }
    }
    ranges
}

/// Allocate a non-overlapping port range for a new environment.
pub fn allocate_port_range(base: (u16, u16), existing_ranges: &[(u16, u16)]) -> (u16, u16) {
    let range_size = base.1 - base.0;
    let mut candidate = base;

    loop {
        let overlaps = existing_ranges
            .iter()
            .any(|existing| candidate.0 <= existing.1 && candidate.1 >= existing.0);

        if !overlaps {
            return candidate;
        }

        // Shift up by range_size + 1
        candidate = (candidate.0 + range_size + 1, candidate.1 + range_size + 1);

        // Safety: don't exceed valid port range
        if candidate.1 >= 65500 {
            return candidate; // Best effort
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_args_has_security_flags() {
        let launcher = ContainerLauncher::new(PodmanClient::new());
        let config = ResolvedConfig {
            image: "test:latest".to_string(),
            port_range: "3000-3019".to_string(),
            security: SecurityConfig {
                cap_drop_all: true,
                no_new_privileges: true,
                userns_keep_id: true,
            },
            mounts: vec![],
            runtime: None,
        };

        let args = launcher.build_run_args(
            "tillandsias-test-aeranthos",
            &config,
            std::path::Path::new("/tmp/test-project"),
            std::path::Path::new("/tmp/cache"),
            (3000, 3019),
        );

        assert!(args.contains(&"--cap-drop=ALL".to_string()));
        assert!(args.contains(&"--security-opt=no-new-privileges".to_string()));
        assert!(args.contains(&"--userns=keep-id".to_string()));
        assert!(args.contains(&"--security-opt=label=disable".to_string()));
        assert!(args.contains(&"--rm".to_string()));
        assert!(args.contains(&"-d".to_string()));
    }

    #[test]
    fn build_args_has_container_name() {
        let launcher = ContainerLauncher::new(PodmanClient::new());
        let config = ResolvedConfig {
            image: "test:latest".to_string(),
            port_range: "3000-3019".to_string(),
            security: SecurityConfig::default(),
            mounts: vec![],
            runtime: None,
        };

        let args = launcher.build_run_args(
            "tillandsias-my-app-aeranthos",
            &config,
            std::path::Path::new("/tmp/test"),
            std::path::Path::new("/tmp/cache"),
            (3000, 3019),
        );

        let name_idx = args.iter().position(|a| a == "--name").unwrap();
        assert_eq!(args[name_idx + 1], "tillandsias-my-app-aeranthos");
    }

    #[test]
    fn build_args_has_port_mapping() {
        let launcher = ContainerLauncher::new(PodmanClient::new());
        let config = ResolvedConfig {
            image: "test:latest".to_string(),
            port_range: "3000-3019".to_string(),
            security: SecurityConfig::default(),
            mounts: vec![],
            runtime: None,
        };

        let args = launcher.build_run_args(
            "test",
            &config,
            std::path::Path::new("/tmp/test"),
            std::path::Path::new("/tmp/cache"),
            (3000, 3019),
        );

        assert!(args.contains(&"3000-3019:3000-3019".to_string()));
    }

    #[test]
    fn allocate_port_range_no_conflicts() {
        let range = allocate_port_range((3000, 3019), &[]);
        assert_eq!(range, (3000, 3019));
    }

    #[test]
    fn allocate_port_range_with_conflict() {
        let range = allocate_port_range((3000, 3019), &[(3000, 3019)]);
        assert_eq!(range, (3020, 3039));
    }

    #[test]
    fn allocate_port_range_multiple_conflicts() {
        let range = allocate_port_range((3000, 3019), &[(3000, 3019), (3020, 3039)]);
        assert_eq!(range, (3040, 3059));
    }

    #[test]
    fn parse_port_output_standard() {
        let output = "0.0.0.0:3000-3019->3000-3019/tcp\n";
        let ranges = parse_port_output(output);
        assert_eq!(ranges, vec![(3000, 3019)]);
    }

    #[test]
    fn parse_port_output_multiple_mappings() {
        let output = "0.0.0.0:3000-3019->3000-3019/tcp, 0.0.0.0:3020-3039->3020-3039/tcp\n";
        let ranges = parse_port_output(output);
        assert_eq!(ranges, vec![(3000, 3019), (3020, 3039)]);
    }

    #[test]
    fn parse_port_output_multiline() {
        let output = "0.0.0.0:3000-3019->3000-3019/tcp\n0.0.0.0:3020-3039->3020-3039/tcp\n";
        let ranges = parse_port_output(output);
        assert_eq!(ranges, vec![(3000, 3019), (3020, 3039)]);
    }

    #[test]
    fn parse_port_output_empty() {
        let ranges = parse_port_output("");
        assert!(ranges.is_empty());
    }

    #[test]
    fn parse_port_output_no_arrow() {
        // Container-only ports without host mapping should be ignored
        let output = "3000-3019/tcp\n";
        let ranges = parse_port_output(output);
        assert!(ranges.is_empty());
    }

    #[test]
    fn container_naming_convention() {
        let name = ContainerInfo::container_name("my-project", TillandsiaGenus::Ionantha);
        assert_eq!(name, "tillandsias-my-project-ionantha");
    }
}

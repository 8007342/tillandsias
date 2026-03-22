use crate::event::ContainerState;
use crate::genus::{PlantLifecycle, TillandsiaGenus};
use crate::project::Project;

/// Info about a running container environment.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ContainerInfo {
    /// Full container name: tillandsias-<project>-<genus>
    pub name: String,
    /// Project this environment belongs to
    pub project_name: String,
    /// Assigned tillandsia genus
    pub genus: TillandsiaGenus,
    /// Current container state
    pub state: ContainerState,
    /// Allocated port range (start, end inclusive)
    pub port_range: (u16, u16),
}

impl ContainerInfo {
    /// Build container name from project and genus.
    pub fn container_name(project_name: &str, genus: TillandsiaGenus) -> String {
        format!("tillandsias-{}-{}", project_name, genus.slug())
    }

    /// Parse project name and genus from a container name.
    pub fn parse_container_name(name: &str) -> Option<(String, TillandsiaGenus)> {
        let stripped = name.strip_prefix("tillandsias-")?;
        // Find the last hyphen-delimited segment that matches a genus slug.
        // Genus slugs can contain hyphens (e.g., "caput-medusae"), so try
        // matching from longest suffix first.
        for genus in TillandsiaGenus::ALL {
            let slug = genus.slug();
            if let Some(project) = stripped.strip_suffix(&format!("-{slug}")) {
                if !project.is_empty() {
                    return Some((project.to_string(), *genus));
                }
            }
        }
        None
    }

    /// Current plant lifecycle state for icon rendering.
    pub fn lifecycle(&self) -> PlantLifecycle {
        PlantLifecycle::from_container_state(&self.state)
    }
}

/// Platform detection for cross-platform behavior.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PlatformInfo {
    pub os: Os,
    pub has_podman: bool,
    pub has_podman_machine: bool,
    pub gpu_devices: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum Os {
    Linux,
    MacOS,
    Windows,
}

impl Os {
    pub fn detect() -> Self {
        if cfg!(target_os = "linux") {
            Self::Linux
        } else if cfg!(target_os = "macos") {
            Self::MacOS
        } else {
            Self::Windows
        }
    }

    pub fn needs_podman_machine(&self) -> bool {
        matches!(self, Self::MacOS | Self::Windows)
    }
}

/// Full tray state rebuilt on every event.
#[derive(Debug, Clone)]
pub struct TrayState {
    pub projects: Vec<Project>,
    pub running: Vec<ContainerInfo>,
    pub platform: PlatformInfo,
}

impl TrayState {
    pub fn new(platform: PlatformInfo) -> Self {
        Self {
            projects: Vec::new(),
            running: Vec::new(),
            platform,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::genus::TillandsiaGenus;

    #[test]
    fn container_name_format() {
        let name = ContainerInfo::container_name("my-app", TillandsiaGenus::Aeranthos);
        assert_eq!(name, "tillandsias-my-app-aeranthos");
    }

    #[test]
    fn parse_container_name_simple() {
        let (project, genus) =
            ContainerInfo::parse_container_name("tillandsias-my-app-aeranthos").unwrap();
        assert_eq!(project, "my-app");
        assert_eq!(genus, TillandsiaGenus::Aeranthos);
    }

    #[test]
    fn parse_container_name_hyphenated_genus() {
        let (project, genus) =
            ContainerInfo::parse_container_name("tillandsias-cool-project-caput-medusae").unwrap();
        assert_eq!(project, "cool-project");
        assert_eq!(genus, TillandsiaGenus::CaputMedusae);
    }

    #[test]
    fn parse_container_name_invalid() {
        assert!(ContainerInfo::parse_container_name("random-container").is_none());
        assert!(ContainerInfo::parse_container_name("tillandsias-").is_none());
    }

    #[test]
    fn postcard_roundtrip_container_info() {
        let info = ContainerInfo {
            name: "tillandsias-my-app-aeranthos".to_string(),
            project_name: "my-app".to_string(),
            genus: TillandsiaGenus::Aeranthos,
            state: crate::event::ContainerState::Running,
            port_range: (3000, 3099),
        };
        let bytes = postcard::to_allocvec(&info).unwrap();
        let decoded: ContainerInfo = postcard::from_bytes(&bytes).unwrap();
        assert_eq!(decoded.name, info.name);
        assert_eq!(decoded.project_name, info.project_name);
        assert_eq!(decoded.genus, info.genus);
        assert_eq!(decoded.state, info.state);
        assert_eq!(decoded.port_range, info.port_range);
    }
}

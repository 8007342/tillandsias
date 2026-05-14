// @trace spec:podman-container-spec, spec:podman-container-handle
use std::path::{Path, PathBuf};

use tillandsias_core::state::ContainerInfo;

/// Mode for a bind or volume mount.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MountMode {
    ReadOnly,
    ReadWrite,
    Custom(String),
}

impl MountMode {
    fn suffix(&self) -> Option<&str> {
        match self {
            MountMode::ReadOnly => Some("ro"),
            MountMode::ReadWrite => Some("rw"),
            MountMode::Custom(mode) => Some(mode.as_str()),
        }
    }
}

/// Mount specification for a container launch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MountSpec {
    Volume {
        source: String,
        target: String,
        mode: MountMode,
    },
    Bind {
        source: String,
        target: String,
        readonly: bool,
    },
}

impl MountSpec {
    fn to_args(&self) -> Vec<String> {
        match self {
            MountSpec::Volume {
                source,
                target,
                mode,
            } => {
                let mut value = format!("{source}:{target}");
                if let Some(suffix) = mode.suffix() {
                    value.push(':');
                    value.push_str(suffix);
                }
                vec!["-v".to_string(), value]
            }
            MountSpec::Bind {
                source,
                target,
                readonly,
            } => {
                let mut value = format!("type=bind,source={source},target={target}");
                if *readonly {
                    value.push_str(",readonly=true");
                }
                vec!["--mount".to_string(), value]
            }
        }
    }
}

/// Typed podman `run` specification.
///
/// This is intentionally opinionated: the Tillandsias runtime considers the
/// security baseline non-negotiable, so the immutable defaults are enabled at
/// construction time and the builder only exposes safe additions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContainerSpec {
    image: String,
    name: Option<String>,
    hostname: Option<String>,
    detached: bool,
    remove: bool,
    init: bool,
    interactive: bool,
    tty: bool,
    read_only: bool,
    pull_never: bool,
    userns_keep_id: bool,
    cap_drop_all: bool,
    cap_add: Vec<String>,
    no_new_privileges: bool,
    label_disable: bool,
    pids_limit: Option<u32>,
    network: Option<String>,
    env: Vec<(String, String)>,
    mounts: Vec<MountSpec>,
    tmpfs: Vec<String>,
    devices: Vec<String>,
    options: Vec<String>,
    publish: Vec<String>,
    entrypoint: Option<String>,
    command: Vec<String>,
}

impl ContainerSpec {
    pub fn new(image: impl Into<String>) -> Self {
        Self {
            image: image.into(),
            name: None,
            hostname: None,
            detached: false,
            remove: true,
            init: true,
            interactive: false,
            tty: false,
            read_only: false,
            pull_never: false,
            userns_keep_id: true,
            cap_drop_all: true,
            cap_add: Vec::new(),
            no_new_privileges: true,
            label_disable: true,
            pids_limit: None,
            network: None,
            env: Vec::new(),
            mounts: Vec::new(),
            tmpfs: Vec::new(),
            devices: Vec::new(),
            options: Vec::new(),
            publish: Vec::new(),
            entrypoint: None,
            command: Vec::new(),
        }
    }

    pub fn name(mut self, value: impl Into<String>) -> Self {
        self.name = Some(value.into());
        self
    }

    pub fn hostname(mut self, value: impl Into<String>) -> Self {
        self.hostname = Some(value.into());
        self
    }

    pub fn detached(mut self) -> Self {
        self.detached = true;
        self
    }

    pub fn interactive(mut self) -> Self {
        self.interactive = true;
        self
    }

    pub fn tty(mut self) -> Self {
        self.tty = true;
        self
    }

    pub fn read_only(mut self) -> Self {
        self.read_only = true;
        self
    }

    pub fn persistent(mut self) -> Self {
        self.remove = false;
        self
    }

    pub fn pull_never(mut self) -> Self {
        self.pull_never = true;
        self
    }

    pub fn pids_limit(mut self, value: u32) -> Self {
        self.pids_limit = Some(value);
        self
    }

    pub fn network(mut self, value: impl Into<String>) -> Self {
        self.network = Some(value.into());
        self
    }

    pub fn env(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.env.push((key.into(), value.into()));
        self
    }

    pub fn volume(
        mut self,
        source: impl Into<String>,
        target: impl Into<String>,
        mode: MountMode,
    ) -> Self {
        self.mounts.push(MountSpec::Volume {
            source: source.into(),
            target: target.into(),
            mode,
        });
        self
    }

    pub fn bind_mount(
        mut self,
        source: impl Into<String>,
        target: impl Into<String>,
        readonly: bool,
    ) -> Self {
        self.mounts.push(MountSpec::Bind {
            source: source.into(),
            target: target.into(),
            readonly,
        });
        self
    }

    pub fn option(mut self, value: impl Into<String>) -> Self {
        self.options.push(value.into());
        self
    }

    pub fn cap_add(mut self, value: impl Into<String>) -> Self {
        self.cap_add.push(value.into());
        self
    }

    pub fn publish(mut self, spec: impl Into<String>) -> Self {
        self.publish.push(spec.into());
        self
    }

    pub fn tmpfs(mut self, spec: impl Into<String>) -> Self {
        self.tmpfs.push(spec.into());
        self
    }

    pub fn device(mut self, spec: impl Into<String>) -> Self {
        self.devices.push(spec.into());
        self
    }

    pub fn entrypoint(mut self, value: impl Into<String>) -> Self {
        self.entrypoint = Some(value.into());
        self
    }

    pub fn arg(mut self, value: impl Into<String>) -> Self {
        self.command.push(value.into());
        self
    }

    pub fn image(&self) -> &str {
        &self.image
    }

    pub fn name_ref(&self) -> Option<&str> {
        self.name.as_deref()
    }

    pub fn build_run_args(&self) -> Vec<String> {
        let mut args = Vec::new();

        if self.detached {
            args.push("-d".to_string());
        }
        if self.remove {
            args.push("--rm".to_string());
        }
        if self.init {
            args.push("--init".to_string());
        }
        if self.pull_never {
            args.push("--pull=never".to_string());
        }
        if let Some(name) = &self.name {
            args.push("--name".to_string());
            args.push(name.clone());
        }
        if let Some(hostname) = &self.hostname {
            args.push("--hostname".to_string());
            args.push(hostname.clone());
        }
        if self.userns_keep_id {
            args.push("--userns=keep-id".to_string());
        }
        if self.cap_drop_all {
            args.push("--cap-drop=ALL".to_string());
        }
        for cap in &self.cap_add {
            args.push("--cap-add".to_string());
            args.push(cap.clone());
        }
        if self.no_new_privileges {
            args.push("--security-opt=no-new-privileges".to_string());
        }
        if self.label_disable {
            args.push("--security-opt=label=disable".to_string());
        }
        if self.read_only {
            args.push("--read-only".to_string());
        }
        if let Some(limit) = self.pids_limit {
            args.push("--pids-limit".to_string());
            args.push(limit.to_string());
        }

        for (key, value) in &self.env {
            args.push("--env".to_string());
            args.push(format!("{key}={value}"));
        }

        if let Some(network) = &self.network {
            args.push("--network".to_string());
            args.push(network.clone());
        }

        for mount in &self.mounts {
            args.extend(mount.to_args());
        }

        for tmpfs in &self.tmpfs {
            args.push("--tmpfs".to_string());
            args.push(tmpfs.clone());
        }

        for device in &self.devices {
            args.push("--device".to_string());
            args.push(device.clone());
        }

        args.extend(self.options.iter().cloned());

        for publish in &self.publish {
            args.push("-p".to_string());
            args.push(publish.clone());
        }

        if let Some(entrypoint) = &self.entrypoint {
            args.push("--entrypoint".to_string());
            args.push(entrypoint.clone());
        }

        args.push(self.image.clone());
        args.extend(self.command.iter().cloned());

        args
    }

    pub fn build_run_argv(&self) -> Vec<String> {
        let mut argv = vec!["run".to_string()];
        argv.extend(self.build_run_args());
        argv
    }
}

/// Lightweight runtime handle for a launched container request.
#[derive(Debug, Clone)]
pub struct ContainerHandle {
    info: ContainerInfo,
    spec: ContainerSpec,
}

impl ContainerHandle {
    pub fn new(info: ContainerInfo, spec: ContainerSpec) -> Self {
        Self { info, spec }
    }

    pub fn name(&self) -> &str {
        &self.info.name
    }

    pub fn image(&self) -> &str {
        self.spec.image()
    }

    pub fn spec(&self) -> &ContainerSpec {
        &self.spec
    }

    pub fn info(&self) -> &ContainerInfo {
        &self.info
    }

    pub fn into_spec(self) -> ContainerSpec {
        self.spec
    }
}

/// Helper to normalize a path to an owned string for container mounts.
pub fn path_to_string(path: impl AsRef<Path>) -> String {
    path.as_ref().display().to_string()
}

/// Helper to normalize a path into a canonical mount source when possible.
pub fn canonical_or_display(path: impl AsRef<Path>) -> PathBuf {
    path.as_ref()
        .canonicalize()
        .unwrap_or_else(|_| path.as_ref().to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_spec_includes_immutable_hardening_flags() {
        let spec = ContainerSpec::new("example:v1")
            .name("tillandsias-example")
            .hostname("forge-example");
        let args = spec.build_run_args();

        assert!(args.contains(&"--init".to_string()));
        assert!(args.contains(&"--rm".to_string()));
        assert!(args.contains(&"--userns=keep-id".to_string()));
        assert!(args.contains(&"--cap-drop=ALL".to_string()));
        assert!(args.contains(&"--security-opt=no-new-privileges".to_string()));
        assert!(args.contains(&"--security-opt=label=disable".to_string()));
    }

    #[test]
    fn persistent_web_profile_is_detached_and_not_auto_removed() {
        let spec = ContainerSpec::new("example:v1")
            .name("tillandsias-example")
            .detached()
            .persistent()
            .entrypoint("/bin/true");
        let args = spec.build_run_args();

        assert!(args.contains(&"-d".to_string()));
        assert!(!args.contains(&"--rm".to_string()));
        assert!(args.contains(&"--init".to_string()));
    }

    #[test]
    fn browser_flags_can_be_expressed_in_the_typed_spec() {
        let spec = ContainerSpec::new("example:v1")
            .pull_never()
            .read_only()
            .cap_add("SYS_CHROOT")
            .tmpfs("/tmp:size=256m")
            .tmpfs("/dev/shm:size=256m")
            .device("/dev/dri/renderD128")
            .option("--network=host");
        let args = spec.build_run_args();

        assert!(args.contains(&"--pull=never".to_string()));
        assert!(args.contains(&"--read-only".to_string()));
        assert!(args.contains(&"--cap-add".to_string()));
        assert!(args.contains(&"SYS_CHROOT".to_string()));
        assert!(args.contains(&"--tmpfs".to_string()));
        assert!(args.contains(&"/tmp:size=256m".to_string()));
        assert!(args.contains(&"--device".to_string()));
        assert!(args.contains(&"/dev/dri/renderD128".to_string()));
    }

    #[test]
    fn bind_and_volume_mounts_are_serialized_deterministically() {
        let spec = ContainerSpec::new("example:v1")
            .volume("/src", "/workspace", MountMode::ReadWrite)
            .bind_mount("/tmp/ca.crt", "/etc/ca.crt", true);
        let args = spec.build_run_args();

        assert!(args.contains(&"-v".to_string()));
        assert!(args.contains(&"/src:/workspace:rw".to_string()));
        assert!(args.contains(&"--mount".to_string()));
        assert!(
            args.iter()
                .any(|arg| arg == "type=bind,source=/tmp/ca.crt,target=/etc/ca.crt,readonly=true")
        );
    }

    #[test]
    fn build_run_argv_prefixes_run() {
        let spec = ContainerSpec::new("example:v1");
        let argv = spec.build_run_argv();
        assert_eq!(argv.first().map(|s| s.as_str()), Some("run"));
    }

    #[test]
    fn handle_exposes_name_and_image() {
        let spec = ContainerSpec::new("example:v1");
        let info = ContainerInfo {
            name: "tillandsias-example".to_string(),
            project_name: "example".to_string(),
            genus: tillandsias_core::genus::TillandsiaGenus::Ionantha,
            state: tillandsias_core::event::ContainerState::Creating,
            port_range: (3000, 3019),
            container_type: tillandsias_core::state::ContainerType::Forge,
            display_emoji: "🌿".to_string(),
        };
        let handle = ContainerHandle::new(info, spec.clone());
        assert_eq!(handle.name(), "tillandsias-example");
        assert_eq!(handle.image(), "example:v1");
        assert_eq!(handle.spec(), &spec);
    }
}

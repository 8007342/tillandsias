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
                let mut value = format!("type=bind,source={source},target={target},relabel=shared");
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
    // ORDER 972-6vaj: there is deliberately no `cap_add`. The field existed as
    // an unvalidated pass-through — any string, straight onto the podman
    // command line, re-granting whatever `--cap-drop=ALL` had just removed —
    // and it had ZERO production callers; the only use in the tree was one
    // test granting SYS_CHROOT. The exit criterion offered "validated against
    // an allowlist or the field is removed", and removal is the stronger and
    // cheaper of the two: an allowlist is a policy to maintain and a place for
    // an exception to be argued, while an absent field cannot be misused and
    // needs no guard. Re-adding it means re-adding the escape hatch, so if a
    // real need appears, add the capability to the profile that needs it with
    // its own justification rather than restoring a general-purpose bypass.
    no_new_privileges: bool,
    label_disable: bool,
    pids_limit: Option<u32>,
    network: Option<String>,
    env: Vec<(String, String)>,
    secrets: Vec<String>,
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
            no_new_privileges: true,
            label_disable: true,
            pids_limit: None,
            network: None,
            env: Vec::new(),
            secrets: Vec::new(),
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

    pub fn secret(mut self, spec: impl Into<String>) -> Self {
        self.secrets.push(spec.into());
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
        let value = value.into();
        if crate::policy::is_allowlisted_passthrough_option(&value) {
            self.options.push(value);
        }
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
        if self.no_new_privileges {
            args.push("--security-opt=no-new-privileges".to_string());
        }
        if self.label_disable {
            args.push("--security-opt=label=disable".to_string());
        }
        if self.read_only {
            args.push("--read-only".to_string());
        }
        // @trace spec:browser-isolation-tray-integration, spec:tray-ux
        // Interactive / tty flags drive the per-project tray launches that
        // spawn a forge shell inside the host's default terminal emulator.
        // Both flags are mutually compatible with `--detach` rejection in
        // policy.rs: a spec marked `.detached().interactive()` would have
        // semantic-conflict properties that are blocked at the call-site
        // (see `launch_forge_agent`), not here.
        if self.interactive {
            args.push("--interactive".to_string());
        }
        if self.tty {
            args.push("--tty".to_string());
        }
        if let Some(limit) = self.pids_limit {
            args.push("--pids-limit".to_string());
            args.push(limit.to_string());
        }

        for (key, value) in &self.env {
            args.push("--env".to_string());
            args.push(format!("{key}={value}"));
        }

        for secret in &self.secrets {
            args.push("--secret".to_string());
            args.push(secret.clone());
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

    /// Serialize to `podman run` argv, REFUSING an argv that violates the
    /// immutable hardening envelope (order 972-6vaj).
    ///
    /// THIS WAS A `debug_assert!` AND THEREFORE NOTHING. `debug_assert!` is
    /// compiled out of release builds, so the only non-test reference to
    /// `validate_launch_argv` in the entire tree evaporated in every shipped
    /// binary: the validator had zero production call sites, and the envelope
    /// the spec calls "immutable" was enforced by nobody at runtime.
    ///
    /// It returns `Result` rather than logging and continuing on purpose. An
    /// argv that has lost a hardening flag is not a degraded launch to be
    /// reported, it is a container that must not be created — and a warning
    /// printed beside a successful launch is the "fail safe-looking" outcome
    /// this project keeps paying for. The caller decides what to do with the
    /// refusal; it cannot silently ignore one.
    // @trace order:972-6vaj, spec:podman-orchestration, spec:security-privacy-isolation
    pub fn build_run_argv(&self) -> Result<Vec<String>, crate::policy::LaunchArgvError> {
        let mut argv = vec!["run".to_string()];
        argv.extend(self.build_run_args());
        crate::policy::validate_launch_argv(&argv)?;
        Ok(argv)
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
    fn interactive_and_tty_flags_are_serialized() {
        // Regression: prior versions of `build_run_args` tracked `.interactive()`
        // and `.tty()` in the spec but never emitted them, so tray-spawned
        // forge shells silently dropped to non-interactive mode. The per-project
        // tray launches (Claude / Codex / OpenCode / Maintenance) depend on
        // these flags reaching `podman run`.
        let spec = ContainerSpec::new("example:v1").interactive().tty();
        let args = spec.build_run_args();

        assert!(args.contains(&"--interactive".to_string()));
        assert!(args.contains(&"--tty".to_string()));
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

    /// ORDER 972-6vaj, EXIT CRITERION 2: this must hold in the RELEASE profile,
    /// which is exactly what the `debug_assert!` it replaces could not do.
    ///
    /// The gate runs `cargo test --release`, so this test executes with
    /// `debug_assertions` OFF. Under the old code the validator call vanished
    /// there and the argv was returned unchecked; a test asserting the old
    /// behaviour would have passed in debug and proved nothing about any
    /// shipped binary. Asserting on the RETURNED VALUE rather than on a panic
    /// is what makes the check profile-independent.
    #[test]
    // @trace order:972-6vaj, spec:podman-orchestration
    fn the_hardening_envelope_is_enforced_in_release_not_only_in_debug() {
        // The negative control first: if this ever passes, the enforcement is
        // gone and every assertion below is vacuous.
        let stripped = vec![
            "run".to_string(),
            "--rm".to_string(),
            "example:v1".to_string(),
        ];
        assert!(
            crate::policy::validate_launch_argv(&stripped).is_err(),
            "an argv with no hardening flags must not validate"
        );

        // A spec built through the public API carries the whole envelope and
        // serializes successfully.
        let spec = ContainerSpec::new("example:v1").name("probe");
        let argv = spec
            .build_run_argv()
            .expect("a spec built through the public builder must be policy-valid");
        for flag in crate::policy::MANDATORY_HARDENING_FLAGS {
            assert!(argv.iter().any(|a| a == flag), "argv lost {flag}: {argv:?}");
        }

        // AND THE PROOF THAT THE CHECK IS LIVE IN THIS PROFILE: strip a flag
        // from a real serialization and confirm the validator rejects it. This
        // is the case a `debug_assert!` could not observe in release at all.
        let without_cap_drop: Vec<String> = argv
            .iter()
            .filter(|a| *a != "--cap-drop=ALL")
            .cloned()
            .collect();
        assert!(
            crate::policy::validate_launch_argv(&without_cap_drop).is_err(),
            "removing --cap-drop=ALL must be refused, in every profile"
        );

        // Say out loud which profile actually ran, so a green result cannot be
        // mistaken for coverage it does not have.
        if cfg!(debug_assertions) {
            eprintln!("note: ran with debug_assertions ON; the gate also runs this --release");
        }
    }

    #[test]
    fn browser_flags_can_be_expressed_in_the_typed_spec() {
        let spec = ContainerSpec::new("example:v1")
            .pull_never()
            .read_only()
            .tmpfs("/tmp:size=256m")
            .tmpfs("/dev/shm:size=256m")
            .device("/dev/dri/renderD128")
            .network("host");
        let args = spec.build_run_args();

        assert!(args.contains(&"--pull=never".to_string()));
        assert!(args.contains(&"--read-only".to_string()));
        // ORDER 972-6vaj: this used to assert `--cap-add SYS_CHROOT`, and it
        // was the ONLY place in the tree that granted a capability — no
        // production caller ever did. The assertion is inverted rather than
        // deleted so the removal is pinned: nothing may re-grant, through this
        // type, a capability that `--cap-drop=ALL` just removed. A profile that
        // genuinely needs one adds it with its own justification; it does not
        // get a general-purpose bypass back.
        assert!(
            !args.iter().any(|a| a == "--cap-add"),
            "the cap_add escape hatch must stay removed: {args:?}"
        );
        assert!(args.contains(&"--tmpfs".to_string()));
        assert!(args.contains(&"/tmp:size=256m".to_string()));
        assert!(args.contains(&"--device".to_string()));
        assert!(args.contains(&"/dev/dri/renderD128".to_string()));
        assert!(args.contains(&"--network".to_string()));
        assert!(args.contains(&"host".to_string()));
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
        assert!(args.iter().any(|arg| arg
            == "type=bind,source=/tmp/ca.crt,target=/etc/ca.crt,relabel=shared,readonly=true"));
    }

    #[test]
    fn scoped_secret_mounts_are_serialized_by_the_typed_spec() {
        let spec = ContainerSpec::new("example:v1")
            .secret("codex-lease,target=vault-token,uid=1000,gid=1000,mode=0400");
        let args = spec.build_run_args();
        let secret_flag = args
            .iter()
            .position(|arg| arg == "--secret")
            .expect("typed secret flag");
        assert_eq!(
            args.get(secret_flag + 1).map(String::as_str),
            Some("codex-lease,target=vault-token,uid=1000,gid=1000,mode=0400")
        );
    }

    #[test]
    fn build_run_argv_prefixes_run() {
        let spec = ContainerSpec::new("example:v1");
        // Order 972-6vaj: build_run_argv now REFUSES a policy-invalid argv
        // instead of asserting only in debug, so the happy path unwraps.
        let argv = spec.build_run_argv().expect("policy-valid");
        assert_eq!(argv.first().map(|s| s.as_str()), Some("run"));
        assert!(crate::policy::validate_launch_argv(&argv).is_ok());
    }

    #[test]
    fn raw_option_passthrough_is_narrowly_allowlisted() {
        let spec = ContainerSpec::new("example:v1")
            .option("--privileged")
            .option("--network=host")
            .option("--device=/dev/dri/renderD128");
        let args = spec.build_run_args();

        assert!(!args.contains(&"--privileged".to_string()));
        assert!(!args.contains(&"--network=host".to_string()));
        assert!(args.contains(&"--device=/dev/dri/renderD128".to_string()));
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

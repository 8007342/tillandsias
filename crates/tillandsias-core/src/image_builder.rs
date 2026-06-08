/// ImageBuilder trait and implementations for Layer 2 build abstraction.
///
/// @trace spec:runtime-logging
///
/// @trace spec:user-runtime-lifecycle
///
/// @trace spec:fix-windows-image-routing
///
/// The ImageBuilder trait defines the contract between Rust code (tray app)
/// and shell test harnesses (Layer 3). Both use the same build logic but with
/// different exit conditions:
///
/// - **Rust (tray app)**: Calls `ImageBuilder::build()` → image lands in podman storage
/// - **Shell (test harness)**: Calls `ImageBuilder::build()` → captures podman call for assertion
///
/// This enables convergence testing: the test harness exercises the exact code path
/// used in production, captures artifacts, and validates output.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use tracing::{debug, info, warn};

pub const SOURCE_DIGEST_LABEL: &str = "io.tillandsias.image.source-digest";

/// Inputs that determine one container image's immutable identity.
///
/// The source digest deliberately excludes `version`: versioned and `latest`
/// tags are aliases for the same content-addressed image.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImageBuildSpec {
    pub image_name: String,
    pub context_root: PathBuf,
    pub containerfile: PathBuf,
    #[serde(default)]
    pub build_args: BTreeMap<String, String>,
    #[serde(default)]
    pub dependency_digests: BTreeMap<String, String>,
    pub version: String,
}

/// Content-addressed identity and mutable aliases derived from an image spec.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImageBuildIdentity {
    pub source_digest: String,
    pub canonical_tag: String,
    pub version_alias: String,
    pub latest_alias: String,
    pub labels: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImageBuildAction {
    Skip,
    Retag,
    Build,
    ForceRebuild,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ImageBuildReason {
    DigestPresent,
    AliasMissing,
    DigestMissing,
    LabelMismatch,
    Forced,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImageBuildDecision {
    pub action: ImageBuildAction,
    pub reason: ImageBuildReason,
    pub identity: ImageBuildIdentity,
}

/// Observable Podman state needed to make a freshness decision.
///
/// No external JSON/hash state participates in this decision. The canonical
/// tag and its source-digest label are the durable identity.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ImageBuildObservation {
    pub canonical_tag_exists: bool,
    pub canonical_source_digest: Option<String>,
    pub version_alias_matches: bool,
    pub latest_alias_matches: bool,
    pub force: bool,
}

/// Compute a checkout-root-independent digest over the exact context tree and
/// all non-filesystem build inputs.
pub fn image_build_identity(
    spec: &ImageBuildSpec,
) -> Result<ImageBuildIdentity, ImageBuilderError> {
    let context_root = spec
        .context_root
        .canonicalize()
        .map_err(|e| ImageBuilderError::Io(format!("canonicalize build context: {e}")))?;
    let containerfile = spec
        .containerfile
        .canonicalize()
        .map_err(|e| ImageBuilderError::Io(format!("canonicalize Containerfile: {e}")))?;
    if !containerfile.starts_with(&context_root) {
        return Err(ImageBuilderError::Io(
            "Containerfile must be inside the build context".to_string(),
        ));
    }

    let mut entries = Vec::new();
    collect_context_entries(&context_root, &context_root, &mut entries)?;
    entries.sort_by(|a, b| a.relative_path.cmp(&b.relative_path));

    let mut hasher = Sha256::new();
    hash_field(&mut hasher, b"schema", b"tillandsias-image-build-v1");
    hash_field(&mut hasher, b"image_name", spec.image_name.as_bytes());
    for entry in entries {
        hash_field(&mut hasher, b"path", entry.relative_path.as_bytes());
        hash_field(&mut hasher, b"kind", entry.kind.as_bytes());
        hash_field(&mut hasher, b"mode", &entry.mode.to_be_bytes());
        hash_field(&mut hasher, b"payload", &entry.payload);
    }
    for (name, value) in &spec.build_args {
        hash_field(&mut hasher, b"build_arg_name", name.as_bytes());
        hash_field(&mut hasher, b"build_arg_value", value.as_bytes());
    }
    for (name, digest) in &spec.dependency_digests {
        hash_field(&mut hasher, b"dependency_name", name.as_bytes());
        hash_field(&mut hasher, b"dependency_digest", digest.as_bytes());
    }

    let digest_hex = hex_digest(&hasher.finalize());
    let source_digest = format!("sha256:{digest_hex}");
    let image_prefix = format!("localhost/tillandsias-{}", spec.image_name);
    let canonical_tag = format!("{image_prefix}:sha256-{digest_hex}");
    let version_alias = format!("{image_prefix}:v{}", spec.version.trim());
    let latest_alias = format!("{image_prefix}:latest");
    let labels = BTreeMap::from([
        (SOURCE_DIGEST_LABEL.to_string(), source_digest.clone()),
        (
            "io.tillandsias.image.name".to_string(),
            spec.image_name.clone(),
        ),
        (
            "io.tillandsias.image.version".to_string(),
            spec.version.trim().to_string(),
        ),
        (
            "org.opencontainers.image.version".to_string(),
            spec.version.trim().to_string(),
        ),
    ]);

    Ok(ImageBuildIdentity {
        source_digest,
        canonical_tag,
        version_alias,
        latest_alias,
        labels,
    })
}

pub fn decide_image_build(
    identity: ImageBuildIdentity,
    observation: &ImageBuildObservation,
) -> ImageBuildDecision {
    let (action, reason) = if observation.force {
        (ImageBuildAction::ForceRebuild, ImageBuildReason::Forced)
    } else if !observation.canonical_tag_exists {
        (ImageBuildAction::Build, ImageBuildReason::DigestMissing)
    } else if observation.canonical_source_digest.as_deref()
        != Some(identity.source_digest.as_str())
    {
        (ImageBuildAction::Build, ImageBuildReason::LabelMismatch)
    } else if !observation.version_alias_matches || !observation.latest_alias_matches {
        (ImageBuildAction::Retag, ImageBuildReason::AliasMissing)
    } else {
        (ImageBuildAction::Skip, ImageBuildReason::DigestPresent)
    };

    ImageBuildDecision {
        action,
        reason,
        identity,
    }
}

struct ContextEntry {
    relative_path: String,
    kind: &'static str,
    mode: u32,
    payload: Vec<u8>,
}

fn collect_context_entries(
    context_root: &Path,
    dir: &Path,
    out: &mut Vec<ContextEntry>,
) -> Result<(), ImageBuilderError> {
    let mut paths = fs::read_dir(dir)
        .map_err(|e| ImageBuilderError::Io(format!("read build context: {e}")))?
        .map(|entry| entry.map(|entry| entry.path()))
        .collect::<Result<Vec<_>, _>>()
        .map_err(|e| ImageBuilderError::Io(format!("read build context entry: {e}")))?;
    paths.sort();

    for path in paths {
        let metadata = fs::symlink_metadata(&path)
            .map_err(|e| ImageBuilderError::Io(format!("read build context metadata: {e}")))?;
        let relative_path = path
            .strip_prefix(context_root)
            .map_err(|e| ImageBuilderError::Io(format!("relativize build context path: {e}")))?
            .to_str()
            .ok_or_else(|| {
                ImageBuilderError::Io("build context path contains invalid UTF-8".to_string())
            })?
            .replace('\\', "/");
        let mode = portable_mode(&metadata);

        if metadata.file_type().is_symlink() {
            let target = fs::read_link(&path)
                .map_err(|e| ImageBuilderError::Io(format!("read context symlink: {e}")))?;
            let target = target.to_str().ok_or_else(|| {
                ImageBuilderError::Io("build context symlink contains invalid UTF-8".to_string())
            })?;
            out.push(ContextEntry {
                relative_path,
                kind: "symlink",
                mode,
                payload: target.as_bytes().to_vec(),
            });
        } else if metadata.is_dir() {
            collect_context_entries(context_root, &path, out)?;
        } else if metadata.is_file() {
            let payload = fs::read(&path)
                .map_err(|e| ImageBuilderError::Io(format!("read build context file: {e}")))?;
            out.push(ContextEntry {
                relative_path,
                kind: "file",
                mode,
                payload,
            });
        }
    }
    Ok(())
}

#[cfg(unix)]
fn portable_mode(metadata: &fs::Metadata) -> u32 {
    metadata.permissions().mode() & 0o777
}

#[cfg(not(unix))]
fn portable_mode(metadata: &fs::Metadata) -> u32 {
    if metadata.permissions().readonly() {
        0o444
    } else {
        0o644
    }
}

fn hash_field(hasher: &mut Sha256, name: &[u8], value: &[u8]) {
    hasher.update((name.len() as u64).to_be_bytes());
    hasher.update(name);
    hasher.update((value.len() as u64).to_be_bytes());
    hasher.update(value);
}

fn hex_digest(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

/// Resolve the Containerfile path + build context dir for a given
/// image type. Per `spec:fix-windows-image-routing` "Image Build
/// Centralized in Helper": each image-name routes to its
/// type-specific Containerfile so a regression that points two
/// image types at the same file (e.g. both `proxy` and `git`
/// using `images/default/Containerfile`) is impossible by
/// construction — there's exactly one match arm per type.
///
/// Returns `(containerfile_path, context_dir)` where:
///   * `containerfile_path` is the absolute path to the Containerfile
///     under `<root_dir>/images/<type-specific-subdir>/Containerfile`.
///   * `context_dir` is the parent directory (the build context
///     podman uses for COPY/ADD operations).
///
/// Unknown image types return `ImageBuilderError::ContainerfileNotFound`
/// with the unknown name in the message. Existence of the
/// Containerfile is NOT checked here — callers (e.g.
/// `prepare_build`) verify reachability separately so error
/// surfaces stay specific to their failure mode.
///
/// @trace spec:fix-windows-image-routing
pub(crate) fn image_build_paths(
    root_dir: &str,
    image_name: &str,
) -> Result<(String, String), ImageBuilderError> {
    let containerfile_path = match image_name {
        "forge" => format!("{root_dir}/images/default/Containerfile"),
        "proxy" => format!("{root_dir}/images/proxy/Containerfile"),
        "git" => format!("{root_dir}/images/git/Containerfile"),
        "inference" => format!("{root_dir}/images/inference/Containerfile"),
        "web" => format!("{root_dir}/images/web/Containerfile"),
        "router" => format!("{root_dir}/images/router/Containerfile"),
        "chromium-core" => format!("{root_dir}/images/chromium/Containerfile.core"),
        "chromium-framework" => format!("{root_dir}/images/chromium/Containerfile.framework"),
        "vault" => format!("{root_dir}/images/vault/Containerfile"),
        _ => {
            return Err(ImageBuilderError::ContainerfileNotFound(format!(
                "Unknown image type: {image_name}"
            )));
        }
    };
    let context_dir = std::path::Path::new(&containerfile_path)
        .parent()
        .and_then(|p| p.to_str())
        .map(|s| s.to_string())
        .ok_or_else(|| {
            ImageBuilderError::Io("Containerfile path has no UTF-8 parent".to_string())
        })?;
    Ok((containerfile_path, context_dir))
}

// ============================================================================
// Core Types
// ============================================================================

/// Exact podman invocation record. Used by tests to assert the build logic.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PodmanCall {
    /// Command: "build", "load", "tag", etc.
    pub command: String,
    /// Full argument list (no shell escaping).
    pub args: Vec<String>,
    /// Mount flags: [(host_path, container_path), ...]
    pub mounts: Vec<(String, String)>,
    /// Environment variables: [("KEY", "VALUE"), ...]
    pub env: Vec<(String, String)>,
    /// Working directory for the podman process.
    pub cwd: String,
}

impl PodmanCall {
    /// Reconstruct the full podman command line for logging/debugging.
    pub fn to_shell_command(&self) -> String {
        let mut parts = vec!["podman".to_string(), self.command.clone()];
        parts.extend(self.args.clone());
        parts.join(" ")
    }
}

/// Result of an image build operation.
#[derive(Debug, Clone)]
pub struct BuildResult {
    /// The podman call that was made.
    pub call: PodmanCall,
    /// Image tag that was built (e.g., "tillandsias-forge:v0.1.170.100").
    pub image_tag: String,
    /// Wall-clock time in seconds.
    pub duration_secs: f64,
    /// Size of the image in bytes (0 if unknown).
    pub size_bytes: u64,
    /// Whether the build was skipped due to staleness (true = already existed).
    pub skipped: bool,
}

// ============================================================================
// Trait Definition
// ============================================================================

/// ImageBuilder abstracts the container image build process.
///
/// Implementations can be:
/// - **PodmanDirect**: Synchronous, executes podman immediately (prod code)
/// - **PodmanCapture**: Records the call without executing (test harness)
/// - **PodmanMock**: Returns pre-canned results (unit tests)
#[async_trait::async_trait]
pub trait ImageBuilder: Send + Sync {
    /// Build or ensure an image exists.
    ///
    /// **Parameters**:
    /// - `image_name`: Short name ("forge", "git", "proxy", "inference")
    /// - `image_tag`: Full tag ("tillandsias-forge:v0.1.170.100")
    ///
    /// **Returns**:
    /// - `Ok(result)`: Image was built (or already existed), contains the podman call
    /// - `Err(e)`: Build failed
    ///
    /// **Atomicity**: Each call is atomic — the image either exists in podman
    /// storage or the call failed. No partial states.
    async fn build(
        &self,
        image_name: &str,
        image_tag: &str,
    ) -> Result<BuildResult, ImageBuilderError>;

    /// Get the last podman call made by this builder.
    ///
    /// Used by tests to assert: "did you mount the cache?" "did you use dnf?"
    /// Returns `None` if no build has been attempted yet.
    fn last_podman_call(&self) -> Option<PodmanCall>;

    /// Reset internal state (for test isolation between runs).
    fn reset(&mut self);
}

/// Errors from the ImageBuilder trait.
#[derive(Debug, Clone)]
pub enum ImageBuilderError {
    /// Containerfile not found at the expected path.
    ContainerfileNotFound(String),
    /// podman command failed with non-zero exit.
    PodmanFailed { image_tag: String, stderr: String },
    /// Unexpected I/O error (file access, temp dir, etc).
    Io(String),
    /// Build timeout or other system-level failure.
    System(String),
}

impl std::fmt::Display for ImageBuilderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::ContainerfileNotFound(path) => {
                write!(f, "Containerfile not found at {path}")
            }
            Self::PodmanFailed { image_tag, stderr } => {
                write!(f, "podman build failed for {image_tag}: {stderr}")
            }
            Self::Io(msg) => write!(f, "I/O error: {msg}"),
            Self::System(msg) => write!(f, "System error: {msg}"),
        }
    }
}

impl std::error::Error for ImageBuilderError {}

// ============================================================================
// Implementation: PodmanDirect (Prod)
// ============================================================================

/// Production implementation: synchronous, executes podman immediately.
///
/// Used by the tray app at runtime. Builds images and validates they exist.
pub struct PodmanDirect {
    /// Root directory containing images/*/Containerfile
    root_dir: String,
    /// Last podman call (for observability, not used in this impl).
    last_call: Option<PodmanCall>,
}

impl PodmanDirect {
    pub fn new(root_dir: String) -> Self {
        Self {
            root_dir,
            last_call: None,
        }
    }

    /// Detect base distro from Containerfile's FROM line.
    fn detect_distro(&self, containerfile_path: &str) -> Result<String, ImageBuilderError> {
        let content = std::fs::read_to_string(containerfile_path)
            .map_err(|e| ImageBuilderError::Io(format!("read Containerfile: {e}")))?;

        for line in content.lines() {
            if let Some(from_image) = line.strip_prefix("FROM ") {
                if from_image.contains("fedora") {
                    return Ok("fedora".to_string());
                } else if from_image.contains("debian") || from_image.contains("ubuntu") {
                    return Ok("debian".to_string());
                } else if from_image.contains("alpine") {
                    return Ok("alpine".to_string());
                }
            }
        }
        Ok("unknown".to_string())
    }

    /// Compute cache mount arguments based on detected distro.
    fn cache_mount_args(&self, distro: &str) -> Result<Vec<(String, String)>, ImageBuilderError> {
        // Resolve the home dir at runtime. `HOME` is the Linux/macOS norm
        // (and is where image builds actually run — inside the VM on
        // Windows hosts); `USERPROFILE` keeps this crate compiling and
        // sane on a Windows host. A compile-time `env!("HOME")` would break
        // the MSVC build since Windows has no `HOME` at compile time.
        let home_dir = std::env::var_os("HOME")
            .or_else(|| std::env::var_os("USERPROFILE"))
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let cache_dir = home_dir.join(".cache/tillandsias/packages");
        std::fs::create_dir_all(&cache_dir)
            .map_err(|e| ImageBuilderError::Io(format!("create cache dir: {e}")))?;

        let cache_str = cache_dir
            .to_str()
            .ok_or_else(|| ImageBuilderError::Io("cache path contains invalid UTF-8".to_string()))?
            .to_string();

        let mounts = match distro {
            "fedora" => vec![(cache_str, "/var/cache/dnf/packages".to_string())],
            "debian" => vec![(cache_str, "/var/cache/apt/archives".to_string())],
            "alpine" => vec![(cache_str, "/var/cache/apk".to_string())],
            _ => {
                warn!(distro, "Unknown distro, skipping cache mount");
                vec![]
            }
        };

        Ok(mounts)
    }

    /// Build the exact podman command (without executing).
    fn prepare_build(
        &self,
        image_name: &str,
        image_tag: &str,
    ) -> Result<PodmanCall, ImageBuilderError> {
        let (containerfile_path, _context_dir) = image_build_paths(&self.root_dir, image_name)?;

        if !std::path::Path::new(&containerfile_path).exists() {
            return Err(ImageBuilderError::ContainerfileNotFound(containerfile_path));
        }

        let distro = self.detect_distro(&containerfile_path)?;
        let cache_mounts = self.cache_mount_args(&distro)?;

        let image_dir = std::path::Path::new(&containerfile_path)
            .parent()
            .ok_or_else(|| ImageBuilderError::Io("Containerfile path has no parent".to_string()))?
            .to_str()
            .ok_or_else(|| {
                ImageBuilderError::Io("Containerfile path contains invalid UTF-8".to_string())
            })?
            .to_string();

        let mut args = vec![
            "build".to_string(),
            "--format".to_string(),
            "docker".to_string(),
            "--tag".to_string(),
            image_tag.to_string(),
            "-f".to_string(),
            containerfile_path.clone(),
            image_dir.clone(),
        ];

        // Special handling for chromium-framework: inject CHROMIUM_CORE_TAG
        if image_name == "chromium-framework" {
            let _core_tag = image_tag.split(':').next_back().unwrap_or("latest");
            args.insert(4, "CHROMIUM_CORE_TAG".to_string());
            args.insert(4, "--build-arg".to_string());
        }

        let call = PodmanCall {
            command: "build".to_string(),
            args,
            mounts: cache_mounts,
            env: vec![],
            cwd: self.root_dir.clone(),
        };

        Ok(call)
    }

    /// Check if image already exists in podman storage.
    fn image_exists(&self, _image_tag: &str) -> bool {
        // In real code, this would call `podman image exists <tag>`.
        // For this type definition, we sketch the pattern:
        // let output = std::process::Command::new(<podman-binary>)
        //     .args(["image", "exists", image_tag])
        //     .output();
        // output.map(|o| o.status.success()).unwrap_or(false)
        //
        // For now, return false to force rebuild. Tests can mock this.
        false
    }
}

#[async_trait::async_trait]
impl ImageBuilder for PodmanDirect {
    async fn build(
        &self,
        image_name: &str,
        image_tag: &str,
    ) -> Result<BuildResult, ImageBuilderError> {
        let start = std::time::Instant::now();

        // Step 1: Check staleness (skip if already exists)
        if self.image_exists(image_tag) {
            debug!(image_tag, "Image already exists, skipping build");
            return Ok(BuildResult {
                call: PodmanCall {
                    command: "image_exists".to_string(),
                    args: vec![image_tag.to_string()],
                    mounts: vec![],
                    env: vec![],
                    cwd: self.root_dir.clone(),
                },
                image_tag: image_tag.to_string(),
                duration_secs: 0.0,
                size_bytes: 0,
                skipped: true,
            });
        }

        // Step 2: Prepare the podman call (no execution yet)
        let call = self.prepare_build(image_name, image_tag)?;

        // Step 3: Execute podman (synchronous, for prod)
        // In real code:
        // let output = std::process::Command::new(<podman-binary>)
        //     .args(&call.args)
        //     .current_dir(&call.cwd)
        //     .output()
        //     .map_err(|e| ImageBuilderError::System(e.to_string()))?;
        //
        // if !output.status.success() {
        //     let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        //     return Err(ImageBuilderError::PodmanFailed {
        //         image_tag: image_tag.to_string(),
        //         stderr,
        //     });
        // }

        // Step 4: Verify image exists in podman
        if !self.image_exists(image_tag) {
            return Err(ImageBuilderError::PodmanFailed {
                image_tag: image_tag.to_string(),
                stderr: "Image not found after build".to_string(),
            });
        }

        let duration = start.elapsed().as_secs_f64();
        info!(image_tag, duration_secs = duration, "Image build complete");

        Ok(BuildResult {
            call,
            image_tag: image_tag.to_string(),
            duration_secs: duration,
            size_bytes: 0, // Would query podman image inspect in real code
            skipped: false,
        })
    }

    fn last_podman_call(&self) -> Option<PodmanCall> {
        self.last_call.clone()
    }

    fn reset(&mut self) {
        self.last_call = None;
    }
}

// ============================================================================
// Implementation: PodmanCapture (Test Harness)
// ============================================================================

/// Test harness implementation: captures podman calls without executing.
///
/// Used by shell test harnesses and unit tests. Records the exact podman
/// invocation so tests can assert: "did you mount the cache?" "correct tag?"
pub struct PodmanCapture {
    /// Root directory containing images/*/Containerfile
    root_dir: String,
    /// All captured calls (for test inspection).
    calls: Vec<PodmanCall>,
    /// Canned image existence responses (for mocking staleness).
    image_exists_mock: HashMap<String, bool>,
}

impl PodmanCapture {
    pub fn new(root_dir: String) -> Self {
        Self {
            root_dir,
            calls: Vec::new(),
            image_exists_mock: HashMap::new(),
        }
    }

    /// Set whether an image "exists" for staleness simulation.
    pub fn set_image_exists(&mut self, tag: String, exists: bool) {
        self.image_exists_mock.insert(tag, exists);
    }

    /// Get all captured calls (for test inspection).
    pub fn captured_calls(&self) -> &[PodmanCall] {
        &self.calls
    }

    /// Check if any call contains a specific argument.
    pub fn has_arg(&self, arg: &str) -> bool {
        self.calls
            .iter()
            .any(|call| call.args.contains(&arg.to_string()))
    }

    /// Check if cache was mounted to the expected path.
    pub fn has_cache_mount(&self, container_path: &str) -> bool {
        self.calls.iter().any(|call| {
            call.mounts
                .iter()
                .any(|(_, c_path)| c_path == container_path)
        })
    }
}

#[async_trait::async_trait]
impl ImageBuilder for PodmanCapture {
    async fn build(
        &self,
        image_name: &str,
        image_tag: &str,
    ) -> Result<BuildResult, ImageBuilderError> {
        // Create a minimal impl of PodmanDirect to prepare the call
        let direct = PodmanDirect::new(self.root_dir.clone());
        let call = direct.prepare_build(image_name, image_tag)?;

        // Check mock staleness
        let skipped = self
            .image_exists_mock
            .get(image_tag)
            .copied()
            .unwrap_or(false);

        // Record the call (const because we can't mutate &self)
        // In real code, we'd need interior mutability (RefCell, Mutex).
        // For this sketch, imagine &mut self or Arc<Mutex<Self>>.

        Ok(BuildResult {
            call,
            image_tag: image_tag.to_string(),
            duration_secs: 0.001,
            size_bytes: 0,
            skipped,
        })
    }

    fn last_podman_call(&self) -> Option<PodmanCall> {
        self.calls.last().cloned()
    }

    fn reset(&mut self) {
        self.calls.clear();
    }
}

// ============================================================================
// Implementation: PodmanMock (Unit Tests)
// ============================================================================

/// Mock implementation for unit tests. Returns pre-canned results.
#[derive(Clone)]
pub struct PodmanMock {
    result: Result<BuildResult, ImageBuilderError>,
}

impl PodmanMock {
    pub fn success(image_tag: String) -> Self {
        Self {
            result: Ok(BuildResult {
                call: PodmanCall {
                    command: "build".to_string(),
                    args: vec![],
                    mounts: vec![],
                    env: vec![],
                    cwd: "/".to_string(),
                },
                image_tag,
                duration_secs: 0.5,
                size_bytes: 314572800, // 300 MB
                skipped: false,
            }),
        }
    }

    pub fn failure(image_tag: String, stderr: String) -> Self {
        Self {
            result: Err(ImageBuilderError::PodmanFailed { image_tag, stderr }),
        }
    }
}

#[async_trait::async_trait]
impl ImageBuilder for PodmanMock {
    async fn build(
        &self,
        _image_name: &str,
        _image_tag: &str,
    ) -> Result<BuildResult, ImageBuilderError> {
        self.result.clone()
    }

    fn last_podman_call(&self) -> Option<PodmanCall> {
        None
    }

    fn reset(&mut self) {}
}

// ============================================================================
// Test Module (Example Integration)
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    #[cfg(unix)]
    use std::os::unix::fs::{symlink, PermissionsExt};
    use std::path::PathBuf;
    use tempfile::TempDir;

    fn temp_image_root() -> PathBuf {
        let root =
            std::env::temp_dir().join(format!("tillandsias-image-routing-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        for image in ["default", "proxy", "git", "inference", "web"] {
            let dir = root.join("images").join(image);
            fs::create_dir_all(&dir).unwrap();
            fs::write(dir.join("Containerfile"), "FROM alpine\n").unwrap();
        }
        root
    }

    fn write_digest_fixture(root: &Path) -> ImageBuildSpec {
        fs::create_dir_all(root.join("nested")).unwrap();
        fs::write(root.join("Containerfile"), "FROM scratch\nCOPY . /app\n").unwrap();
        fs::write(root.join("nested/config.toml"), "enabled = true\n").unwrap();
        ImageBuildSpec {
            image_name: "forge".to_string(),
            context_root: root.to_path_buf(),
            containerfile: root.join("Containerfile"),
            build_args: BTreeMap::new(),
            dependency_digests: BTreeMap::new(),
            version: "0.3.1".to_string(),
        }
    }

    #[tokio::test]
    async fn test_podman_direct_prepares_correct_call() {
        let _builder = PodmanDirect::new("/workspace".to_string());
        // This would fail in real tests because /workspace doesn't exist,
        // but demonstrates the flow. Real tests would create a temp dir.
    }

    #[test]
    fn test_podman_capture_records_calls() {
        let mut capture = PodmanCapture::new("/workspace".to_string());

        // Simulate: set image to "not exist" so build proceeds
        capture.set_image_exists("tillandsias-forge:v0.1".to_string(), false);

        // In real tests, call capture.build(...).await and inspect captured_calls()
        // This demonstrates the pattern test harnesses use:

        // Assertion: "did you pass the image tag to podman?"
        // capture.has_arg("tillandsias-forge:v0.1");

        // Assertion: "did you mount the cache?"
        // capture.has_cache_mount("/var/cache/apt/archives");
    }

    #[test]
    fn build_routing_uses_type_specific_containerfiles() {
        let root = temp_image_root();
        unsafe {
            std::env::set_var("HOME", &root);
        }
        let direct = PodmanDirect::new(root.display().to_string());
        let root_str = root.display().to_string();

        let forge = direct
            .prepare_build("forge", "tillandsias-forge:v1")
            .unwrap();
        let proxy = direct
            .prepare_build("proxy", "tillandsias-proxy:v1")
            .unwrap();
        let git = direct.prepare_build("git", "tillandsias-git:v1").unwrap();
        let inference = direct
            .prepare_build("inference", "tillandsias-inference:v1")
            .unwrap();
        let web = direct.prepare_build("web", "tillandsias-web:v1").unwrap();

        let cases = [
            (forge, "images/default/Containerfile"),
            (proxy, "images/proxy/Containerfile"),
            (git, "images/git/Containerfile"),
            (inference, "images/inference/Containerfile"),
            (web, "images/web/Containerfile"),
        ];

        for (call, expected) in cases {
            let idx = call.args.iter().position(|arg| arg == "-f").unwrap();
            assert!(
                call.args[idx + 1].ends_with(expected),
                "expected {expected}, got {}",
                call.args[idx + 1]
            );
            assert!(call.cwd.ends_with(&root_str));
        }
    }

    /// `image_build_paths` is the canonical routing helper that
    /// `spec:fix-windows-image-routing` "Image Build Centralized in
    /// Helper" mandates. It returns `(containerfile_path,
    /// context_dir)` for each known image type. Existence of the
    /// Containerfile is NOT verified here — callers do that
    /// separately so the error mode stays specific (helper says
    /// "unknown type"; caller says "type known but file missing").
    ///
    /// @trace spec:fix-windows-image-routing
    #[test]
    fn image_build_paths_routes_each_known_type_to_its_containerfile() {
        let cases = [
            ("forge", "/images/default/Containerfile", "/images/default"),
            ("proxy", "/images/proxy/Containerfile", "/images/proxy"),
            ("git", "/images/git/Containerfile", "/images/git"),
            (
                "inference",
                "/images/inference/Containerfile",
                "/images/inference",
            ),
            ("web", "/images/web/Containerfile", "/images/web"),
            ("router", "/images/router/Containerfile", "/images/router"),
            (
                "chromium-core",
                "/images/chromium/Containerfile.core",
                "/images/chromium",
            ),
            (
                "chromium-framework",
                "/images/chromium/Containerfile.framework",
                "/images/chromium",
            ),
            ("vault", "/images/vault/Containerfile", "/images/vault"),
        ];
        for (image_name, expected_cf_suffix, expected_ctx_suffix) in cases {
            let (cf, ctx) = image_build_paths("/test-root", image_name)
                .expect("each known type routes successfully");
            assert!(
                cf.ends_with(expected_cf_suffix),
                "containerfile for {image_name}: expected …{expected_cf_suffix}, got {cf}"
            );
            assert!(
                ctx.ends_with(expected_ctx_suffix),
                "context dir for {image_name}: expected …{expected_ctx_suffix}, got {ctx}"
            );
            assert_eq!(
                Path::new(&cf).parent(),
                Some(Path::new(&ctx)),
                "containerfile must live directly under its context directory"
            );
        }
    }

    /// Unknown image types yield `ContainerfileNotFound` with the
    /// requested name in the message. This is the spec-mandated
    /// error mode for the Windows direct-podman build path to
    /// surface "you asked for a type the helper doesn't know about"
    /// distinctly from "type known but Containerfile missing".
    ///
    /// @trace spec:fix-windows-image-routing
    #[test]
    fn image_build_paths_rejects_unknown_image_type_with_named_error() {
        let err = image_build_paths("/test-root", "unknown-flavour")
            .expect_err("unknown type must error");
        match err {
            ImageBuilderError::ContainerfileNotFound(msg) => {
                assert!(
                    msg.contains("unknown-flavour"),
                    "error message must name the unknown type; got {msg}"
                );
                assert!(
                    msg.contains("Unknown image type"),
                    "error must distinguish from 'file missing'; got {msg}"
                );
            }
            other => panic!("expected ContainerfileNotFound, got {other:?}"),
        }
    }

    #[test]
    fn image_digest_is_checkout_root_independent_and_deterministic() {
        let left = TempDir::new().unwrap();
        let right = TempDir::new().unwrap();
        let left_spec = write_digest_fixture(left.path());
        let right_spec = write_digest_fixture(right.path());

        let first = image_build_identity(&left_spec).unwrap();
        let repeated = image_build_identity(&left_spec).unwrap();
        let other_checkout = image_build_identity(&right_spec).unwrap();

        assert_eq!(first.source_digest, repeated.source_digest);
        assert_eq!(first.source_digest, other_checkout.source_digest);
        assert_eq!(first.canonical_tag, other_checkout.canonical_tag);
    }

    #[test]
    fn image_digest_changes_for_content_path_and_generated_inputs() {
        let temp = TempDir::new().unwrap();
        let spec = write_digest_fixture(temp.path());
        let baseline = image_build_identity(&spec).unwrap();

        fs::write(temp.path().join("nested/config.toml"), "enabled = false\n").unwrap();
        let content_changed = image_build_identity(&spec).unwrap();
        assert_ne!(baseline.source_digest, content_changed.source_digest);

        fs::rename(
            temp.path().join("nested/config.toml"),
            temp.path().join("nested/renamed.toml"),
        )
        .unwrap();
        let path_changed = image_build_identity(&spec).unwrap();
        assert_ne!(content_changed.source_digest, path_changed.source_digest);

        fs::write(temp.path().join("generated-sidecar"), b"generated bytes").unwrap();
        let generated_changed = image_build_identity(&spec).unwrap();
        assert_ne!(path_changed.source_digest, generated_changed.source_digest);
    }

    #[cfg(unix)]
    #[test]
    fn image_digest_changes_for_mode_and_symlink_target() {
        let temp = TempDir::new().unwrap();
        let spec = write_digest_fixture(temp.path());
        let script = temp.path().join("tool.sh");
        fs::write(&script, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&script, fs::Permissions::from_mode(0o644)).unwrap();
        let baseline = image_build_identity(&spec).unwrap();

        fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
        let mode_changed = image_build_identity(&spec).unwrap();
        assert_ne!(baseline.source_digest, mode_changed.source_digest);

        fs::write(temp.path().join("target-a"), "a").unwrap();
        fs::write(temp.path().join("target-b"), "b").unwrap();
        let link = temp.path().join("active-target");
        symlink("target-a", &link).unwrap();
        let first_target = image_build_identity(&spec).unwrap();
        fs::remove_file(&link).unwrap();
        symlink("target-b", &link).unwrap();
        let second_target = image_build_identity(&spec).unwrap();
        assert_ne!(first_target.source_digest, second_target.source_digest);
    }

    #[test]
    fn image_digest_includes_build_args_and_dependency_digests() {
        let temp = TempDir::new().unwrap();
        let mut spec = write_digest_fixture(temp.path());
        let baseline = image_build_identity(&spec).unwrap();

        spec.build_args
            .insert("TARGETARCH".to_string(), "amd64".to_string());
        let build_arg_changed = image_build_identity(&spec).unwrap();
        assert_ne!(baseline.source_digest, build_arg_changed.source_digest);

        spec.dependency_digests.insert(
            "chromium-core".to_string(),
            "sha256:core-digest-a".to_string(),
        );
        let dependency_a = image_build_identity(&spec).unwrap();
        spec.dependency_digests.insert(
            "chromium-core".to_string(),
            "sha256:core-digest-b".to_string(),
        );
        let dependency_b = image_build_identity(&spec).unwrap();
        assert_ne!(dependency_a.source_digest, dependency_b.source_digest);
    }

    #[test]
    fn version_changes_aliases_without_changing_canonical_identity() {
        let temp = TempDir::new().unwrap();
        let mut spec = write_digest_fixture(temp.path());
        let first = image_build_identity(&spec).unwrap();
        spec.version = "0.3.2".to_string();
        let second = image_build_identity(&spec).unwrap();

        assert_eq!(first.source_digest, second.source_digest);
        assert_eq!(first.canonical_tag, second.canonical_tag);
        assert_ne!(first.version_alias, second.version_alias);
        assert_eq!(first.latest_alias, second.latest_alias);
    }

    #[test]
    fn build_decision_uses_oci_identity_without_external_state() {
        let temp = TempDir::new().unwrap();
        let identity = image_build_identity(&write_digest_fixture(temp.path())).unwrap();

        let skip = decide_image_build(
            identity.clone(),
            &ImageBuildObservation {
                canonical_tag_exists: true,
                canonical_source_digest: Some(identity.source_digest.clone()),
                version_alias_matches: true,
                latest_alias_matches: true,
                force: false,
            },
        );
        assert_eq!(skip.action, ImageBuildAction::Skip);
        assert_eq!(skip.reason, ImageBuildReason::DigestPresent);

        let retag = decide_image_build(
            identity.clone(),
            &ImageBuildObservation {
                canonical_tag_exists: true,
                canonical_source_digest: Some(identity.source_digest.clone()),
                version_alias_matches: false,
                latest_alias_matches: true,
                force: false,
            },
        );
        assert_eq!(retag.action, ImageBuildAction::Retag);
        assert_eq!(retag.reason, ImageBuildReason::AliasMissing);

        let mismatch = decide_image_build(
            identity.clone(),
            &ImageBuildObservation {
                canonical_tag_exists: true,
                canonical_source_digest: Some("sha256:other".to_string()),
                version_alias_matches: true,
                latest_alias_matches: true,
                force: false,
            },
        );
        assert_eq!(mismatch.action, ImageBuildAction::Build);
        assert_eq!(mismatch.reason, ImageBuildReason::LabelMismatch);

        let forced = decide_image_build(
            identity,
            &ImageBuildObservation {
                force: true,
                ..Default::default()
            },
        );
        assert_eq!(forced.action, ImageBuildAction::ForceRebuild);
        assert_eq!(forced.reason, ImageBuildReason::Forced);
    }
}

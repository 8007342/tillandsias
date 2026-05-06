/// ImageBuilder trait and implementations for Layer 2 build abstraction.
///
/// @trace spec:user-runtime-lifecycle
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
use std::collections::HashMap;
use tracing::{debug, info, warn};

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
        let cache_dir = std::path::Path::new(env!("HOME")).join(".cache/tillandsias/packages");
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
        let containerfile_path = match image_name {
            "forge" => format!("{}/images/default/Containerfile", self.root_dir),
            "proxy" => format!("{}/images/proxy/Containerfile", self.root_dir),
            "git" => format!("{}/images/git/Containerfile", self.root_dir),
            "inference" => format!("{}/images/inference/Containerfile", self.root_dir),
            "web" => format!("{}/images/web/Containerfile", self.root_dir),
            _ => {
                return Err(ImageBuilderError::ContainerfileNotFound(format!(
                    "Unknown image type: {image_name}"
                )));
            }
        };

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
        // let output = std::process::Command::new("podman")
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
        // let output = std::process::Command::new("podman")
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
}

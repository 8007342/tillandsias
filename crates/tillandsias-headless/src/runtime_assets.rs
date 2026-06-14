// @trace spec:user-runtime-lifecycle, spec:linux-native-portable-executable, spec:init-command
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use tillandsias_core::image_builder::{
    ImageBuildIdentity, ImageBuildSpec, image_build_identity as compute_image_build_identity,
};

#[derive(Clone, Copy, Debug)]
pub(crate) struct EmbeddedRuntimeAsset {
    pub(crate) path: &'static str,
    pub(crate) bytes: &'static [u8],
    pub(crate) executable: bool,
}

include!(concat!(env!("OUT_DIR"), "/runtime_assets_generated.rs"));

#[derive(Debug, Serialize, Deserialize)]
struct RuntimeAssetManifest {
    version: String,
    manifest_digest: String,
    #[serde(default)]
    materialized_at: String,
    file_count: usize,
    files: Vec<RuntimeAssetManifestFile>,
}

#[derive(Debug, Serialize, Deserialize)]
struct RuntimeAssetManifestFile {
    path: String,
    executable: bool,
    sha256: String,
}

pub(crate) fn runtime_data_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_DATA_HOME")
        && !xdg.trim().is_empty()
    {
        return PathBuf::from(xdg).join("tillandsias");
    }

    if let Ok(home) = std::env::var("HOME")
        && !home.trim().is_empty()
    {
        return PathBuf::from(home)
            .join(".local")
            .join("share")
            .join("tillandsias");
    }

    std::env::temp_dir().join("tillandsias-data")
}

pub(crate) fn runtime_asset_root(version: &str) -> PathBuf {
    runtime_data_dir().join("runtime").join(version)
}

pub(crate) fn ensure_runtime_assets(version: &str, debug: bool) -> Result<PathBuf, String> {
    let root = runtime_asset_root(version);
    if validate_runtime_assets(version, &root)? {
        if debug {
            eprintln!(
                "[tillandsias] runtime assets ready at {} ({})",
                root.display(),
                embedded_manifest_digest()
            );
        }
        return Ok(root);
    }

    materialize_runtime_assets(version, &root)?;
    if debug {
        eprintln!(
            "[tillandsias] materialized runtime assets at {} ({})",
            root.display(),
            embedded_manifest_digest()
        );
    }
    Ok(root)
}

pub(crate) fn validate_runtime_assets(version: &str, root: &Path) -> Result<bool, String> {
    let manifest_path = root.join("manifest.json");
    if !manifest_path.is_file() {
        return Ok(false);
    }

    let manifest_text = fs::read_to_string(&manifest_path)
        .map_err(|e| format!("Failed to read runtime asset manifest: {e}"))?;
    let manifest: RuntimeAssetManifest = match serde_json::from_str(&manifest_text) {
        Ok(manifest) => manifest,
        Err(_) => return Ok(false),
    };

    if manifest.version != version
        || manifest.manifest_digest != embedded_manifest_digest()
        || manifest.materialized_at.trim().is_empty()
        || manifest.file_count != EMBEDDED_RUNTIME_ASSETS.len()
    {
        return Ok(false);
    }

    for asset in EMBEDDED_RUNTIME_ASSETS {
        let path = root.join(asset.path);
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(_) => return Ok(false),
        };
        if bytes.as_slice() != asset.bytes {
            return Ok(false);
        }
        #[cfg(unix)]
        {
            let mode = fs::metadata(&path)
                .map_err(|e| format!("Failed to read runtime asset metadata: {e}"))?
                .permissions()
                .mode();
            if asset.executable && mode & 0o111 == 0 {
                return Ok(false);
            }
        }
    }

    Ok(true)
}

fn materialize_runtime_assets(version: &str, root: &Path) -> Result<(), String> {
    let parent = root
        .parent()
        .ok_or_else(|| "Runtime asset root has no parent".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|e| format!("Failed to create runtime asset parent: {e}"))?;

    let tmp = parent.join(format!(".{}.tmp-{}", version, std::process::id()));
    if tmp.exists() {
        fs::remove_dir_all(&tmp)
            .map_err(|e| format!("Failed to remove stale runtime asset temp dir: {e}"))?;
    }
    fs::create_dir_all(&tmp)
        .map_err(|e| format!("Failed to create runtime asset temp dir: {e}"))?;

    for asset in EMBEDDED_RUNTIME_ASSETS {
        write_asset(&tmp, asset)?;
    }

    let manifest = RuntimeAssetManifest {
        version: version.to_string(),
        manifest_digest: embedded_manifest_digest(),
        materialized_at: chrono::Utc::now().to_rfc3339(),
        file_count: EMBEDDED_RUNTIME_ASSETS.len(),
        files: EMBEDDED_RUNTIME_ASSETS
            .iter()
            .map(|asset| RuntimeAssetManifestFile {
                path: asset.path.to_string(),
                executable: asset.executable,
                sha256: sha256_hex(asset.bytes),
            })
            .collect(),
    };
    let manifest_json = serde_json::to_string_pretty(&manifest)
        .map_err(|e| format!("Failed to serialize runtime asset manifest: {e}"))?;
    fs::write(tmp.join("manifest.json"), manifest_json)
        .map_err(|e| format!("Failed to write runtime asset manifest: {e}"))?;

    if root.exists() {
        fs::remove_dir_all(root)
            .map_err(|e| format!("Failed to replace existing runtime asset dir: {e}"))?;
    }
    fs::rename(&tmp, root).map_err(|e| {
        let _ = fs::remove_dir_all(&tmp);
        format!("Failed to publish runtime asset dir: {e}")
    })?;

    Ok(())
}

fn write_asset(root: &Path, asset: &EmbeddedRuntimeAsset) -> Result<(), String> {
    let rel = Path::new(asset.path);
    if rel.components().any(|c| {
        matches!(
            c,
            std::path::Component::ParentDir | std::path::Component::RootDir
        )
    }) {
        return Err(format!(
            "Invalid embedded runtime asset path: {}",
            asset.path
        ));
    }

    let dest = root.join(rel);
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)
            .map_err(|e| format!("Failed to create runtime asset directory: {e}"))?;
    }
    fs::write(&dest, asset.bytes)
        .map_err(|e| format!("Failed to write runtime asset {}: {e}", asset.path))?;

    #[cfg(unix)]
    {
        let mode = if asset.executable { 0o755 } else { 0o644 };
        fs::set_permissions(&dest, fs::Permissions::from_mode(mode))
            .map_err(|e| format!("Failed to set runtime asset permissions: {e}"))?;
    }

    Ok(())
}

pub(crate) fn root_manifest_digest(root: &Path) -> Result<String, String> {
    let manifest_text = fs::read_to_string(root.join("manifest.json"))
        .map_err(|e| format!("Failed to read runtime asset manifest: {e}"))?;
    let manifest: RuntimeAssetManifest = serde_json::from_str(&manifest_text)
        .map_err(|e| format!("Failed to parse runtime asset manifest: {e}"))?;
    Ok(manifest.manifest_digest)
}

pub(crate) fn image_identity(
    root: &Path,
    image_name: &str,
    version: &str,
    build_args: BTreeMap<String, String>,
    dependency_digests: BTreeMap<String, String>,
) -> Result<ImageBuildIdentity, String> {
    let rel = image_context_rel(image_name)?;
    let context = root.join(rel);
    if !context.is_dir() {
        return Err(format!(
            "Runtime image context not found for {image_name}: {}",
            context.display()
        ));
    }

    let containerfile = match image_name {
        "forge-base" => context.join("Containerfile.base"),
        "chromium-core" => context.join("Containerfile.core"),
        "chromium-framework" => context.join("Containerfile.framework"),
        _ => context.join("Containerfile"),
    };
    let spec = ImageBuildSpec {
        image_name: image_name.to_string(),
        context_root: context,
        containerfile,
        build_args,
        dependency_digests,
        version: version.to_string(),
    };
    compute_image_build_identity(&spec).map_err(|e| e.to_string())
}

fn image_context_rel(image_name: &str) -> Result<&'static str, String> {
    match image_name {
        "forge-base" | "forge" => Ok("images/default"),
        "proxy" => Ok("images/proxy"),
        "git" => Ok("images/git"),
        "inference" => Ok("images/inference"),
        "web" => Ok("images/web"),
        "router" => Ok("images/router"),
        "chromium-core" | "chromium-framework" => Ok("images/chromium"),
        "vault" => Ok("images/vault"),
        other => Err(format!("Unknown image type: {other}")),
    }
}

pub(crate) fn embedded_manifest_digest() -> String {
    let mut hasher = Sha256::new();
    for asset in EMBEDDED_RUNTIME_ASSETS {
        hasher.update(asset.path.as_bytes());
        hasher.update([0]);
        hasher.update([u8::from(asset.executable)]);
        hasher.update([0]);
        hasher.update(asset.bytes);
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    hex_digest(&digest)
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let digest = hasher.finalize();
    hex_digest(&digest)
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> std::sync::MutexGuard<'static, ()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(())).lock().unwrap()
    }

    #[test]
    fn embedded_assets_include_required_runtime_contexts() {
        let paths = EMBEDDED_RUNTIME_ASSETS
            .iter()
            .map(|asset| asset.path)
            .collect::<std::collections::HashSet<_>>();

        for required in [
            "images/default/Containerfile.base",
            "images/default/Containerfile",
            "images/default/skills/advance-work-from-plan/SKILL.md",
            "images/proxy/allowlist.txt",
            "images/router/tillandsias-router-sidecar",
            "scripts/manage-cache.sh",
        ] {
            assert!(
                paths.contains(required),
                "missing embedded asset {required}"
            );
        }
    }

    #[test]
    fn every_containerfile_copy_source_exists_in_embedded_assets() {
        let embedded_paths = EMBEDDED_RUNTIME_ASSETS
            .iter()
            .map(|asset| asset.path)
            .collect::<std::collections::HashSet<_>>();

        // List of all containerfiles and their context directories
        let containerfiles = [
            ("images/default/Containerfile.base", "images/default"),
            ("images/default/Containerfile", "images/default"),
            ("images/proxy/Containerfile", "images/proxy"),
            ("images/git/Containerfile", "images/git"),
            ("images/inference/Containerfile", "images/inference"),
            ("images/web/Containerfile", "images/web"),
            ("images/router/Containerfile", "images/router"),
            ("images/chromium/Containerfile.core", "images/chromium"),
            ("images/chromium/Containerfile.framework", "images/chromium"),
            ("images/vault/Containerfile", "images/vault"),
        ];

        for (cf_rel_path, context_dir) in containerfiles {
            let cf_asset = EMBEDDED_RUNTIME_ASSETS
                .iter()
                .find(|asset| asset.path == cf_rel_path)
                .unwrap_or_else(|| panic!("Containerfile asset not embedded: {cf_rel_path}"));

            let cf_content = std::str::from_utf8(cf_asset.bytes)
                .unwrap_or_else(|e| panic!("Containerfile {cf_rel_path} is not valid UTF-8: {e}"));

            for line in cf_content.lines() {
                let trimmed = line.trim();
                if trimmed.starts_with("COPY ") {
                    let tokens = trimmed.split_whitespace().skip(1);
                    let mut sources = Vec::new();
                    let mut dest = None;

                    for token in tokens {
                        if token.starts_with("--") {
                            continue;
                        }
                        if let Some(d) = dest {
                            sources.push(d);
                        }
                        dest = Some(token);
                    }

                    assert!(!sources.is_empty(), "No sources found in COPY line: {line}");

                    for src in sources {
                        let clean_src = src.trim_matches(|c| c == '"' || c == '\'' || c == '/');
                        let expected_prefix = if clean_src.is_empty() {
                            format!("{context_dir}/")
                        } else {
                            format!("{context_dir}/{clean_src}")
                        };

                        let found = embedded_paths.iter().any(|path| {
                            if path == &expected_prefix {
                                true
                            } else {
                                path.starts_with(&format!("{expected_prefix}/"))
                            }
                        });

                        assert!(
                            found,
                            "Containerfile {cf_rel_path} COPY source {src} (resolved as {expected_prefix}) not found in embedded assets"
                        );
                    }
                }
            }
        }
    }

    #[test]
    fn materialized_assets_repair_corruption() {
        let _guard = env_lock();
        let temp = tempfile::tempdir().expect("tempdir");
        let old_xdg = std::env::var_os("XDG_DATA_HOME");
        unsafe {
            std::env::set_var("XDG_DATA_HOME", temp.path());
        }

        let root = ensure_runtime_assets("test-version", false).expect("materialize");
        let asset = root.join("images/proxy/allowlist.txt");
        fs::write(&asset, "corrupt").expect("corrupt asset");
        assert!(!validate_runtime_assets("test-version", &root).expect("validate"));
        let repaired = ensure_runtime_assets("test-version", false).expect("repair");
        assert!(validate_runtime_assets("test-version", &repaired).expect("validate repaired"));

        unsafe {
            if let Some(value) = old_xdg {
                std::env::set_var("XDG_DATA_HOME", value);
            } else {
                std::env::remove_var("XDG_DATA_HOME");
            }
        }
    }
}

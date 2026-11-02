//! Imagegen model files: fetched on first use into the reusable cache by
//! pinned URL and sha256 (order 1874-h9ns).
//!
//! @trace order:1874-h9ns (spec: openspec/changes/local-image-generation, not yet archived)
//!
//! The pins live in `images/imagegen/models.tsv` (declarative, one row per
//! file, revision + sha256 + size + licence). This module:
//!
//! - resolves the cache dir, `cache_root()/models/imagegen/<tier>/`, and
//!   REFUSES it when it sits on tmpfs or ramfs (design: models never on a
//!   ramdisk; a 7 GB tier on tmpfs is 7 GB of RAM the forge then loses);
//! - holds a per-file flock while it fetches, so two lanes asking for the
//!   same tier download it once;
//! - downloads through a [`Transport`] into `<file>.part`, hashes it on the
//!   HOST, and keeps it only when the digest equals the pin. A mismatch
//!   deletes the part and fails naming the model. Nothing half-verified is
//!   ever left under the final name;
//! - writes a `<file>.sha256` sidecar after a verified fetch, so a later call
//!   checks size + sidecar instead of re-hashing gigabytes every request.
//!
//! The production transport ([`ProxyTransport`]) runs curl in a one-shot
//! container on the enclave network with the canonical proxy env: the HOST
//! never opens a connection of its own, so every byte passes the squid
//! allowlist (spec:proxy-container). Progress comes from curl's own meter,
//! read as a stream, never from polling the file.
#![cfg_attr(not(test), allow(dead_code))]

use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

const MODELS_TSV: &str = include_str!("../../../images/imagegen/models.tsv");
/// The one media licence register (1921-h4gv). A file is fetched only when
/// the register carries its exact repo, revision, file and sha256, ungated
/// and under an allowed licence.
const REGISTER_TSV: &str = include_str!("../../../images/models/licence-register.tsv");

/// The shipped register (1954-gdi6: image.generate gates ControlNet and LoRA files on it).
pub fn register_tsv() -> &'static str {
    REGISTER_TSV
}

/// Refuse `row` unless `register` carries it exactly (repo, revision, file,
/// sha256), `gated` false and an allowed spdx.
pub fn register_admits(register: &str, row: &ModelFile) -> Result<(), String> {
    for line in register.lines() {
        if line.starts_with('#') || line.trim().is_empty() {
            continue;
        }
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() < 7 {
            continue;
        }
        if c[1] == row.repo
            && c[2] == row.revision
            && c[3] == row.file
            && c[4].eq_ignore_ascii_case(&row.sha256)
        {
            if c[6] != "false" {
                return Err(format!("model_refused: {} is gated", row.label()));
            }
            if !crate::imagegen_tiers::PERMISSIVE_LICENCES.contains(&c[5]) {
                return Err(format!("model_refused: {} licence {}", row.label(), c[5]));
            }
            return Ok(());
        }
    }
    Err(format!(
        "model_refused: {} at {} is not in images/models/licence-register.tsv",
        row.label(),
        row.revision
    ))
}

/// Only these formats are ever fetched: a pickle checkpoint executes code on load.
const ALLOWED_SUFFIXES: &[&str] = &[".safetensors", ".gguf"];

/// One pinned file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelFile {
    pub tier: String,
    pub role: String,
    pub repo: String,
    pub revision: String,
    pub file: String,
    pub sha256: String,
    pub bytes: u64,
    pub licence: String,
}

impl ModelFile {
    /// 1954-gdi6: a ControlNet (`controlnet:<name>`) or LoRA (`lora`) row;
    /// 1956-bh6j: or a studio-only weight (`studio:<kind>`: ipadapter,
    /// clip_vision, layer_model, birefnet). Aux rows are never part of a tier
    /// download; they are fetched only when a request or workflow names them.
    pub fn is_aux(&self) -> bool {
        self.role == "lora"
            || self.role.starts_with("controlnet:")
            || self.role.starts_with("studio:")
    }

    /// The base tier an aux row pairs with: the first segment of its `tier`
    /// column (`I1/controlnet-openpose` pairs with I1).
    pub fn base_tier(&self) -> &str {
        self.tier.split('/').next().unwrap_or(&self.tier)
    }

    /// The pinned download URL: a commit, never a branch.
    pub fn url(&self) -> String {
        format!(
            "https://huggingface.co/{}/resolve/{}/{}",
            self.repo, self.revision, self.file
        )
    }

    /// The file's name in the cache dir (its basename in the repo).
    pub fn cache_name(&self) -> &str {
        self.file.rsplit('/').next().unwrap_or(&self.file)
    }

    /// `repo/file`, how a failure names the model.
    pub fn label(&self) -> String {
        format!("{}/{}", self.repo, self.file)
    }
}

pub fn parse_manifest(body: &str) -> Result<Vec<ModelFile>, String> {
    let mut rows = Vec::new();
    for (n, line) in body.lines().enumerate() {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let c: Vec<&str> = line.split('\t').collect();
        if c.len() != 8 {
            return Err(format!(
                "models.tsv line {}: {} columns, want 8",
                n + 1,
                c.len()
            ));
        }
        let row = ModelFile {
            tier: c[0].to_string(),
            role: c[1].to_string(),
            repo: c[2].to_string(),
            revision: c[3].to_string(),
            file: c[4].to_string(),
            sha256: c[5].to_ascii_lowercase(),
            bytes: c[6]
                .parse()
                .map_err(|e| format!("models.tsv line {}: bytes: {e}", n + 1))?,
            licence: c[7].to_string(),
        };
        if row.sha256.len() != 64 || !row.sha256.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!("models.tsv line {}: sha256 is not 64 hex", n + 1));
        }
        if row.revision.len() != 40 || !row.revision.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err(format!(
                "models.tsv line {}: revision must be a pinned 40-hex commit",
                n + 1
            ));
        }
        if !ALLOWED_SUFFIXES.iter().any(|s| row.file.ends_with(s)) {
            return Err(format!(
                "models.tsv line {}: {} is not .safetensors or .gguf",
                n + 1,
                row.file
            ));
        }
        if !crate::imagegen_tiers::PERMISSIVE_LICENCES.contains(&row.licence.as_str()) {
            return Err(format!(
                "models.tsv line {}: licence {} is not on the permissive list",
                n + 1,
                row.licence
            ));
        }
        rows.push(row);
    }
    Ok(rows)
}

/// The shipped manifest.
pub fn manifest() -> Vec<ModelFile> {
    parse_manifest(MODELS_TSV).expect("images/imagegen/models.tsv parses (fixture-checked)")
}

/// The files tier `tier` needs. Empty when the tier has no pinned files yet.
/// ControlNet and LoRA rows (1954-gdi6) are fetched only when a request names them.
pub fn files_for_tier(manifest: &[ModelFile], tier: &str) -> Vec<ModelFile> {
    manifest
        .iter()
        .filter(|m| m.tier == tier && !m.is_aux())
        .cloned()
        .collect()
}

/// `cache_root()/models/imagegen`, from an explicit cache root (testable).
pub fn models_dir_under(cache_root: &Path) -> PathBuf {
    cache_root.join("models").join("imagegen")
}

/// `cache_root()/models/imagegen`.
pub fn models_dir() -> PathBuf {
    models_dir_under(&tillandsias_core::cache_root::cache_root())
}

/// True when `path` (or its nearest existing ancestor) is on tmpfs or ramfs.
pub fn is_volatile(path: &Path) -> bool {
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::ffi::OsStrExt;
        const TMPFS_MAGIC: i64 = 0x0102_1994;
        const RAMFS_MAGIC: i64 = 0x8584_58f6;
        let mut probe = path.to_path_buf();
        while !probe.exists() {
            if !probe.pop() {
                return false;
            }
        }
        let Ok(c) = std::ffi::CString::new(probe.as_os_str().as_bytes()) else {
            return false;
        };
        let mut st: libc::statfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statfs(c.as_ptr(), &mut st) } != 0 {
            return false;
        }
        let kind = st.f_type as i64;
        kind == TMPFS_MAGIC || kind == RAMFS_MAGIC
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = path;
        false
    }
}

/// Progress of one fetch, as events.
#[derive(Debug, Clone, PartialEq)]
pub enum FetchEvent {
    /// A download started (the file was not cached).
    Started { model: String, bytes: u64 },
    /// Whole percent of the current file.
    Percent { model: String, percent: u8 },
    /// The file is verified and kept.
    Verified { model: String },
}

/// Moves the bytes of one URL into `dest`. Implementations must NOT verify:
/// verification is the caller's, on the host, against the pin.
pub trait Transport {
    fn fetch(&self, url: &str, dest: &Path, on_percent: &mut dyn FnMut(u8)) -> Result<(), String>;
}

fn sha256_file(path: &Path) -> Result<String, String> {
    let mut f = fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f
            .read(&mut buf)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect())
}

/// An exclusive flock held for the guard's life.
struct FileLock {
    _held: fs::File,
}

impl FileLock {
    fn acquire(path: &Path) -> Result<Self, String> {
        let f = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(path)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        #[cfg(unix)]
        {
            use std::os::fd::AsRawFd;
            if unsafe { libc::flock(f.as_raw_fd(), libc::LOCK_EX) } != 0 {
                return Err(format!(
                    "{}: flock: {}",
                    path.display(),
                    std::io::Error::last_os_error()
                ));
            }
        }
        Ok(FileLock { _held: f })
    }
}

/// A cached file is usable when its size equals the pin AND its sidecar
/// names the pinned digest (written only after a verified fetch).
fn cached_and_verified(path: &Path, m: &ModelFile) -> bool {
    let size_ok = fs::metadata(path)
        .map(|md| md.len() == m.bytes)
        .unwrap_or(false);
    let sidecar = path.with_file_name(format!("{}.sha256", m.cache_name()));
    size_ok
        && fs::read_to_string(sidecar)
            .map(|s| s.trim() == m.sha256)
            .unwrap_or(false)
}

/// Ensure every file in `files` is present and verified under
/// `models_dir/<tier>/`. Returns `(role, path)` per file, in manifest order.
pub fn ensure_files(
    models_dir: &Path,
    files: &[ModelFile],
    transport: &dyn Transport,
    on_event: &mut dyn FnMut(FetchEvent),
) -> Result<Vec<(String, PathBuf)>, String> {
    ensure_files_registered(REGISTER_TSV, models_dir, files, transport, on_event)
}

/// [`ensure_files`] against an explicit register (fixtures).
pub fn ensure_files_registered(
    register: &str,
    models_dir: &Path,
    files: &[ModelFile],
    transport: &dyn Transport,
    on_event: &mut dyn FnMut(FetchEvent),
) -> Result<Vec<(String, PathBuf)>, String> {
    if is_volatile(models_dir) {
        return Err(format!(
            "model_cache_volatile: {} is on tmpfs or ramfs; imagegen models are never kept in RAM. \
             Point XDG_CACHE_HOME at a disk-backed directory.",
            models_dir.display()
        ));
    }
    for m in files {
        register_admits(register, m)?;
    }
    let mut out = Vec::new();
    for m in files {
        let dir = models_dir.join(&m.tier);
        fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        let final_path = dir.join(m.cache_name());
        let _lock = FileLock::acquire(&dir.join(format!(".{}.lock", m.cache_name())))?;
        if cached_and_verified(&final_path, m) {
            out.push((m.role.clone(), final_path));
            continue;
        }
        let part = dir.join(format!("{}.part", m.cache_name()));
        on_event(FetchEvent::Started {
            model: m.label(),
            bytes: m.bytes,
        });
        let label = m.label();
        let fetched = transport.fetch(&m.url(), &part, &mut |p| {
            on_event_percent(on_event, &label, p);
        });
        if let Err(e) = fetched {
            // A partial download is kept for curl's resume (-C -), never under
            // the final name; it is re-verified in full when it completes.
            return Err(format!("model_fetch_failed: {}: {e}", m.label()));
        }
        let digest = sha256_file(&part);
        let digest = match digest {
            Ok(d) => d,
            Err(e) => {
                let _ = fs::remove_file(&part);
                return Err(format!("model_fetch_failed: {}: {e}", m.label()));
            }
        };
        if digest != m.sha256 {
            let _ = fs::remove_file(&part);
            return Err(format!(
                "model_digest_mismatch: {} sha256 {digest} differs from the pin {}; the file was discarded",
                m.label(),
                m.sha256
            ));
        }
        fs::rename(&part, &final_path).map_err(|e| format!("{}: {e}", final_path.display()))?;
        let mut sidecar = fs::File::create(dir.join(format!("{}.sha256", m.cache_name())))
            .map_err(|e| format!("{}: {e}", dir.display()))?;
        let _ = writeln!(sidecar, "{}", m.sha256);
        on_event(FetchEvent::Verified { model: m.label() });
        out.push((m.role.clone(), final_path));
    }
    Ok(out)
}

fn on_event_percent(on_event: &mut dyn FnMut(FetchEvent), model: &str, percent: u8) {
    on_event(FetchEvent::Percent {
        model: model.to_string(),
        percent,
    });
}

/// curl's progress meter: `\r` separated rows whose first field is the whole
/// percent. The header rows start with `%` or a letter and are skipped.
pub fn meter_percent(row: &str) -> Option<u8> {
    let first = row.split_whitespace().next()?;
    let n: u8 = first.parse().ok()?;
    (n <= 100).then_some(n)
}

/// The production transport: curl in a one-shot container on the enclave
/// network with the canonical proxy env, writing into the bind-mounted dir.
pub struct ProxyTransport {
    /// An image with curl that is already on the host (the git mirror image,
    /// an init image).
    pub image: String,
}

impl ProxyTransport {
    pub fn for_this_build() -> Self {
        ProxyTransport {
            image: std::env::var("TILLANDSIAS_IMAGEGEN_FETCH_IMAGE")
                .ok()
                .filter(|s| !s.trim().is_empty())
                // launch-images-ok: image.generate is served only to a running forge, whose enclave already runs the git mirror from this image
                .unwrap_or_else(|| crate::versioned_image_tag("git", crate::VERSION.trim())),
        }
    }

    pub fn podman_args(&self, url: &str, dest: &Path) -> Vec<String> {
        let dir = dest.parent().unwrap_or(Path::new("."));
        let name = dest
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("download.part");
        let mut args: Vec<String> = vec![
            "run".into(),
            "--rm".into(),
            "--network".into(),
            crate::ENCLAVE_NET.into(),
            "--userns=keep-id".into(),
            "--cap-drop=ALL".into(),
            "--security-opt=no-new-privileges".into(),
            "--security-opt=label=disable".into(),
            "--memory=256m".into(),
            "--pids-limit=64".into(),
            "--mount".into(),
            format!("type=bind,source={},target=/dl", dir.display()),
            "--entrypoint".into(),
            "curl".into(),
        ];
        // Inserted before the image: the proxy env is the only route out.
        let mut with_env = crate::proxy_env_args();
        args.splice(args.len() - 2..args.len() - 2, with_env.drain(..));
        args.extend([
            self.image.clone(),
            "--fail".into(),
            "--location".into(),
            "--retry".into(),
            "3".into(),
            "--continue-at".into(),
            "-".into(),
            "--progress-meter".into(),
            "--output".into(),
            format!("/dl/{name}"),
            url.into(),
        ]);
        args
    }
}

impl Transport for ProxyTransport {
    fn fetch(&self, url: &str, dest: &Path, on_percent: &mut dyn FnMut(u8)) -> Result<(), String> {
        let mut last: Option<u8> = None;
        run_streamed(&self.podman_args(url, dest), &mut |row| {
            if let Some(p) = meter_percent(row)
                && last != Some(p)
            {
                last = Some(p);
                on_percent(p);
            }
        })
        .map_err(|e| format!("curl through the enclave proxy failed: {e}"))
    }
}

/// Run `podman <args>` to completion, handing every stderr AND stdout row
/// (split on `\r` or `\n`) to `on_row` as it arrives: progress is read from
/// the process's own stream, never by polling. The ONE caller-owned spawn of
/// the imagegen lane (fetch and generate share it); its lifetime is the
/// request's, ended by the process exiting.
pub fn run_streamed(args: &[String], on_row: &mut dyn FnMut(&str)) -> Result<(), String> {
    let mut cmd = crate::podman_command();
    cmd.args(args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = cmd
        .spawn_caller_owned_lifetime()
        .map_err(|e| format!("podman: {e}"))?;
    // stdout drains on its own thread so neither pipe can fill and block.
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    let mut readers = Vec::new();
    for pipe in [
        child
            .stdout
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
        child
            .stderr
            .take()
            .map(|p| Box::new(p) as Box<dyn Read + Send>),
    ]
    .into_iter()
    .flatten()
    {
        let tx = tx.clone();
        readers.push(std::thread::spawn(move || {
            let mut pipe = pipe;
            let mut buf = [0u8; 4096];
            let mut row = String::new();
            while let Ok(n) = pipe.read(&mut buf) {
                if n == 0 {
                    break;
                }
                for ch in String::from_utf8_lossy(&buf[..n]).chars() {
                    if ch == '\r' || ch == '\n' {
                        if !row.trim().is_empty() {
                            let _ = tx.send(std::mem::take(&mut row));
                        }
                        row.clear();
                    } else {
                        row.push(ch);
                    }
                }
            }
            if !row.trim().is_empty() {
                let _ = tx.send(row);
            }
        }));
    }
    drop(tx);
    let mut tail: Vec<String> = Vec::new();
    for row in rx {
        on_row(&row);
        tail.push(row);
        if tail.len() > 8 {
            tail.remove(0);
        }
    }
    for r in readers {
        let _ = r.join();
    }
    let status = child.wait().map_err(|e| format!("podman: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{status}: {}", tail.join(" | ")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A transport that writes fixed bytes, standing in for the network.
    struct Serve(Vec<u8>);
    impl Transport for Serve {
        fn fetch(&self, _url: &str, dest: &Path, on: &mut dyn FnMut(u8)) -> Result<(), String> {
            on(50);
            fs::write(dest, &self.0).map_err(|e| e.to_string())?;
            on(100);
            Ok(())
        }
    }

    /// A disk-backed scratch dir (the test binary's own target dir; /tmp is
    /// tmpfs on the fleet's Fedora hosts and is refused by design).
    fn disk_scratch(tag: &str) -> PathBuf {
        let exe = std::env::current_exe().expect("test exe");
        let dir = exe
            .parent()
            .expect("deps dir")
            .join(format!("imagegen-models-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).expect("scratch");
        dir
    }

    /// ensure_files against a register that carries exactly `files`.
    fn ensure_files_t(
        models: &Path,
        files: &[ModelFile],
        t: &dyn Transport,
        on: &mut dyn FnMut(FetchEvent),
    ) -> Result<Vec<(String, PathBuf)>, String> {
        let reg: String = files
            .iter()
            .map(|m| {
                format!(
                    "x\t{}\t{}\t{}\t{}\t{}\tfalse\tcard\n",
                    m.repo, m.revision, m.file, m.sha256, m.licence
                )
            })
            .collect();
        ensure_files_registered(&reg, models, files, t, on)
    }

    fn pin_for(bytes: &[u8]) -> ModelFile {
        let sha: String = Sha256::digest(bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect();
        ModelFile {
            tier: "I0".into(),
            role: "model".into(),
            repo: "example/model".into(),
            revision: "0".repeat(40),
            file: "m.safetensors".into(),
            sha256: sha,
            bytes: bytes.len() as u64,
            licence: "openrail++".into(),
        }
    }

    /// EXIT CRITERION (1874-h9ns): a served file whose sha256 differs from its
    /// pin is refused, nothing is left under the cache dir, and the resolved
    /// dir is cache_root()/models/imagegen and not tmpfs.
    #[test]
    fn a_digest_mismatched_model_is_refused_and_nothing_is_left() {
        let root = disk_scratch("mismatch");
        let models = models_dir_under(&root);
        assert!(models.ends_with("models/imagegen"), "{}", models.display());
        assert!(
            !is_volatile(&models),
            "scratch must be disk-backed: {}",
            models.display()
        );

        let pin = pin_for(b"the pinned weights");
        let mut events = Vec::new();
        let err = ensure_files_t(
            &models,
            std::slice::from_ref(&pin),
            &Serve(b"tampered".to_vec()),
            &mut |e| events.push(e),
        )
        .expect_err("a mismatched digest must be refused");
        assert!(err.contains("model_digest_mismatch"), "{err}");
        assert!(
            err.contains("example/model/m.safetensors"),
            "names the model: {err}"
        );
        let left: Vec<_> = fs::read_dir(models.join("I0"))
            .unwrap()
            .flatten()
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| !n.starts_with('.'))
            .collect();
        assert!(left.is_empty(), "nothing but the lock may remain: {left:?}");

        // The same pin with the right bytes is kept, verified, and a second
        // call does not fetch again.
        let good = b"the pinned weights".to_vec();
        let got = ensure_files_t(
            &models,
            std::slice::from_ref(&pin),
            &Serve(good),
            &mut |_| {},
        )
        .unwrap();
        assert_eq!(fs::read(&got[0].1).unwrap(), b"the pinned weights");
        struct Refuse;
        impl Transport for Refuse {
            fn fetch(&self, _: &str, _: &Path, _: &mut dyn FnMut(u8)) -> Result<(), String> {
                Err("must not be called for a cached file".into())
            }
        }
        ensure_files_t(&models, std::slice::from_ref(&pin), &Refuse, &mut |_| {}).unwrap();
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn every_shipped_manifest_row_is_in_the_register_and_a_stranger_is_refused() {
        for row in manifest() {
            register_admits(REGISTER_TSV, &row).unwrap();
        }
        let err = register_admits(REGISTER_TSV, &pin_for(b"x")).unwrap_err();
        assert!(
            err.contains("not in images/models/licence-register.tsv"),
            "{err}"
        );
        let mut tampered = manifest()[0].clone();
        tampered.sha256 = "0".repeat(64);
        assert!(register_admits(REGISTER_TSV, &tampered).is_err());
    }

    #[test]
    fn the_shipped_cache_dir_is_under_cache_root_models_imagegen() {
        let d = models_dir();
        assert!(d.starts_with(tillandsias_core::cache_root::cache_root()));
        assert!(d.ends_with("models/imagegen"));
    }

    #[test]
    #[cfg(target_os = "linux")]
    fn a_tmpfs_models_dir_is_refused() {
        // /dev/shm is tmpfs on every Linux host.
        let shm = Path::new("/dev/shm/tillandsias-imagegen-models-test");
        assert!(is_volatile(shm));
        let err = ensure_files(shm, &[pin_for(b"x")], &Serve(b"x".to_vec()), &mut |_| {})
            .expect_err("tmpfs refused");
        assert!(err.contains("model_cache_volatile"), "{err}");
        assert!(!shm.exists(), "nothing created on tmpfs");
    }

    #[test]
    fn the_shipped_manifest_pins_i0_and_i1_and_every_row_is_safe() {
        let m = manifest();
        assert!(!files_for_tier(&m, "I0").is_empty());
        assert!(!files_for_tier(&m, "I1").is_empty());
        for row in &m {
            assert!(row.url().contains(&format!("/resolve/{}/", row.revision)));
        }
        // A pickle checkpoint and a branch revision are refused.
        let bad = "I0\tmodel\ta/b\t".to_string()
            + &"0".repeat(40)
            + "\tx.ckpt\t"
            + &"0".repeat(64)
            + "\t1\topenrail++";
        assert!(parse_manifest(&bad).is_err());
        let branch =
            "I0\tmodel\ta/b\tmain\tx.gguf\t".to_string() + &"0".repeat(64) + "\t1\topenrail++";
        assert!(parse_manifest(&branch).is_err());
        let nc = "I0\tmodel\ta/b\t".to_string()
            + &"0".repeat(40)
            + "\tx.gguf\t"
            + &"0".repeat(64)
            + "\t1\tcc-by-nc-4.0";
        assert!(parse_manifest(&nc).is_err());
    }

    #[test]
    fn studio_rows_are_aux_and_never_part_of_a_tier_download() {
        // 1956-bh6j: a studio:<kind> row pairs with its base tier but is not
        // fetched by the tier download; a plain model row is.
        let rev = "0".repeat(40);
        let sha = "0".repeat(64);
        let body = format!(
            "I1\tmodel\ta/b\t{rev}\tm.safetensors\t{sha}\t1\topenrail++\n\
             I1/ipadapter\tstudio:ipadapter\th94/IP-Adapter\t{rev}\tsdxl_models/ip.safetensors\t{sha}\t1\tapache-2.0\n\
             I1/controlnet-union\tcontrolnet:union\txinsir/u\t{rev}\tu.safetensors\t{sha}\t1\tapache-2.0\n\
             I1/lora\tlora\tn/p\t{rev}\tp.safetensors\t{sha}\t1\tcreativeml-openrail-m\n"
        );
        let m = parse_manifest(&body).unwrap();
        assert_eq!(m.len(), 4);
        assert!(!m[0].is_aux());
        for row in &m[1..] {
            assert!(row.is_aux(), "{} is aux", row.role);
            assert_eq!(row.base_tier(), "I1");
        }
        assert_eq!(m[1].cache_name(), "ip.safetensors");
        let i1 = files_for_tier(&m, "I1");
        assert_eq!(i1.len(), 1, "only the model row belongs to the I1 download");
        // The shipped manifest: every studio row is aux, under I1, and in the register.
        let shipped = manifest();
        let studio: Vec<_> = shipped
            .iter()
            .filter(|r| r.role.starts_with("studio:"))
            .collect();
        assert!(studio.len() >= 5, "the D4 studio weights are pinned");
        for row in studio {
            assert!(row.is_aux());
            assert_eq!(row.base_tier(), "I1");
            register_admits(REGISTER_TSV, row).unwrap();
        }
    }

    /// LIVE, opt-in: fetch tier `TILLANDSIAS_IMAGEGEN_LIVE_TIER` (default I0)
    /// into the real cache through the running enclave proxy.
    /// `cargo test -p tillandsias-headless --bin tillandsias live_fetch -- --ignored --nocapture`
    #[test]
    #[ignore = "live: downloads through the enclave proxy"]
    fn live_fetch_through_the_enclave_proxy() {
        let tier = std::env::var("TILLANDSIAS_IMAGEGEN_LIVE_TIER").unwrap_or_else(|_| "I0".into());
        let files = files_for_tier(&manifest(), &tier);
        let t0 = std::time::Instant::now();
        let got = ensure_files(
            &models_dir(),
            &files,
            &ProxyTransport::for_this_build(),
            &mut |e| {
                if !matches!(e, FetchEvent::Percent { percent, .. } if percent % 10 != 0) {
                    eprintln!("{e:?}");
                }
            },
        )
        .expect("live fetch");
        eprintln!("{tier}: {got:?} in {:.1} s", t0.elapsed().as_secs_f64());
    }

    #[test]
    fn curl_meter_rows_parse_to_percent() {
        assert_eq!(meter_percent("  % Total    % Received % Xferd"), None);
        assert_eq!(
            meter_percent(" 12 1280M   12  160M    0     0  50.1M      0  0:00:25"),
            Some(12)
        );
        assert_eq!(meter_percent("100 1280M  100 1280M"), Some(100));
    }

    #[test]
    fn the_proxy_transport_reaches_out_only_through_the_proxy() {
        let t = ProxyTransport {
            image: "img:tag".into(),
        };
        let a = t.podman_args(
            "https://huggingface.co/x",
            Path::new("/c/models/imagegen/I0/f.part"),
        );
        let joined = a.join(" ");
        assert!(joined.contains("--network tillandsias-enclave"), "{joined}");
        assert!(joined.contains("https_proxy=http://proxy:3128"), "{joined}");
        let img = a.iter().position(|s| s == "img:tag").unwrap();
        let env = a
            .iter()
            .position(|s| s.starts_with("https_proxy="))
            .unwrap();
        assert!(env < img, "proxy env is a podman flag, before the image");
        assert_eq!(a.last().unwrap(), "https://huggingface.co/x");
    }
}

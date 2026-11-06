//! 1118-fqfk slice 2b: CA private keys never rest on durable disk in the clear.
//!
//! A key keeps its path (`<ca dir>/intermediate.key`, `<state>/preview-ca/
//! preview-ca.key`, `<ca dir>/vault.key`), so every reader is unchanged, but the
//! path is a symlink into a 0700 tmpfs directory under `$XDG_RUNTIME_DIR`. The
//! bytes live there for the session. A CA key's durable copy is the OS keyring;
//! the Vault TLS leaf key has none and is minted again after a reboot.
//!
//! Launch calls [`materialize`] before its "is the key usable" check:
//! - a regular file at the path is legacy plaintext: it is deleted (operator
//!   ruling, 2026-10-19: "Credentials lost is a better outcome than
//!   unencrypted credentials"), and the caller's missing-key check re-mints;
//! - a dangling symlink (after a reboot) is refilled from the keyring, but only
//!   when the entry was sealed against the certificate now on disk; anything
//!   else leaves it dangling, and the caller re-mints.
//!
//! A mint writes its key at [`staging_path`] and publishes it with [`seal`].
//! Nothing is repaired: a key that cannot be refilled is thrown away and its CA
//! is minted again.
//!
//! The store is active only on a host whose runtime directory is tmpfs, in a
//! build with the keyring. Elsewhere (VM guests, a runtime dir on disk) every
//! call leaves the key where the mint put it; guests are 1118 slice 3.
//!
//! @trace spec:tillandsias-vault, plan 1118-fqfk
// Where the store can never be active (Windows, or a build without the vault
// feature) session() is always None, so the store's machinery is unreachable
// there by design, not dead.
#![cfg_attr(not(all(unix, feature = "vault")), allow(dead_code))]

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

/// The keyring entry prefix; the user is `ca-key:<file name>`.
const KEYRING_PREFIX: &str = "ca-key:";

/// Where keys live and how the keyring is reached, for one session.
struct Store {
    /// The 0700 tmpfs directory holding this session's key bytes.
    home: PathBuf,
    /// The keyring read: `Ok(Some)` an entry, `Ok(None)` no entry, `Err` the
    /// keyring could not answer (locked, no session bus, timed out). 2007-ckun:
    /// the two are not the same: only a proven absence lets the CA be minted.
    read: fn(&str) -> Result<Option<String>, String>,
    /// The keyring write.
    write: fn(&str, &str) -> Result<(), String>,
}

/// This session's store, or `None` when keys stay where the mint put them.
/// Never under `cargo test`: a test's CA must not reach the operator's keyring
/// or this session's key home (a first run sealed a test preview CA into the
/// real keyring). Tests build a [`Store`] over their own tmpfs and keyring.
fn session() -> Option<Store> {
    #[cfg(all(unix, feature = "vault", not(test)))]
    {
        if crate::vault_bootstrap::is_running_in_vm() {
            return None;
        }
        let home = crate::vault_bootstrap::runtime_dir_tillandsias().join("keys");
        Store::at(home, keyring_read, keyring_write)
    }
    #[cfg(not(all(unix, feature = "vault", not(test))))]
    {
        None
    }
}

/// What a launch found at a key path.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Materialized {
    /// The store is not active here; nothing was touched.
    Inactive,
    /// The link resolves to this session's key.
    Present,
    /// The link was dangling and the keyring refilled it.
    Refilled,
    /// Plaintext was deleted, or the key could not be refilled; the caller's
    /// missing-key check re-mints.
    Gone,
    /// 2007-ckun: the key is missing and the keyring could not be ASKED. The
    /// key may well exist there, so the caller must not mint: it keeps a
    /// valid certificate and refuses by name until the keyring answers.
    Unavailable,
}

/// Reconcile one key path before the caller asks whether its key is usable.
/// `keyring` is false for a key with no durable copy (the Vault TLS leaf).
pub(crate) fn materialize(persisted: &Path, cert: &Path, keyring: bool) -> Materialized {
    match session() {
        Some(store) => store.materialize(persisted, cert, keyring),
        None => at_rest::materialize(persisted),
    }
}

/// 1898-hyhf: where the tmpfs store is inactive (macOS and Windows hosts, a
/// runtime dir on disk, VM guests, every `cargo test`), a key still never
/// rests on disk in the clear. openssl writes it ENCRYPTED (PKCS#8, AES-256)
/// under a passphrase that is itself never on durable disk:
/// - the OS keyring (macOS Keychain, Secret Service) when it takes the entry,
///   so the CA survives a restart;
/// - else a 0600 file on a tmpfs runtime dir (a guest's /run), per boot;
/// - else this process's memory only, so the next process cannot decrypt the
///   key, deletes that ciphertext, and mints the CA again (an ephemeral CA:
///   a lost key beats an unencrypted one, operator ruling 2026-10-19).
///
/// Under cfg(test) it is always process memory: a test never reaches the
/// operator's keyring or runtime dir.
mod at_rest {
    use std::path::Path;
    use std::process::{Command, Stdio};
    use std::sync::Mutex;

    use super::Materialized;

    /// The env var each openssl child reads the passphrase from (`env:`), set
    /// on that child only, so it never appears in an argv.
    pub(crate) const PASS_ENV: &str = "TILLANDSIAS_KEY_PASS";

    #[cfg(all(unix, feature = "vault", not(test)))]
    const KEYRING_USER: &str = "ca-key-pass:at-rest";

    /// The at-rest passphrase, or `None` when it is UNAVAILABLE (2003-kypa).
    ///
    /// Unavailable means the durable store could not be read (a locked
    /// keyring, no session bus, a guest runtime dir that is not tmpfs), or a
    /// new passphrase could not be stored. Before 2003-kypa both fell back to
    /// a fresh random value cached for the whole process: that process could
    /// not decrypt the key at rest, `materialize` deleted it as "lost", and
    /// the CA was minted again under a running Vault. Now nothing is
    /// invented: a caller gets no passphrase, openssl fails closed, no key is
    /// written or deleted, and the next call asks the store again. Only a
    /// value that was read or stored is cached.
    pub(super) fn pass() -> Option<String> {
        #[cfg(test)]
        if let Some(lookup) = *TEST_LOOKUP.lock().unwrap_or_else(|p| p.into_inner()) {
            return pass_with(lookup, durable_store);
        }
        pass_with(durable_lookup, durable_store)
    }

    /// Test seam: a stub passphrase store in place of process memory.
    #[cfg(test)]
    pub(super) static TEST_LOOKUP: Mutex<Option<PassLookup>> = Mutex::new(None);

    static CACHE: Mutex<Option<String>> = Mutex::new(None);

    /// A passphrase store's read: `Ok(Some)` stored, `Ok(None)` no entry,
    /// `Err` unreadable.
    pub(super) type PassLookup = fn() -> Result<Option<String>, String>;

    /// The store answers `Ok(Some)` for a stored passphrase, `Ok(None)` for
    /// no entry yet (a first run, which creates one), `Err` when it could
    /// not be read.
    pub(super) fn pass_with(
        lookup: PassLookup,
        store: fn(&str) -> Result<(), String>,
    ) -> Option<String> {
        let mut cache = CACHE.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(v) = cache.as_ref() {
            return Some(v.clone());
        }
        let value = match lookup() {
            Ok(Some(v)) if !v.is_empty() => v,
            Ok(_) => {
                let v = fresh();
                if let Err(e) = store(&v) {
                    eprintln!(
                        "[tillandsias] warn:ca-key-pass-unavailable:store-failed: {e}; no CA \
                         key is written under a passphrase nobody keeps (2003-kypa)"
                    );
                    return None;
                }
                v
            }
            Err(e) => {
                eprintln!(
                    "[tillandsias] warn:ca-key-pass-unavailable:read-failed: {e}; the CA \
                     key at rest is left as it is and asked for again next time (2003-kypa)"
                );
                return None;
            }
        };
        *cache = Some(value.clone());
        Some(value)
    }

    #[cfg(test)]
    pub(super) fn reset_cache() {
        *CACHE.lock().unwrap_or_else(|p| p.into_inner()) = None;
    }

    fn fresh() -> String {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).expect("ca_key_store: host CSPRNG unavailable");
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }

    #[cfg(all(unix, feature = "vault", not(test)))]
    fn guest_pass_file() -> std::path::PathBuf {
        crate::vault_bootstrap::runtime_dir_tillandsias().join("ca-key-pass")
    }

    #[cfg(all(unix, feature = "vault", not(test)))]
    fn durable_lookup() -> Result<Option<String>, String> {
        if crate::vault_bootstrap::is_running_in_vm() {
            // A guest has no keyring; a pass file on its tmpfs runtime dir
            // lives exactly one boot.
            return match std::fs::read_to_string(guest_pass_file()) {
                Ok(v) => Ok(Some(v.trim().to_string()).filter(|v| !v.is_empty())),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(e) => Err(format!("guest pass file: {e}")),
            };
        }
        crate::vault_bootstrap::keyring_get_blocking(KEYRING_USER)
    }

    #[cfg(all(unix, feature = "vault", not(test)))]
    fn durable_store(value: &str) -> Result<(), String> {
        if crate::vault_bootstrap::is_running_in_vm() {
            use std::os::unix::fs::DirBuilderExt;
            let dir = crate::vault_bootstrap::runtime_dir_tillandsias();
            std::fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&dir)
                .map_err(|e| format!("guest runtime dir: {e}"))?;
            if !crate::vault_bootstrap::path_is_tmpfs(&dir) {
                return Err("guest runtime dir is not tmpfs".into());
            }
            return super::write_key(&guest_pass_file(), value.as_bytes());
        }
        super::keyring_write(KEYRING_USER, value)
    }

    /// No durable store in this build (or under test): process memory only,
    /// so the passphrase is minted once and kept for the process, as before.
    #[cfg(not(all(unix, feature = "vault", not(test))))]
    fn durable_lookup() -> Result<Option<String>, String> {
        Ok(None)
    }

    #[cfg(not(all(unix, feature = "vault", not(test))))]
    fn durable_store(_value: &str) -> Result<(), String> {
        Ok(())
    }

    pub(super) fn is_encrypted(bytes: &[u8]) -> bool {
        bytes
            .windows(b"ENCRYPTED PRIVATE KEY".len())
            .any(|w| w == b"ENCRYPTED PRIVATE KEY")
    }

    /// Decrypt `path` in memory: the PEM on stdout, never a file.
    pub(super) fn decrypt(path: &Path) -> Result<Vec<u8>, String> {
        let pass = pass().ok_or_else(|| {
            format!(
                "{}: unavailable:ca-key-pass: the passphrase store could not be read",
                path.display()
            )
        })?;
        let out = Command::new("openssl")
            .args(["pkey", "-passin", &format!("env:{PASS_ENV}"), "-in"])
            .arg(path)
            .env(PASS_ENV, pass)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
            .map_err(|e| format!("spawn openssl pkey for {}: {e}", path.display()))?;
        if !out.status.success() {
            return Err(format!(
                "{}: the key does not decrypt under this session's passphrase",
                path.display()
            ));
        }
        Ok(out.stdout)
    }

    /// An encrypted key this session cannot decrypt is ciphertext under a
    /// lost passphrase: it holds nothing recoverable, so it is removed and the
    /// caller's missing-key check mints again. A plaintext key at the path
    /// predates this fix and is left exactly as it is: the operator decides
    /// about existing files (1898-hyhf).
    pub(super) fn materialize(persisted: &Path) -> Materialized {
        let Ok(bytes) = std::fs::read(persisted) else {
            return Materialized::Inactive;
        };
        // 2003-kypa: with no passphrase there is no proof the key is lost, so
        // it is left exactly as it is; only a key that fails under the
        // passphrase this host keeps is ciphertext nobody can open.
        if is_encrypted(&bytes) && pass().is_some() && decrypt(persisted).is_err() {
            let _ = std::fs::remove_file(persisted);
            return Materialized::Gone;
        }
        Materialized::Inactive
    }
}

/// Whether a mint must encrypt its key (the tmpfs store is inactive).
fn encrypts_at_rest() -> bool {
    session().is_none()
}

/// openssl arguments for a mint's key output: `-nodes` when the key lands on
/// the tmpfs store, else an encrypted key under the at-rest passphrase. Pair
/// with [`pass_env`] on the same Command.
pub(crate) fn key_out_args() -> Vec<String> {
    if encrypts_at_rest() {
        vec!["-passout".into(), format!("env:{}", at_rest::PASS_ENV)]
    } else {
        vec!["-nodes".into()]
    }
}

/// openssl arguments for reading a CA key (`-CAkey`, `-key`). A plaintext key
/// ignores them. Pair with [`pass_env`].
pub(crate) fn key_in_args() -> Vec<String> {
    if encrypts_at_rest() {
        vec!["-passin".into(), format!("env:{}", at_rest::PASS_ENV)]
    } else {
        Vec::new()
    }
}

/// The passphrase env for an openssl child that takes [`key_out_args`] or
/// [`key_in_args`].
/// 2003-kypa: with the passphrase unavailable the variable is left UNSET, so
/// openssl's `env:` read fails and the child exits nonzero: a mint writes no
/// key and a read reports unknown. No plaintext fallback.
pub(crate) fn pass_env() -> Vec<(&'static str, String)> {
    if encrypts_at_rest() {
        at_rest::pass()
            .map(|p| vec![(at_rest::PASS_ENV, p)])
            .unwrap_or_default()
    } else {
        Vec::new()
    }
}

/// A key's PEM in memory, decrypted when it rests encrypted; any other file
/// is returned as it is.
pub(crate) fn read_key(path: &Path) -> Result<Vec<u8>, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?;
    if at_rest::is_encrypted(&bytes) {
        at_rest::decrypt(path)
    } else {
        Ok(bytes)
    }
}

/// Where a mint writes the key for `persisted` before [`seal`]: on tmpfs when
/// the store is active, else beside `persisted` as before.
pub(crate) fn staging_path(persisted: &Path, unique: &str) -> PathBuf {
    match session() {
        Some(store) => store.staging_path(persisted, unique),
        None => persisted.with_file_name(staged_name(persisted, unique)),
    }
}

/// Publish a freshly minted key from [`staging_path`]: into the key home, with
/// `persisted` pointing at it and a keyring copy sealed against `cert_bytes`
/// (the certificate published with it). A keyring that does not take the copy
/// is not an error: the key lives for this session, and its CA is minted again
/// after a reboot.
pub(crate) fn seal(
    staged: &Path,
    persisted: &Path,
    cert_bytes: &[u8],
    keyring: bool,
) -> Result<(), String> {
    match session() {
        Some(store) => store.seal(staged, persisted, cert_bytes, keyring),
        None => std::fs::rename(staged, persisted)
            .map_err(|e| format!("publish {}: {e}", persisted.display())),
    }
}

impl Store {
    /// A store at `home`, when `home` can be made a 0700 directory on tmpfs.
    #[cfg(unix)]
    // Its callers are the non-test vault build and the Linux-only tests, so a
    // test build anywhere else has none.
    #[cfg_attr(all(test, not(target_os = "linux")), allow(dead_code))]
    fn at(
        home: PathBuf,
        read: fn(&str) -> Result<Option<String>, String>,
        write: fn(&str, &str) -> Result<(), String>,
    ) -> Option<Self> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&home)
            .ok()?;
        std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).ok()?;
        is_tmpfs(&home).then_some(Self { home, read, write })
    }

    fn staging_path(&self, persisted: &Path, unique: &str) -> PathBuf {
        self.home.join(staged_name(persisted, unique))
    }

    fn materialize(&self, persisted: &Path, cert: &Path, keyring: bool) -> Materialized {
        let Ok(meta) = std::fs::symlink_metadata(persisted) else {
            return self.refill(persisted, cert, keyring);
        };
        if !meta.file_type().is_symlink() {
            // Legacy plaintext: thrown away, never imported.
            scrub(persisted);
            eprintln!(
                "[tillandsias] ok:ca-key-plaintext-removed:{}: a key in the clear on disk \
                 was deleted, and its CA is minted again (1118-fqfk)",
                file_name(persisted)
            );
            return Materialized::Gone;
        }
        if persisted.is_file() {
            return Materialized::Present;
        }
        self.refill(persisted, cert, keyring)
    }

    fn refill(&self, persisted: &Path, cert: &Path, keyring: bool) -> Materialized {
        if !keyring {
            return Materialized::Gone;
        }
        let Ok(cert_bytes) = std::fs::read(cert) else {
            return Materialized::Gone;
        };
        let entry = match (self.read)(&keyring_user(persisted)) {
            Ok(entry) => entry,
            Err(e) => {
                eprintln!(
                    "[tillandsias] warn:ca-key-unavailable:{}: the key is not on tmpfs and \
                     the keyring could not be read ({e}); the CA is kept, not minted again \
                     (2007-ckun)",
                    file_name(persisted)
                );
                return Materialized::Unavailable;
            }
        };
        let Some(pem) = entry.and_then(|entry| unseal_entry(&entry, &cert_bytes)) else {
            return Materialized::Gone;
        };
        let staged = self.staging_path(persisted, &format!("refill.{}", std::process::id()));
        match write_key(&staged, pem.as_bytes()).and_then(|()| self.publish(&staged, persisted)) {
            Ok(()) => Materialized::Refilled,
            Err(_) => {
                scrub(&staged);
                Materialized::Gone
            }
        }
    }

    fn seal(
        &self,
        staged: &Path,
        persisted: &Path,
        cert_bytes: &[u8],
        keyring: bool,
    ) -> Result<(), String> {
        if keyring {
            let pem = std::fs::read_to_string(staged)
                .map_err(|e| format!("read staged {}: {e}", staged.display()))?;
            if let Err(e) = (self.write)(&keyring_user(persisted), &seal_entry(&pem, cert_bytes)) {
                eprintln!(
                    "[tillandsias] note:ca-key-not-in-keyring:{}: {e}; the key lives on tmpfs \
                     for this session only, and its CA is minted again after a reboot",
                    file_name(persisted)
                );
            }
        }
        self.publish(staged, persisted)
    }

    /// Move `staged` into the key home and swap `persisted` to a symlink at
    /// it. The key moves first, so a reader of the old link never meets a
    /// missing target for longer than the link's rename.
    fn publish(&self, staged: &Path, persisted: &Path) -> Result<(), String> {
        let target = self.home.join(file_name(persisted));
        std::fs::rename(staged, &target)
            .map_err(|e| format!("publish {}: {e}", target.display()))?;
        #[cfg(unix)]
        {
            let link = persisted.with_file_name(format!(
                ".{}.link.{}",
                file_name(persisted),
                std::process::id()
            ));
            let _ = std::fs::remove_file(&link);
            std::os::unix::fs::symlink(&target, &link)
                .map_err(|e| format!("link {}: {e}", link.display()))?;
            std::fs::rename(&link, persisted)
                .map_err(|e| format!("publish link {}: {e}", persisted.display()))?;
        }
        Ok(())
    }
}

#[cfg(all(unix, feature = "vault"))]
#[cfg_attr(all(test, not(target_os = "linux")), allow(dead_code))]
fn is_tmpfs(path: &Path) -> bool {
    crate::vault_bootstrap::path_is_tmpfs(path)
}

/// Without the vault module there is no store, so nothing is ever tmpfs to it.
#[cfg(all(unix, not(feature = "vault")))]
#[cfg_attr(all(test, not(target_os = "linux")), allow(dead_code))]
fn is_tmpfs(_path: &Path) -> bool {
    false
}

fn file_name(path: &Path) -> &str {
    path.file_name()
        .and_then(|n| n.to_str())
        .expect("a key path ends in a UTF-8 file name")
}

/// ORDER 2007-ckun: remove staging files a dead process left: the mint's
/// `<name>.<pid>.<nanos>.tmp` and the refill's `<name>.refill.<pid>.tmp`,
/// beside `persisted` and in this session's key home. Each is a private key
/// (or its certificate) from a mint that started and never published. Only
/// these exact shapes are removed, and only when `<pid>` is not running, so a
/// mint in progress elsewhere keeps its files and nothing unrecognised is
/// touched. Returns the names removed, each logged ok:ca-staging-swept.
pub(crate) fn sweep_stale_staging(persisted: &Path) -> Vec<String> {
    let mut dirs: Vec<PathBuf> = persisted
        .parent()
        .map(Path::to_path_buf)
        .into_iter()
        .collect();
    if let Some(store) = session() {
        dirs.push(store.home.clone());
    }
    let alive = |pid: u32| Path::new(&format!("/proc/{pid}")).exists();
    sweep_in(&dirs, file_name(persisted), &alive)
}

fn sweep_in(dirs: &[PathBuf], name: &str, alive: &dyn Fn(u32) -> bool) -> Vec<String> {
    let mut swept = Vec::new();
    let prefixes = [name.to_string(), name.replace(".key", ".crt")];
    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };
        for e in entries.flatten() {
            let file = e.file_name().to_string_lossy().into_owned();
            let Some(pid) = prefixes.iter().find_map(|p| staged_pid(&file, p)) else {
                continue;
            };
            if pid == std::process::id() || alive(pid) {
                continue;
            }
            scrub(&e.path());
            eprintln!(
                "[tillandsias] ok:ca-staging-swept:{file}: left by pid {pid}, not running (2007-ckun)"
            );
            swept.push(file);
        }
    }
    swept
}

/// The pid in `<prefix>.<pid>.<digits>.tmp` or `<prefix>.refill.<pid>.tmp`.
fn staged_pid(file: &str, prefix: &str) -> Option<u32> {
    let rest = file
        .strip_prefix(prefix)?
        .strip_prefix('.')?
        .strip_suffix(".tmp")?;
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    match rest.split('.').collect::<Vec<_>>()[..] {
        ["refill", pid] if digits(pid) => pid.parse().ok(),
        [pid, nanos] if digits(pid) && digits(nanos) => pid.parse().ok(),
        _ => None,
    }
}

fn staged_name(persisted: &Path, unique: &str) -> String {
    format!("{}.{unique}.tmp", file_name(persisted))
}

#[cfg(unix)]
fn write_key(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let _ = std::fs::remove_file(path);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("create {}: {e}", path.display()))?;
    file.write_all(bytes)
        .map_err(|e| format!("write {}: {e}", path.display()))
}

#[cfg(not(unix))]
fn write_key(path: &Path, _bytes: &[u8]) -> Result<(), String> {
    Err(format!(
        "{}: the tmpfs key store needs unix",
        path.display()
    ))
}

/// Overwrite a regular file with zeros and remove it; a symlink is only removed.
fn scrub(path: &Path) {
    if let Ok(meta) = std::fs::symlink_metadata(path) {
        if meta.file_type().is_file() {
            let _ = std::fs::write(path, vec![0u8; meta.len() as usize]);
        }
        let _ = std::fs::remove_file(path);
    }
}

fn keyring_user(persisted: &Path) -> String {
    format!("{KEYRING_PREFIX}{}", file_name(persisted))
}

fn cert_fingerprint(cert_bytes: &[u8]) -> String {
    Sha256::digest(cert_bytes)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}

/// A keyring entry: the paired certificate's SHA-256, a newline, the PEM key.
fn seal_entry(pem: &str, cert_bytes: &[u8]) -> String {
    format!("sha256:{}\n{pem}", cert_fingerprint(cert_bytes))
}

/// The PEM key of an entry sealed against exactly `cert_bytes`; anything else
/// (another certificate, a malformed entry) is no key.
fn unseal_entry(entry: &str, cert_bytes: &[u8]) -> Option<String> {
    let (head, pem) = entry.split_once('\n')?;
    let fingerprint = head.strip_prefix("sha256:")?;
    (fingerprint == cert_fingerprint(cert_bytes) && pem.contains("PRIVATE KEY"))
        .then(|| pem.to_string())
}

/// 2007-ckun: a locked or unreachable keyring is an ERROR, never "no entry".
/// Before, both read as absent, the key was Gone and the CA was minted again
/// under a running Vault and proxy.
#[cfg(all(unix, feature = "vault", not(test)))]
fn keyring_read(user: &str) -> Result<Option<String>, String> {
    crate::vault_bootstrap::keyring_get_blocking(user)
}

#[cfg(all(unix, feature = "vault", not(test)))]
fn keyring_write(user: &str, value: &str) -> Result<(), String> {
    crate::vault_bootstrap::keychain_set_blocking(user, value)
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    use super::*;
    use std::sync::Mutex;

    const PEM: &str = "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----\n";

    /// The fake keyring, shared by the `fn` pointers a Store holds.
    static KEYRING: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());
    /// Tests share KEYRING, so they run one at a time.
    static SERIAL: Mutex<()> = Mutex::new(());

    fn fake_read(user: &str) -> Result<Option<String>, String> {
        let ring = KEYRING.lock().unwrap();
        Ok(ring.iter().find(|(u, _)| u == user).map(|(_, v)| v.clone()))
    }

    fn locked_read(_user: &str) -> Result<Option<String>, String> {
        Err("org.freedesktop.Secret.Error.IsLocked".into())
    }

    fn fake_write(user: &str, value: &str) -> Result<(), String> {
        let mut ring = KEYRING.lock().unwrap();
        ring.retain(|(u, _)| u != user);
        ring.push((user.to_string(), value.to_string()));
        Ok(())
    }

    fn refusing_write(user: &str, _value: &str) -> Result<(), String> {
        Err(format!("refused:keyring-unavailable:{user}"))
    }

    // 2003-kypa: a keyring that fails its first reads and then recovers.
    // While it fails, the passphrase is unavailable, the encrypted key is
    // neither decrypted nor deleted, and the dir is byte-identical; once it
    // recovers, the same key decrypts. Red before 2003-kypa: the failed read
    // became a fresh cached passphrase, decrypt failed, and materialize
    // deleted the key (Gone), so the CA was minted again.
    static FLAKY_READS: Mutex<u32> = Mutex::new(0);
    fn flaky_lookup() -> Result<Option<String>, String> {
        let mut n = FLAKY_READS.lock().unwrap();
        *n += 1;
        // Down for the three reads made while it is locked, then back.
        if *n <= 3 {
            Err("keyring locked".into())
        } else {
            Ok(Some("the-kept-passphrase".into()))
        }
    }

    #[test]
    fn a_failed_keyring_read_leaves_the_key_and_recovers_with_the_keyring() {
        let _serial = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        let dir = tempfile::tempdir().unwrap();
        let key = dir.path().join("intermediate.key");
        let made = std::process::Command::new("openssl")
            .args([
                "genpkey",
                "-algorithm",
                "EC",
                "-pkeyopt",
                "ec_paramgen_curve:P-256",
            ])
            .args(["-aes-256-cbc", "-pass", "env:KYPA_PASS", "-out"])
            .arg(&key)
            .env("KYPA_PASS", "the-kept-passphrase")
            .stderr(std::process::Stdio::null())
            .status()
            .unwrap();
        assert!(made.success());
        let before = std::fs::read(&key).unwrap();
        at_rest::reset_cache();
        *FLAKY_READS.lock().unwrap() = 0;
        *at_rest::TEST_LOOKUP.lock().unwrap() = Some(flaky_lookup);

        let unavailable = at_rest::materialize(&key);
        let env_while_down = pass_env_for_test();
        let decrypt_while_down = at_rest::decrypt(&key);
        let bytes_while_down = std::fs::read(&key).ok();
        let recovered = at_rest::decrypt(&key);

        *at_rest::TEST_LOOKUP.lock().unwrap() = None;
        at_rest::reset_cache();
        assert!(
            matches!(unavailable, Materialized::Inactive),
            "{unavailable:?}"
        );
        assert!(env_while_down.is_empty(), "no passphrase is invented");
        assert!(
            decrypt_while_down
                .unwrap_err()
                .contains("unavailable:ca-key-pass")
        );
        assert_eq!(
            bytes_while_down.as_deref(),
            Some(before.as_slice()),
            "the key changed"
        );
        assert!(
            String::from_utf8_lossy(&recovered.expect("decrypts once the keyring recovers"))
                .contains("PRIVATE KEY")
        );
        assert_eq!(std::fs::read(&key).unwrap(), before);
    }

    /// pass_env as an at-rest caller sees it, independent of the tmpfs store.
    fn pass_env_for_test() -> Vec<(&'static str, String)> {
        at_rest::pass()
            .map(|p| vec![(at_rest::PASS_ENV, p)])
            .unwrap_or_default()
    }

    // 2003-kypa: a first run with a working, empty keyring still creates a
    // passphrase and keeps it.
    fn empty_lookup() -> Result<Option<String>, String> {
        Ok(None)
    }
    fn refusing_store(_v: &str) -> Result<(), String> {
        Err("keyring write refused".into())
    }
    fn accepting_store(v: &str) -> Result<(), String> {
        fake_write("ca-key-pass:at-rest", v)
    }

    #[test]
    fn a_first_run_creates_and_stores_the_passphrase_and_a_failed_store_invents_none() {
        let _serial = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        KEYRING.lock().unwrap().clear();
        at_rest::reset_cache();
        assert_eq!(at_rest::pass_with(empty_lookup, refusing_store), None);
        let made = at_rest::pass_with(empty_lookup, accepting_store).expect("created");
        assert_eq!(
            fake_read("ca-key-pass:at-rest").unwrap().as_deref(),
            Some(made.as_str())
        );
        assert_eq!(
            at_rest::pass_with(empty_lookup, refusing_store),
            Some(made),
            "cached"
        );
        at_rest::reset_cache();
        KEYRING.lock().unwrap().clear();
    }

    /// (tmpfs home, durable state dir, store); /dev/shm is tmpfs on Linux.
    fn store(
        write: fn(&str, &str) -> Result<(), String>,
    ) -> (tempfile::TempDir, tempfile::TempDir, Store) {
        let shm = tempfile::tempdir_in("/dev/shm").expect("tmpfs scratch");
        let state = tempfile::tempdir().expect("state dir");
        let store = Store::at(shm.path().join("keys"), fake_read, write).expect("tmpfs store");
        (shm, state, store)
    }

    fn mint(store: &Store, state: &Path, cert: &[u8], keyring: bool) -> PathBuf {
        let (persisted, crt) = (
            state.join("intermediate.key"),
            state.join("intermediate.crt"),
        );
        let staged = store.staging_path(&persisted, "t");
        std::fs::write(&staged, PEM).unwrap();
        store.seal(&staged, &persisted, cert, keyring).unwrap();
        std::fs::write(&crt, cert).unwrap();
        persisted
    }

    #[test]
    fn a_minted_key_is_a_link_into_tmpfs_and_never_bytes_on_disk() {
        let _serial = SERIAL.lock().unwrap();
        KEYRING.lock().unwrap().clear();
        let (_shm, state, store) = store(fake_write);
        let persisted = mint(&store, state.path(), b"cert one", true);
        let meta = std::fs::symlink_metadata(&persisted).unwrap();
        assert!(
            meta.file_type().is_symlink(),
            "the durable path holds a link, not the key"
        );
        assert_eq!(
            std::fs::read_link(&persisted).unwrap(),
            store.home.join("intermediate.key")
        );
        assert_eq!(
            std::fs::read_to_string(&persisted).unwrap(),
            PEM,
            "readers see the key"
        );
        assert!(is_tmpfs(&std::fs::canonicalize(&persisted).unwrap()));
        let durable: Vec<_> = std::fs::read_dir(state.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
            .filter(|e| std::fs::read_to_string(e.path()).is_ok_and(|t| t.contains("PRIVATE KEY")))
            .collect();
        assert!(
            durable.is_empty(),
            "no private key bytes in the state dir: {durable:?}"
        );
        assert_eq!(
            store.materialize(&persisted, &state.path().join("intermediate.crt"), true),
            Materialized::Present
        );
    }

    #[test]
    fn after_a_reboot_the_keyring_refills_the_key_for_the_same_certificate_only() {
        let _serial = SERIAL.lock().unwrap();
        KEYRING.lock().unwrap().clear();
        let (_shm, state, store) = store(fake_write);
        let persisted = mint(&store, state.path(), b"cert one", true);
        let crt = state.path().join("intermediate.crt");
        // A reboot empties tmpfs; the link dangles.
        std::fs::remove_file(store.home.join("intermediate.key")).unwrap();
        assert!(!persisted.is_file());
        assert_eq!(
            store.materialize(&persisted, &crt, true),
            Materialized::Refilled
        );
        assert_eq!(std::fs::read_to_string(&persisted).unwrap(), PEM);
        // A certificate the entry was not sealed against gets no key.
        std::fs::remove_file(store.home.join("intermediate.key")).unwrap();
        std::fs::write(&crt, b"cert two").unwrap();
        assert_eq!(
            store.materialize(&persisted, &crt, true),
            Materialized::Gone
        );
        assert!(
            !persisted.is_file(),
            "the caller's missing-key check re-mints"
        );
    }

    #[test]
    fn legacy_plaintext_is_deleted_not_imported() {
        let _serial = SERIAL.lock().unwrap();
        KEYRING.lock().unwrap().clear();
        let (_shm, state, store) = store(fake_write);
        let persisted = state.path().join("intermediate.key");
        std::fs::write(&persisted, PEM).unwrap();
        std::fs::write(state.path().join("intermediate.crt"), b"cert").unwrap();
        assert_eq!(
            store.materialize(&persisted, &state.path().join("intermediate.crt"), true),
            Materialized::Gone
        );
        assert!(
            std::fs::symlink_metadata(&persisted).is_err(),
            "the plaintext is gone"
        );
        assert!(
            KEYRING.lock().unwrap().is_empty(),
            "and was never copied into the keyring"
        );
    }

    #[test]
    fn a_keyring_that_refuses_leaves_a_session_only_key_and_a_leaf_never_asks() {
        let _serial = SERIAL.lock().unwrap();
        KEYRING.lock().unwrap().clear();
        let (_shm, state, store) = store(refusing_write);
        let persisted = mint(&store, state.path(), b"cert", true);
        assert_eq!(
            std::fs::read_to_string(&persisted).unwrap(),
            PEM,
            "the session still has it"
        );
        std::fs::remove_file(store.home.join("intermediate.key")).unwrap();
        assert_eq!(
            store.materialize(&persisted, &state.path().join("intermediate.crt"), true),
            Materialized::Gone
        );
        // A key with no durable copy (the Vault TLS leaf) never touches the keyring.
        let (_shm2, state2, store2) = store_with_ring();
        let leaf = mint(&store2, state2.path(), b"leaf", false);
        assert!(KEYRING.lock().unwrap().is_empty());
        std::fs::remove_file(store2.home.join("intermediate.key")).unwrap();
        assert_eq!(
            store2.materialize(&leaf, &state2.path().join("intermediate.crt"), false),
            Materialized::Gone
        );
    }

    /// 2007-ckun: a dangling key with a LOCKED keyring is Unavailable, not
    /// Gone, so the caller keeps the CA instead of minting; a keyring that
    /// answers "no entry" is still Gone. Pre-fix: FAILS, both were Gone.
    #[test]
    fn a_locked_keyring_is_unavailable_not_a_missing_key() {
        let _serial = SERIAL.lock().unwrap_or_else(|p| p.into_inner());
        KEYRING.lock().unwrap().clear();
        let (_shm, state, store) = store(fake_write);
        let persisted = mint(&store, state.path(), b"cert", true);
        let crt = state.path().join("intermediate.crt");
        std::fs::remove_file(store.home.join("intermediate.key")).unwrap();
        let locked = Store {
            home: store.home.clone(),
            read: locked_read,
            write: fake_write,
        };
        assert_eq!(
            locked.materialize(&persisted, &crt, true),
            Materialized::Unavailable
        );
        assert!(
            std::fs::symlink_metadata(&persisted).is_ok(),
            "the link is left for the next call to refill"
        );
        // The keyring unlocks: the same link refills.
        assert_eq!(
            store.materialize(&persisted, &crt, true),
            Materialized::Refilled
        );
        // A keyring that answers with no entry is a proven absence.
        std::fs::remove_file(store.home.join("intermediate.key")).unwrap();
        KEYRING.lock().unwrap().clear();
        assert_eq!(
            store.materialize(&persisted, &crt, true),
            Materialized::Gone
        );
    }

    /// 2007-ckun: staging files of dead processes are swept, those of a live
    /// one (and this process) are kept, and nothing of another shape is
    /// touched. Pre-fix: FAILS, nothing swept them (five cleartext keys on
    /// macuahuitl, Nov 4-5).
    #[test]
    fn stale_ca_staging_is_swept_and_live_or_unknown_files_are_kept() {
        let dir = tempfile::tempdir_in("/dev/shm").unwrap();
        let me = std::process::id();
        let names = [
            "intermediate.key.2781247.1793822354424113489.tmp",
            "intermediate.crt.2781247.1793822354424113489.tmp",
            "intermediate.key.refill.95528.tmp",
            "intermediate.key.4242.1.tmp",
            &format!("intermediate.key.{me}.7.tmp"),
            "intermediate.key",
            "intermediate.key.119",
            "intermediate.key.abc.1.tmp",
            "vault.key.2781247.1.tmp",
        ]
        .map(String::from);
        for n in &names {
            std::fs::write(dir.path().join(n), b"x").unwrap();
        }
        let alive = |pid: u32| pid == 4242;
        let mut swept = sweep_in(&[dir.path().to_path_buf()], "intermediate.key", &alive);
        swept.sort();
        assert_eq!(
            swept,
            [
                "intermediate.crt.2781247.1793822354424113489.tmp",
                "intermediate.key.2781247.1793822354424113489.tmp",
                "intermediate.key.refill.95528.tmp",
            ]
        );
        for kept in [
            "intermediate.key.4242.1.tmp",
            &format!("intermediate.key.{me}.7.tmp"),
            "intermediate.key",
            "intermediate.key.119",
            "intermediate.key.abc.1.tmp",
            "vault.key.2781247.1.tmp",
        ] {
            assert!(dir.path().join(kept).exists(), "{kept} kept");
        }
    }

    fn store_with_ring() -> (tempfile::TempDir, tempfile::TempDir, Store) {
        store(fake_write)
    }

    #[test]
    fn an_entry_unseals_only_against_the_certificate_it_was_sealed_with() {
        let entry = seal_entry(PEM, b"cert one");
        assert_eq!(unseal_entry(&entry, b"cert one").as_deref(), Some(PEM));
        assert_eq!(unseal_entry(&entry, b"cert two"), None);
        assert_eq!(
            unseal_entry(PEM, b"cert one"),
            None,
            "an unsealed value is no key"
        );
        assert_eq!(unseal_entry(&seal_entry("not a key", b"c"), b"c"), None);
        assert_eq!(
            keyring_user(Path::new("/s/preview-ca/preview-ca.key")),
            "ca-key:preview-ca.key"
        );
    }
}

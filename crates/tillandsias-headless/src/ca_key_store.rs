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
    /// The keyring read: an entry's value, or `None` (absent or unreachable).
    read: fn(&str) -> Option<String>,
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
}

/// Reconcile one key path before the caller asks whether its key is usable.
/// `keyring` is false for a key with no durable copy (the Vault TLS leaf).
pub(crate) fn materialize(persisted: &Path, cert: &Path, keyring: bool) -> Materialized {
    match session() {
        Some(store) => store.materialize(persisted, cert, keyring),
        None => Materialized::Inactive,
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
    fn at(
        home: PathBuf,
        read: fn(&str) -> Option<String>,
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
        let Some(pem) = (self.read)(&keyring_user(persisted))
            .and_then(|entry| unseal_entry(&entry, &cert_bytes))
        else {
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
fn is_tmpfs(path: &Path) -> bool {
    crate::vault_bootstrap::path_is_tmpfs(path)
}

/// Without the vault module there is no store, so nothing is ever tmpfs to it.
#[cfg(all(unix, not(feature = "vault")))]
fn is_tmpfs(_path: &Path) -> bool {
    false
}

fn file_name(path: &Path) -> &str {
    path.file_name()
        .and_then(|n| n.to_str())
        .expect("a key path ends in a UTF-8 file name")
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

/// A locked or unreachable keyring answers like an absent entry: either way
/// there is no key to refill, and the CA is minted again.
#[cfg(all(unix, feature = "vault", not(test)))]
fn keyring_read(user: &str) -> Option<String> {
    crate::vault_bootstrap::keyring_get_blocking(user)
        .ok()
        .flatten()
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

    fn fake_read(user: &str) -> Option<String> {
        let ring = KEYRING.lock().unwrap();
        ring.iter().find(|(u, _)| u == user).map(|(_, v)| v.clone())
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

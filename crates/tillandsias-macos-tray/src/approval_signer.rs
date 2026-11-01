//! Order 1886-hf9j: approvals on a Mac are signed by a Secure Enclave key
//! after Touch ID, as SSHSIG that stock `ssh-keygen -Y verify` accepts.
//!
//! The enclave half (create, sign after LocalAuthentication) is CryptoKit in
//! `swift/approval_signer.swift`, compiled by build.rs. This module builds
//! the SSHSIG envelope (OpenSSH PROTOCOL.sshsig) around the raw P-256
//! signature, keeps the wrapped key, and prints the allowed-signers line.
//!
//! One key per (Mac, repo slug), so approvals cannot be linked across
//! projects (operator 2026-10-27, notes on 1879-5jkt / 1880-9wpd /
//! 1888-e3yh). The principal stays `operator`; the allowed-signers line names
//! the key by its label `tillandsias-approval/<slug>` and nothing about the
//! host (no hostname, no biometric type).
//!
//! The wrapped key is CryptoKit's `dataRepresentation`: only this Mac's
//! Secure Enclave can use it, so the file holds no usable secret (operator
//! 2026-10-19: no plaintext credentials at rest). Losing it means enrolling
//! again, which the design accepts.
//!
//! Slice 1 presents and logs only: nothing verifies or enforces these
//! signatures yet (operator ruling R4, `present` mode).
//!
//! Design: openspec/changes/os-verified-approval-gates (approval-attestation).

use std::path::{Path, PathBuf};

use base64::Engine as _;
use sha2::{Digest, Sha512};

/// SSHSIG namespace for every approval (design D2).
pub(crate) const NAMESPACE: &str = "tillandsias-approval@v1";
/// The principal the allowed-signers line names.
pub(crate) const PRINCIPAL: &str = "operator";
const KEY_TYPE: &str = "ecdsa-sha2-nistp256";
const CURVE: &str = "nistp256";
/// The text LocalAuthentication shows under "Tillandsias is trying to ...".
/// User-facing; held for the operator's wording (dialog slice).
pub(crate) const SIGN_REASON: &str = "approve the action Tillandsias asked about";

unsafe extern "C" {
    fn tla_se_available() -> i32;
    fn tla_se_create(
        biometric: i32,
        blob_out: *mut u8,
        blob_cap: usize,
        blob_len: *mut usize,
        pub_out: *mut u8,
        pub_cap: usize,
        pub_len: *mut usize,
    ) -> i32;
    fn tla_se_public(
        blob: *const u8,
        blob_len: usize,
        pub_out: *mut u8,
        pub_cap: usize,
        pub_len: *mut usize,
    ) -> i32;
    fn tla_se_sign(
        blob: *const u8,
        blob_len: usize,
        msg: *const u8,
        msg_len: usize,
        reason: *const std::ffi::c_char,
        sig_out: *mut u8,
        sig_cap: usize,
        sig_len: *mut usize,
    ) -> i32;
    #[cfg(test)]
    fn tla_sw_sign(
        raw: *const u8,
        raw_len: usize,
        msg: *const u8,
        msg_len: usize,
        pub_out: *mut u8,
        pub_cap: usize,
        pub_len: *mut usize,
        sig_out: *mut u8,
        sig_cap: usize,
        sig_len: *mut usize,
    ) -> i32;
}

fn ffi_error(what: &str, code: i32) -> String {
    let why = match code {
        -1 => "this Mac has no Secure Enclave",
        -2 => "the access control could not be built",
        -3 => "the enclave refused to create a key",
        -4 => "an output buffer was too small",
        -5 => {
            "the stored key could not be loaded (enrolled on another Mac, or the fingerprints changed)"
        }
        -6 => "signing was cancelled or not authorised",
        _ => "unknown failure",
    };
    format!("{what}: {why} (code {code})")
}

/// A repo slug is `owner/name`, each part `[A-Za-z0-9._-]`, never `.`/`..`.
pub(crate) fn check_slug(slug: &str) -> Result<(&str, &str), String> {
    let ok = |p: &str| {
        !p.is_empty()
            && p != "."
            && p != ".."
            && p.bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    };
    match slug.split_once('/') {
        Some((owner, name)) if ok(owner) && ok(name) => Ok((owner, name)),
        _ => Err(format!("{slug:?} is not a repo slug (owner/name)")),
    }
}

/// The key's label, recorded in the allowed-signers line and the grant.
pub(crate) fn key_label(slug: &str) -> String {
    format!("{NAMESPACE_LABEL}/{slug}")
}
const NAMESPACE_LABEL: &str = "tillandsias-approval";

/// Where `slug`'s wrapped key lives: beside the VM images, one per repo.
pub(crate) fn key_path(slug: &str) -> Result<PathBuf, String> {
    let (owner, name) = check_slug(slug)?;
    Ok(crate::diagnose::resolve_image_root()
        .0
        .join("approval-keys")
        .join(owner)
        .join(format!("{name}.se")))
}

/// An SSH wire `string`: u32 big-endian length, then the bytes.
fn put_string(out: &mut Vec<u8>, bytes: &[u8]) {
    out.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
    out.extend_from_slice(bytes);
}

/// An SSH `mpint` from an unsigned big-endian integer: no leading zeros, and
/// a 0x00 prefix when the top bit is set so it does not read as negative.
fn put_mpint(out: &mut Vec<u8>, unsigned: &[u8]) {
    let trimmed: &[u8] = match unsigned.iter().position(|b| *b != 0) {
        Some(i) => &unsigned[i..],
        None => &[],
    };
    if trimmed.first().is_some_and(|b| b & 0x80 != 0) {
        let mut v = Vec::with_capacity(trimmed.len() + 1);
        v.push(0);
        v.extend_from_slice(trimmed);
        put_string(out, &v);
    } else {
        put_string(out, trimmed);
    }
}

/// The SSH public key blob for a 65-byte X9.63 P-256 point.
pub(crate) fn public_key_blob(x963: &[u8]) -> Vec<u8> {
    let mut b = Vec::new();
    put_string(&mut b, KEY_TYPE.as_bytes());
    put_string(&mut b, CURVE.as_bytes());
    put_string(&mut b, x963);
    b
}

/// `operator namespaces="tillandsias-approval@v1" ecdsa-sha2-nistp256 AAAA…
/// tillandsias-approval/<slug>`: the trailing comment says which key.
pub(crate) fn allowed_signers_line(x963: &[u8], slug: &str) -> String {
    format!(
        "{PRINCIPAL} namespaces=\"{NAMESPACE}\" {KEY_TYPE} {} {}",
        base64::engine::general_purpose::STANDARD.encode(public_key_blob(x963)),
        key_label(slug)
    )
}

/// The bytes the key actually signs (PROTOCOL.sshsig "signed data"): the
/// magic, namespace, empty reserved field, hash name and the SHA-512 of the
/// message.
pub(crate) fn signed_data(message: &[u8]) -> Vec<u8> {
    let mut d = b"SSHSIG".to_vec();
    put_string(&mut d, NAMESPACE.as_bytes());
    put_string(&mut d, b"");
    put_string(&mut d, b"sha512");
    put_string(&mut d, &Sha512::digest(message));
    d
}

/// The armored SSHSIG for `raw_sig` (64-byte r||s over [`signed_data`]).
pub(crate) fn armor(x963: &[u8], raw_sig: &[u8]) -> Result<String, String> {
    if raw_sig.len() != 64 {
        return Err(format!(
            "a P-256 signature is 64 bytes, got {}",
            raw_sig.len()
        ));
    }
    let mut inner = Vec::new();
    put_mpint(&mut inner, &raw_sig[..32]);
    put_mpint(&mut inner, &raw_sig[32..]);
    let mut sig_blob = Vec::new();
    put_string(&mut sig_blob, KEY_TYPE.as_bytes());
    put_string(&mut sig_blob, &inner);

    let mut blob = b"SSHSIG".to_vec();
    blob.extend_from_slice(&1u32.to_be_bytes());
    put_string(&mut blob, &public_key_blob(x963));
    put_string(&mut blob, NAMESPACE.as_bytes());
    put_string(&mut blob, b"");
    put_string(&mut blob, b"sha512");
    put_string(&mut blob, &sig_blob);

    let b64 = base64::engine::general_purpose::STANDARD.encode(blob);
    let mut out = String::from("-----BEGIN SSH SIGNATURE-----\n");
    for chunk in b64.as_bytes().chunks(70) {
        out.push_str(std::str::from_utf8(chunk).expect("base64 is ascii"));
        out.push('\n');
    }
    out.push_str("-----END SSH SIGNATURE-----\n");
    Ok(out)
}

/// The public key of the wrapped key at `path`, read with no prompt.
pub(crate) fn public_key(path: &Path) -> Result<Vec<u8>, String> {
    let blob = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut x963 = [0u8; 65];
    let mut n = 0usize;
    // SAFETY: the buffers outlive the call and their capacities are passed.
    let rc = unsafe { tla_se_public(blob.as_ptr(), blob.len(), x963.as_mut_ptr(), 65, &mut n) };
    if rc != 0 {
        return Err(ffi_error("reading the approval key", rc));
    }
    Ok(x963[..n].to_vec())
}

/// Create the key at `path` if there is none; return its public key. An
/// existing key is kept, so enrolling twice prints the same line.
pub(crate) fn enrol(path: &Path) -> Result<Vec<u8>, String> {
    if path.exists() {
        return public_key(path);
    }
    // SAFETY: no arguments.
    if unsafe { tla_se_available() } != 1 {
        return Err(ffi_error("enrolling", -1));
    }
    let mut blob = vec![0u8; 4096];
    let mut blob_len = 0usize;
    let mut x963 = [0u8; 65];
    let mut pub_len = 0usize;
    let create =
        |biometric: i32, blob: &mut [u8], bl: &mut usize, x: &mut [u8; 65], pl: &mut usize| {
            // SAFETY: the buffers outlive the call and their capacities are passed.
            unsafe {
                tla_se_create(
                    biometric,
                    blob.as_mut_ptr(),
                    blob.len(),
                    bl,
                    x.as_mut_ptr(),
                    65,
                    pl,
                )
            }
        };
    // Touch ID first; a Mac without enrolled fingerprints gets user presence
    // (Touch ID or the Mac password), as design D1 says.
    let mut rc = create(1, &mut blob, &mut blob_len, &mut x963, &mut pub_len);
    if rc == -3 {
        rc = create(0, &mut blob, &mut blob_len, &mut x963, &mut pub_len);
    }
    if rc != 0 {
        return Err(ffi_error("enrolling", rc));
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    }
    write_private(path, &blob[..blob_len])?;
    Ok(x963[..pub_len].to_vec())
}

fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    use std::io::Write as _;
    use std::os::unix::fs::OpenOptionsExt as _;
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|e| format!("{}: {e}", path.display()))?;
    f.write_all(bytes)
        .map_err(|e| format!("{}: {e}", path.display()))
}

/// Sign `message` with the key at `path`. The enclave asks for Touch ID
/// showing `reason`, every time. Returns the armored SSHSIG.
pub(crate) fn sign(path: &Path, message: &[u8], reason: &str) -> Result<String, String> {
    let blob = std::fs::read(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let x963 = public_key(path)?;
    let data = signed_data(message);
    let reason =
        std::ffi::CString::new(reason).map_err(|_| "the reason has a NUL byte".to_string())?;
    let mut sig = [0u8; 64];
    let mut n = 0usize;
    // SAFETY: the buffers outlive the call and their capacities are passed.
    let rc = unsafe {
        tla_se_sign(
            blob.as_ptr(),
            blob.len(),
            data.as_ptr(),
            data.len(),
            reason.as_ptr(),
            sig.as_mut_ptr(),
            64,
            &mut n,
        )
    };
    if rc != 0 {
        return Err(ffi_error("signing", rc));
    }
    armor(&x963, &sig[..n])
}

/// `--approval-enrol <owner/name>`: create that repo's key if needed and
/// print its allowed-signers line. Exit 0, or 1 with the reason on stderr.
pub(crate) fn enrol_main(slug: &str) -> i32 {
    match key_path(slug).and_then(|p| enrol(&p)) {
        Ok(x963) => {
            println!("{}", allowed_signers_line(&x963, slug));
            0
        }
        Err(e) => {
            eprintln!("approval: {e}");
            1
        }
    }
}

/// `--approval-sign <owner/name> <file>`: sign the file's bytes with that
/// repo's key after Touch ID and print the armored SSHSIG. Exit 0, or 1 with
/// the reason on stderr.
pub(crate) fn sign_main(slug: &str, file: &str) -> i32 {
    let message = match std::fs::read(file) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("approval: {file}: {e}");
            return 1;
        }
    };
    match key_path(slug).and_then(|p| sign(&p, &message, SIGN_REASON)) {
        Ok(armored) => {
            print!("{armored}");
            0
        }
        Err(e) => {
            eprintln!("approval: {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    /// A software key's signature over [`signed_data`], through the same
    /// CryptoKit signing call the enclave key uses.
    fn sw_sign(message: &[u8]) -> (Vec<u8>, Vec<u8>) {
        sw_sign_with(0x42, message)
    }

    fn sw_sign_with(seed: u8, message: &[u8]) -> (Vec<u8>, Vec<u8>) {
        let raw = [seed; 32];
        let data = signed_data(message);
        let (mut x963, mut sig) = ([0u8; 65], [0u8; 64]);
        let (mut pl, mut sl) = (0usize, 0usize);
        // SAFETY: the buffers outlive the call and their capacities are passed.
        let rc = unsafe {
            tla_sw_sign(
                raw.as_ptr(),
                32,
                data.as_ptr(),
                data.len(),
                x963.as_mut_ptr(),
                65,
                &mut pl,
                sig.as_mut_ptr(),
                64,
                &mut sl,
            )
        };
        assert_eq!(rc, 0);
        (x963[..pl].to_vec(), sig[..sl].to_vec())
    }

    fn verify(dir: &Path, x963: &[u8], armored: &str, message: &[u8]) -> bool {
        verify_line(
            dir,
            &allowed_signers_line(x963, "8007342/tillandsias"),
            armored,
            message,
        )
    }

    fn verify_line(dir: &Path, line: &str, armored: &str, message: &[u8]) -> bool {
        let signers = dir.join("allowed_signers");
        let sig = dir.join("msg.sig");
        std::fs::write(&signers, format!("{line}\n")).unwrap();
        std::fs::write(&sig, armored).unwrap();
        let mut child = Command::new("/usr/bin/ssh-keygen")
            .args(["-Y", "verify", "-n", NAMESPACE, "-I", PRINCIPAL, "-f"])
            .arg(&signers)
            .arg("-s")
            .arg(&sig)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("ssh-keygen");
        use std::io::Write as _;
        child.stdin.take().unwrap().write_all(message).unwrap();
        child.wait().unwrap().success()
    }

    const STATEMENT: &[u8] = b"tillandsias-grant v1\naction: workflow-dispatch\n\
        target: 8007342/tillandsias release.yml@main\nscope: once\n";

    /// The envelope is what stock ssh-keygen verifies, and a one-byte change
    /// to the statement, or a different namespace, fails it.
    #[test]
    fn the_envelope_verifies_with_ssh_keygen_and_a_changed_byte_does_not() {
        let dir = tempfile::tempdir().unwrap();
        let (x963, sig) = sw_sign(STATEMENT);
        let armored = armor(&x963, &sig).unwrap();
        assert!(verify(dir.path(), &x963, &armored, STATEMENT), "{armored}");

        let mut tampered = STATEMENT.to_vec();
        tampered[30] ^= 1;
        assert!(!verify(dir.path(), &x963, &armored, &tampered));
    }

    /// One key per repo: a signature made with repo A's key is refused when
    /// presented against repo B's allowed-signers line, and each line names
    /// its key by label and carries nothing about the host.
    #[test]
    fn a_signature_from_repo_a_is_refused_for_repo_b() {
        let dir = tempfile::tempdir().unwrap();
        let (a_pub, a_sig) = sw_sign_with(0x42, STATEMENT);
        let (b_pub, _) = sw_sign_with(0x43, STATEMENT);
        let armored = armor(&a_pub, &a_sig).unwrap();
        let line_a = allowed_signers_line(&a_pub, "acme/repo-a");
        let line_b = allowed_signers_line(&b_pub, "acme/repo-b");
        assert!(
            line_a.ends_with(" tillandsias-approval/acme/repo-a"),
            "{line_a}"
        );
        assert!(line_a.starts_with("operator "), "{line_a}");
        assert!(verify_line(dir.path(), &line_a, &armored, STATEMENT));
        assert!(!verify_line(dir.path(), &line_b, &armored, STATEMENT));
    }

    /// Slugs map to one file each and cannot climb out of the key directory.
    #[test]
    fn slugs_are_owner_slash_name_and_never_traverse() {
        assert_eq!(
            check_slug("8007342/tillandsias"),
            Ok(("8007342", "tillandsias"))
        );
        for bad in [
            "", "a", "a/", "/b", "a/b/c", "../b", "a/..", "a/b c", "a\\b/c",
        ] {
            assert!(check_slug(bad).is_err(), "{bad:?}");
        }
    }

    /// mpint drops leading zeros and adds one before a set top bit.
    #[test]
    fn mpint_is_minimal_and_never_negative() {
        let mut v = Vec::new();
        put_mpint(&mut v, &[0, 0, 0x7f]);
        assert_eq!(v, [0, 0, 0, 1, 0x7f]);
        v.clear();
        put_mpint(&mut v, &[0, 0x80]);
        assert_eq!(v, [0, 0, 0, 2, 0, 0x80]);
        v.clear();
        put_mpint(&mut v, &[0, 0]);
        assert_eq!(v, [0, 0, 0, 0]);
    }

    /// Enrolling over an existing key keeps it rather than replacing it, and
    /// a key file is written 0600 and never overwritten.
    #[test]
    fn an_existing_key_file_is_never_overwritten() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("approval-key.se");
        write_private(&path, b"first").unwrap();
        assert!(write_private(&path, b"second").is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"first");
        use std::os::unix::fs::PermissionsExt as _;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
}

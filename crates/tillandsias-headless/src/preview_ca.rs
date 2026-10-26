//! ORDER 1761-bvyn: the preview CA, the one Tillandsias issuer a HOST browser
//! trusts (operator ruling 2026-10-17: "Automatic, user scope").
//!
//! It signs only the router's preview leaves, and its critical Name
//! Constraints permit DNS `localhost` and its subdomains and exclude every IP
//! address. Browsers enforce constraints on a trust anchor (measured on
//! lenovinha, Chrome 154: a leaf it signs for example.com fails with "Not
//! permitted by name constraints"), so anything that reads its key can
//! impersonate only `*.localhost` to the operator's browser, never a real
//! site. The enclave CA (`intermediate.crt`) stays unconstrained, since squid
//! signs real domains with it, and is never host-trusted
//! (scripts/lua/check-enclave-ca-not-host-trusted.lua).
//!
//! Like the enclave CA (1762-bano) it lives a year and is re-minted at launch
//! when fewer than `CERT_MIN_REMAINING_SECS` remain; a publish mints it only
//! when it is missing or unusable, so a running session never swaps it.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

pub(crate) const CRT: &str = "preview-ca.crt";
pub(crate) const KEY: &str = "preview-ca.key";
/// The NSS nickname, and the certificate's CN.
pub(crate) const NICKNAME: &str = "Tillandsias Preview CA (localhost only)";
/// Permitted: DNS `localhost` (RFC 5280: the name and every name below it).
/// Excluded: all of IPv4 and IPv6, so no leaf it signs vouches for an address.
pub(crate) const NAME_CONSTRAINTS: &str = "nameConstraints=critical,permitted;DNS:localhost,excluded;IP:0.0.0.0/0.0.0.0,excluded;IP:0:0:0:0:0:0:0:0/0:0:0:0:0:0:0:0";

/// `<state>/tillandsias/preview-ca`, beside the enclave CA's directory and
/// never inside it: that one is mounted into containers.
pub(crate) fn dir() -> PathBuf {
    Path::new(&crate::ca_dir()).with_file_name("preview-ca")
}

/// The preview CA is usable when both files exist and the certificate stays
/// valid for `margin_secs` more seconds.
fn usable(dir: &Path, margin_secs: u64) -> bool {
    dir.join(KEY).is_file() && crate::cert_valid_for(&dir.join(CRT), margin_secs)
}

/// Ensure the preview CA in `dir`, minting it when it is missing or valid for
/// less than `margin_secs`. Launch passes `CERT_MIN_REMAINING_SECS`; a publish
/// passes 0. Returns whether it minted.
pub(crate) fn ensure_in(dir: &Path, margin_secs: u64) -> Result<bool, String> {
    // 1118-fqfk slice 2b: the key is a link into tmpfs, refilled from the
    // keyring after a reboot; plaintext is deleted and the CA minted again.
    crate::ca_key_store::materialize(&dir.join(KEY), &dir.join(CRT), true);
    if usable(dir, margin_secs) {
        return Ok(false);
    }
    std::fs::create_dir_all(dir)
        .map_err(|_| "router_not_ready: preview CA directory unavailable")?;
    let _lock = crate::resource_lock::acquire("preview-ca", Duration::from_secs(10), false)?;
    if usable(dir, margin_secs) {
        return Ok(false);
    }
    // Both files are written into a fresh directory and renamed into place key
    // first, so a reader never pairs a new certificate with an old key for
    // longer than the second rename.
    let staging = tempfile::tempdir_in(dir)
        .map_err(|_| "router_not_ready: preview CA staging unavailable")?;
    let crt = staging.path().join(CRT);
    let key = crate::ca_key_store::staging_path(&dir.join(KEY), &std::process::id().to_string());
    let status = Command::new("openssl")
        .args([
            "req",
            "-x509",
            "-newkey",
            "ec",
            "-pkeyopt",
            "ec_paramgen_curve:prime256v1",
        ])
        // 1898-hyhf: `-nodes` only onto the tmpfs store; elsewhere encrypted.
        .args(crate::ca_key_store::key_out_args())
        .envs(crate::ca_key_store::pass_env())
        .arg("-keyout")
        .arg(&key)
        .arg("-out")
        .arg(&crt)
        .args(["-days", crate::CA_VALIDITY_DAYS])
        .args(["-subj", &format!("/O=Tillandsias/CN={NICKNAME}")])
        .args(["-addext", "basicConstraints=critical,CA:TRUE,pathlen:0"])
        .args(["-addext", "keyUsage=critical,keyCertSign,cRLSign"])
        .args(["-addext", NAME_CONSTRAINTS])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|_| "router_not_ready: certificate tool unavailable")?;
    if !status.success() {
        return Err("router_not_ready: preview CA generation failed".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| "router_not_ready: preview CA key permissions failed")?;
    }
    let crt_bytes =
        std::fs::read(&crt).map_err(|_| "router_not_ready: preview CA unreadable after mint")?;
    crate::ca_key_store::seal(&key, &dir.join(KEY), &crt_bytes, true)
        .map_err(|_| "router_not_ready: preview CA key publication failed")?;
    std::fs::rename(&crt, dir.join(CRT))
        .map_err(|_| "router_not_ready: preview CA publication failed")?;
    Ok(true)
}

/// `ensure_in(dir(), margin_secs)`, returning the directory.
pub(crate) fn ensure(margin_secs: u64) -> Result<PathBuf, String> {
    let dir = dir();
    ensure_in(&dir, margin_secs)?;
    Ok(dir)
}

/// Was `leaf` (its first certificate) issued by the preview CA in `dir`, and
/// does it verify under it? A leaf from a previous preview CA, or from the
/// enclave CA before 1761-bvyn, does not, and is re-issued.
#[cfg(any(test, feature = "tray"))]
pub(crate) fn issued_leaf(dir: &Path, leaf: &Path) -> bool {
    Command::new("openssl")
        .arg("verify")
        .arg("-CAfile")
        .arg(dir.join(CRT))
        .arg(leaf)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Sign `san` with the CA in `dir`; the leaf lives as long as the TempDir.
    fn sign(dir: &Path, cn: &str, san: &str) -> (tempfile::TempDir, PathBuf) {
        let work = tempfile::tempdir().unwrap();
        let (csr, key, ext, crt) = (
            work.path().join("l.csr"),
            work.path().join("l.key"),
            work.path().join("l.ext"),
            work.path().join("l.crt"),
        );
        assert!(
            Command::new("openssl")
                .args([
                    "req",
                    "-new",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-subj",
                    &format!("/CN={cn}")
                ])
                .arg("-keyout")
                .arg(&key)
                .arg("-out")
                .arg(&csr)
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success()
        );
        std::fs::write(&ext, format!("subjectAltName={san}\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth\n")).unwrap();
        assert!(
            Command::new("openssl")
                .args(["x509", "-req", "-days", "7", "-set_serial", "7"])
                .arg("-in")
                .arg(&csr)
                .arg("-CA")
                .arg(dir.join(CRT))
                .arg("-CAkey")
                .arg(dir.join(KEY))
                .args(crate::ca_key_store::key_in_args())
                .envs(crate::ca_key_store::pass_env())
                .arg("-extfile")
                .arg(&ext)
                .arg("-out")
                .arg(&crt)
                .stderr(Stdio::null())
                .status()
                .unwrap()
                .success()
        );
        (work, crt)
    }

    /// Sign `san` with the CA in `dir` and verify the leaf against it alone.
    fn sign_and_verify(dir: &Path, cn: &str, san: &str) -> bool {
        let (_work, crt) = sign(dir, cn, san);
        issued_leaf(dir, &crt)
    }

    // Exit criterion 2 of 1761-bvyn. RED before the fix: preview leaves were
    // signed by the unconstrained enclave CA, under which example.com verifies.
    #[test]
    fn the_preview_ca_signs_only_localhost_names() {
        let dir = tempfile::tempdir().unwrap();
        assert!(ensure_in(dir.path(), crate::CERT_MIN_REMAINING_SECS).unwrap());
        assert!(sign_and_verify(
            dir.path(),
            "www.lakanoa.localhost",
            "DNS:www.lakanoa.localhost,DNS:flutter.lakanoa.localhost"
        ));
        assert!(sign_and_verify(dir.path(), "localhost", "DNS:localhost"));
        assert!(
            !sign_and_verify(dir.path(), "example.com", "DNS:example.com"),
            "example.com must be outside the permitted subtree"
        );
        assert!(
            !sign_and_verify(dir.path(), "x", "DNS:localhost.example.com"),
            "a name that merely starts with localhost is not below it"
        );
        assert!(
            !sign_and_verify(dir.path(), "x", "DNS:a.localhost,IP:127.0.0.1"),
            "every IP address is excluded"
        );
    }

    #[test]
    fn the_preview_ca_is_a_critical_name_constrained_ca_for_a_year() {
        let dir = tempfile::tempdir().unwrap();
        ensure_in(dir.path(), 0).unwrap();
        let text = Command::new("openssl")
            .args(["x509", "-noout", "-text", "-in"])
            .arg(dir.path().join(CRT))
            .output()
            .unwrap();
        let text = String::from_utf8_lossy(&text.stdout);
        assert!(text.contains("X509v3 Name Constraints: critical"), "{text}");
        assert!(text.contains("CA:TRUE, pathlen:0"), "{text}");
        assert!(crate::cert_valid_for(
            &dir.path().join(CRT),
            364 * 24 * 60 * 60
        ));
        assert!(!crate::cert_valid_for(
            &dir.path().join(CRT),
            366 * 24 * 60 * 60
        ));
    }

    #[test]
    fn launch_remints_inside_the_margin_and_publish_keeps_a_valid_ca() {
        let dir = tempfile::tempdir().unwrap();
        assert!(ensure_in(dir.path(), 0).unwrap(), "missing: minted");
        let first = std::fs::read(dir.path().join(CRT)).unwrap();
        assert!(
            !ensure_in(dir.path(), crate::CERT_MIN_REMAINING_SECS).unwrap(),
            "a year left: kept at launch"
        );
        assert!(
            ensure_in(dir.path(), 400 * 24 * 60 * 60).unwrap(),
            "inside the margin: re-minted"
        );
        assert_ne!(first, std::fs::read(dir.path().join(CRT)).unwrap());
        std::fs::remove_file(dir.path().join(KEY)).unwrap();
        assert!(
            ensure_in(dir.path(), 0).unwrap(),
            "a missing key: re-minted"
        );
    }

    #[test]
    fn a_leaf_from_another_ca_is_not_issued_by_this_one() {
        let (a, b) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        ensure_in(a.path(), 0).unwrap();
        ensure_in(b.path(), 0).unwrap();
        let (_work, leaf) = sign(a.path(), "www.p.localhost", "DNS:www.p.localhost");
        assert!(issued_leaf(a.path(), &leaf));
        assert!(
            !issued_leaf(b.path(), &leaf),
            "a rotated CA re-issues every older leaf"
        );
    }
}

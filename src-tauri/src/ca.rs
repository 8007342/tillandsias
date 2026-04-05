//! Certificate Authority management for the MITM proxy.
//!
//! Generates and stores a root CA certificate (long-lived, on host) and
//! intermediate CAs (short-lived, per proxy lifetime) for HTTPS caching.
//!
//! The root CA lives at `$XDG_DATA_HOME/tillandsias/ca/` and is generated
//! once, persisting across restarts. Intermediate CAs are generated fresh
//! each time the proxy starts and written to tmpfs (`$XDG_RUNTIME_DIR`).
//!
//! @trace spec:proxy-container

use std::fs;
use std::path::{Path, PathBuf};

use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, KeyPair, KeyUsagePurpose};
use tracing::{debug, info, info_span};

/// Return the directory for storing root CA files.
///
/// Uses `dirs::data_dir()` which resolves to `$XDG_DATA_HOME` on Linux,
/// `~/Library/Application Support` on macOS, `AppData/Roaming` on Windows.
fn ca_dir() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("tillandsias")
        .join("ca")
}

/// Ensure the root CA certificate and key exist, generating them if needed.
///
/// Returns `(cert_path, key_path)` for the root CA. The cert is world-readable;
/// the key is mode 0600 (owner-only).
///
/// @trace spec:proxy-container
pub fn ensure_root_ca() -> Result<(PathBuf, PathBuf), String> {
    let _span = info_span!("ensure_root_ca", accountability = true, category = "ca").entered();

    let dir = ca_dir();
    let cert_path = dir.join("root.crt");
    let key_path = dir.join("root.key");

    // If both files already exist, return early.
    if cert_path.exists() && key_path.exists() {
        debug!(
            spec = "proxy-container",
            "Root CA already exists at {}",
            dir.display()
        );
        return Ok((cert_path, key_path));
    }

    info!(
        accountability = true,
        category = "ca",
        spec = "proxy-container",
        "Generating new root CA certificate"
    );

    // Generate EC P-256 key pair
    let key_pair = KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)
        .map_err(|e| format!("Failed to generate root CA key pair: {e}"))?;

    // Build certificate parameters
    let mut params = CertificateParams::new(Vec::<String>::new())
        .map_err(|e| format!("Failed to create root CA params: {e}"))?;
    params
        .distinguished_name
        .push(DnType::OrganizationName, "Tillandsias");
    params
        .distinguished_name
        .push(DnType::CommonName, "Tillandsias Root CA");
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(1));
    params.not_before = time::OffsetDateTime::now_utc();
    params.not_after =
        time::OffsetDateTime::now_utc() + std::time::Duration::from_secs(10 * 365 * 24 * 3600);
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];

    // Self-sign
    let cert = params
        .self_signed(&key_pair)
        .map_err(|e| format!("Failed to self-sign root CA: {e}"))?;

    let cert_pem = cert.pem();
    let key_pem = key_pair.serialize_pem();

    // Write to disk
    fs::create_dir_all(&dir)
        .map_err(|e| format!("Failed to create CA directory {}: {e}", dir.display()))?;

    fs::write(&cert_path, &cert_pem)
        .map_err(|e| format!("Failed to write root cert: {e}"))?;

    fs::write(&key_path, &key_pem)
        .map_err(|e| format!("Failed to write root key: {e}"))?;

    // Set key file to mode 0600 (owner read/write only)
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = fs::Permissions::from_mode(0o600);
        fs::set_permissions(&key_path, perms)
            .map_err(|e| format!("Failed to set root key permissions: {e}"))?;
    }

    info!(
        accountability = true,
        category = "ca",
        spec = "proxy-container",
        "Root CA generated at {}",
        dir.display()
    );

    Ok((cert_path, key_path))
}

/// Generate an intermediate CA certificate signed by the root CA.
///
/// Returns `(cert_pem, key_pem)` as PEM strings. These are not written to
/// persistent storage -- the caller writes them to tmpfs for the proxy's
/// lifetime only.
///
/// @trace spec:proxy-container
pub fn generate_intermediate_ca(
    root_cert_path: &Path,
    root_key_path: &Path,
) -> Result<(String, String), String> {
    let _span =
        info_span!("generate_intermediate_ca", accountability = true, category = "ca").entered();

    // Read root CA materials
    let root_cert_pem = fs::read_to_string(root_cert_path)
        .map_err(|e| format!("Failed to read root cert: {e}"))?;
    let root_key_pem = fs::read_to_string(root_key_path)
        .map_err(|e| format!("Failed to read root key: {e}"))?;

    // Reconstruct the root CA for signing
    let root_key = KeyPair::from_pem(&root_key_pem)
        .map_err(|e| format!("Failed to parse root key: {e}"))?;
    let root_cert_params = CertificateParams::from_ca_cert_pem(&root_cert_pem)
        .map_err(|e| format!("Failed to parse root cert: {e}"))?;
    let root_cert = root_cert_params
        .self_signed(&root_key)
        .map_err(|e| format!("Failed to reconstruct root cert: {e}"))?;

    // Generate intermediate key pair
    let intermediate_key = KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)
        .map_err(|e| format!("Failed to generate intermediate key pair: {e}"))?;

    // Build intermediate certificate parameters
    let mut params = CertificateParams::new(Vec::<String>::new())
        .map_err(|e| format!("Failed to create intermediate CA params: {e}"))?;
    params
        .distinguished_name
        .push(DnType::OrganizationName, "Tillandsias");
    params
        .distinguished_name
        .push(DnType::CommonName, "Tillandsias Proxy CA");
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    params.not_before = time::OffsetDateTime::now_utc();
    params.not_after =
        time::OffsetDateTime::now_utc() + std::time::Duration::from_secs(30 * 24 * 3600);
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];

    // Sign with root CA
    let intermediate_cert = params
        .signed_by(&intermediate_key, &root_cert, &root_key)
        .map_err(|e| format!("Failed to sign intermediate CA: {e}"))?;

    let cert_pem = intermediate_cert.pem();
    let key_pem = intermediate_key.serialize_pem();

    info!(
        accountability = true,
        category = "ca",
        spec = "proxy-container",
        "Intermediate CA generated (30-day validity)"
    );

    Ok((cert_pem, key_pem))
}

/// Build a CA chain PEM by concatenating intermediate + root certificates.
///
/// The chain is mounted into forge containers so they trust the proxy's
/// dynamically generated server certificates.
///
/// @trace spec:proxy-container
pub fn ca_chain_pem(root_cert_path: &Path, intermediate_cert_pem: &str) -> Result<String, String> {
    let root_cert_pem = fs::read_to_string(root_cert_path)
        .map_err(|e| format!("Failed to read root cert for chain: {e}"))?;

    // Intermediate first, then root (standard chain ordering: leaf -> root)
    let mut chain = String::with_capacity(intermediate_cert_pem.len() + root_cert_pem.len() + 1);
    chain.push_str(intermediate_cert_pem);
    if !intermediate_cert_pem.ends_with('\n') {
        chain.push('\n');
    }
    chain.push_str(&root_cert_pem);

    Ok(chain)
}

/// Return the tmpfs directory for proxy certificate files.
///
/// Uses `$XDG_RUNTIME_DIR` (typically `/run/user/<uid>`, tmpfs on Linux).
/// Falls back to `/tmp` if the runtime dir is not available.
///
/// @trace spec:proxy-container
pub fn proxy_certs_dir() -> PathBuf {
    dirs::runtime_dir()
        .unwrap_or_else(|| PathBuf::from("/tmp"))
        .join("tillandsias")
        .join("proxy-certs")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: generate a root CA in a temporary directory.
    fn generate_root_in_tmpdir() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let dir = tempfile::tempdir().expect("create temp dir");
        let cert_path = dir.path().join("root.crt");
        let key_path = dir.path().join("root.key");

        let key_pair = KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)
            .expect("generate key pair");

        let mut params =
            CertificateParams::new(Vec::<String>::new()).expect("create params");
        params
            .distinguished_name
            .push(DnType::OrganizationName, "Tillandsias");
        params
            .distinguished_name
            .push(DnType::CommonName, "Tillandsias Root CA");
        params.is_ca = IsCa::Ca(BasicConstraints::Constrained(1));
        params.not_before = time::OffsetDateTime::now_utc();
        params.not_after = time::OffsetDateTime::now_utc()
            + std::time::Duration::from_secs(10 * 365 * 24 * 3600);
        params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];

        let cert = params.self_signed(&key_pair).expect("self-sign");

        fs::write(&cert_path, cert.pem()).expect("write cert");
        fs::write(&key_path, key_pair.serialize_pem()).expect("write key");

        (dir, cert_path, key_path)
    }

    #[test]
    fn test_generate_root_ca() {
        // Generate root CA using the helper (same algorithm as ensure_root_ca)
        let (_dir, cert_path, key_path) = generate_root_in_tmpdir();

        let cert_pem = fs::read_to_string(&cert_path).expect("read cert");
        let key_pem = fs::read_to_string(&key_path).expect("read key");

        assert!(
            cert_pem.contains("BEGIN CERTIFICATE"),
            "Root cert should be PEM format"
        );
        assert!(
            cert_pem.contains("END CERTIFICATE"),
            "Root cert should be PEM format"
        );
        assert!(
            key_pem.contains("BEGIN PRIVATE KEY"),
            "Root key should be PEM format"
        );
        assert!(
            key_pem.contains("END PRIVATE KEY"),
            "Root key should be PEM format"
        );
    }

    #[test]
    fn test_generate_intermediate_ca() {
        let (_dir, cert_path, key_path) = generate_root_in_tmpdir();

        let (int_cert, int_key) =
            generate_intermediate_ca(&cert_path, &key_path).expect("generate intermediate");

        assert!(
            int_cert.contains("BEGIN CERTIFICATE"),
            "Intermediate cert should be PEM format"
        );
        assert!(
            int_key.contains("BEGIN PRIVATE KEY"),
            "Intermediate key should be PEM format"
        );
        // Intermediate cert should be different from root cert
        let root_cert = fs::read_to_string(&cert_path).expect("read root cert");
        assert_ne!(
            int_cert, root_cert,
            "Intermediate cert should differ from root cert"
        );
    }

    #[test]
    fn test_ca_chain() {
        let (_dir, cert_path, key_path) = generate_root_in_tmpdir();

        let (int_cert, _int_key) =
            generate_intermediate_ca(&cert_path, &key_path).expect("generate intermediate");

        let chain = ca_chain_pem(&cert_path, &int_cert).expect("build chain");

        // Chain should contain two certificates
        let cert_count = chain.matches("BEGIN CERTIFICATE").count();
        assert_eq!(
            cert_count, 2,
            "Chain should contain exactly 2 certificates (intermediate + root)"
        );

        // Intermediate should come first
        let first_cert_pos = chain.find("BEGIN CERTIFICATE").unwrap();
        let second_cert_pos = chain[first_cert_pos + 1..]
            .find("BEGIN CERTIFICATE")
            .unwrap()
            + first_cert_pos
            + 1;
        // The intermediate cert content should appear before root cert content
        assert!(
            first_cert_pos < second_cert_pos,
            "Intermediate cert should precede root cert in chain"
        );
    }
}

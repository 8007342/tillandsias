//! Ephemeral Certificate Authority for the MITM proxy.
//!
//! Generates the ENTIRE cert chain fresh on every launch:
//! - Root CA (ephemeral, tmpfs, dies with session)
//! - Intermediate CA (ephemeral, tmpfs, dies with proxy)
//!
//! No persistent CA keys on disk. The chain is born with the proxy
//! and dies when the proxy stops. New certs every launch — overhead
//! is milliseconds (EC P-256 key generation).
//!
//! @trace spec:proxy-container, spec:certificate-authority

use std::fs;
use std::path::PathBuf;

use rcgen::{BasicConstraints, CertificateParams, DnType, IsCa, KeyPair, KeyUsagePurpose};
use tracing::{info, info_span, warn};

/// Return the tmpfs directory for ephemeral CA files.
/// Everything here dies with the session (logout/reboot).
/// @trace spec:proxy-container
pub fn proxy_certs_dir() -> PathBuf {
    if let Ok(xdg) = std::env::var("XDG_RUNTIME_DIR") {
        PathBuf::from(xdg)
            .join("tillandsias")
            .join("proxy-certs")
    } else {
        std::env::temp_dir()
            .join("tillandsias-proxy-certs")
    }
}

/// Generate the full ephemeral cert chain (root + intermediate) on tmpfs.
///
/// Returns the certs directory path. Files created:
/// - `root.crt` — root CA cert (injected into forge containers for trust)
/// - `intermediate.crt` — intermediate CA cert (used by squid for SSL bump)
/// - `intermediate.key` — intermediate CA key (used by squid, mode 0600)
/// - `ca-chain.crt` — concatenated chain (root + intermediate, for clients)
///
/// Called on every proxy launch. Takes ~5ms (EC P-256 key generation).
/// @trace spec:proxy-container
pub fn generate_ephemeral_certs() -> Result<PathBuf, String> {
    let _span = info_span!("generate_certs", accountability = true, category = "ca").entered();

    let dir = proxy_certs_dir();
    fs::create_dir_all(&dir)
        .map_err(|e| format!("Failed to create certs dir: {e}"))?;

    // --- Root CA (ephemeral, dies with session) ---
    let root_key = KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)
        .map_err(|e| format!("Root CA keygen failed: {e}"))?;

    let mut root_params = CertificateParams::new(Vec::<String>::new())
        .map_err(|e| format!("Root CA params: {e}"))?;
    root_params.distinguished_name.push(DnType::OrganizationName, "Tillandsias");
    root_params.distinguished_name.push(DnType::CommonName, "Tillandsias Ephemeral Root CA");
    root_params.is_ca = IsCa::Ca(BasicConstraints::Constrained(1));
    root_params.not_before = time::OffsetDateTime::now_utc();
    root_params.not_after = time::OffsetDateTime::now_utc() + std::time::Duration::from_secs(30 * 24 * 3600);
    root_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];

    let root_cert = root_params.self_signed(&root_key)
        .map_err(|e| format!("Root CA self-sign failed: {e}"))?;

    // --- Intermediate CA (signed by root, for squid SSL bump) ---
    let intermediate_key = KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)
        .map_err(|e| format!("Intermediate CA keygen failed: {e}"))?;

    let mut intermediate_params = CertificateParams::new(Vec::<String>::new())
        .map_err(|e| format!("Intermediate CA params: {e}"))?;
    intermediate_params.distinguished_name.push(DnType::OrganizationName, "Tillandsias");
    intermediate_params.distinguished_name.push(DnType::CommonName, "Tillandsias Proxy CA");
    intermediate_params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    intermediate_params.not_before = time::OffsetDateTime::now_utc();
    intermediate_params.not_after = time::OffsetDateTime::now_utc() + std::time::Duration::from_secs(30 * 24 * 3600);
    intermediate_params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];

    let intermediate_cert = intermediate_params.signed_by(&intermediate_key, &root_cert, &root_key)
        .map_err(|e| format!("Intermediate CA signing failed: {e}"))?;

    // --- Write to tmpfs ---
    let root_cert_pem = root_cert.pem();
    let intermediate_cert_pem = intermediate_cert.pem();
    let intermediate_key_pem = intermediate_key.serialize_pem();
    let chain_pem = format!("{}\n{}", intermediate_cert_pem, root_cert_pem);

    fs::write(dir.join("root.crt"), &root_cert_pem)
        .map_err(|e| format!("Write root.crt: {e}"))?;
    fs::write(dir.join("intermediate.crt"), &intermediate_cert_pem)
        .map_err(|e| format!("Write intermediate.crt: {e}"))?;
    fs::write(dir.join("intermediate.key"), &intermediate_key_pem)
        .map_err(|e| format!("Write intermediate.key: {e}"))?;
    fs::write(dir.join("ca-chain.crt"), &chain_pem)
        .map_err(|e| format!("Write ca-chain.crt: {e}"))?;

    // Key file: mode 0600
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let key_path = dir.join("intermediate.key");
        if let Err(e) = fs::set_permissions(&key_path, fs::Permissions::from_mode(0o600)) {
            warn!(
                accountability = true,
                category = "secrets",
                spec = "proxy-container",
                error = %e,
                "Intermediate CA key permissions not set to 0600 — key may be world-readable"
            );
        }
    }

    info!(
        accountability = true,
        category = "ca",
        spec = "proxy-container",
        "Ephemeral CA chain generated (root + intermediate, 30-day validity, tmpfs)"
    );

    Ok(dir)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_ephemeral_certs_produces_valid_pem() {
        let dir = generate_ephemeral_certs().expect("cert generation should succeed");
        assert!(dir.join("root.crt").exists());
        assert!(dir.join("intermediate.crt").exists());
        assert!(dir.join("intermediate.key").exists());
        assert!(dir.join("ca-chain.crt").exists());

        let chain = fs::read_to_string(dir.join("ca-chain.crt")).unwrap();
        assert!(chain.contains("BEGIN CERTIFICATE"));
        // Chain should have two certs (intermediate + root)
        assert_eq!(chain.matches("BEGIN CERTIFICATE").count(), 2);

        // Clean up
        fs::remove_dir_all(&dir).ok();
    }
}

use std::collections::HashMap;
use std::sync::OnceLock;

#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(dead_code)]
pub struct CatalogEntry {
    pub category: String,
    pub name: String,
    pub digest: String,
    pub primary: bool,
}

#[allow(dead_code)]
pub fn get_catalog() -> &'static HashMap<String, CatalogEntry> {
    static CATALOG: OnceLock<HashMap<String, CatalogEntry>> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let mut m = HashMap::new();

        // WEB static
        m.insert(
            "WEB/busybox".to_string(),
            CatalogEntry {
                category: "WEB".to_string(),
                name: "busybox".to_string(),
                digest: "docker.io/library/busybox@sha256:498668471c644f55f28f0907e1cda58a43f87db2137aa59dcbcc354bb4a6aa7c".to_string(),
                primary: true,
            },
        );
        m.insert(
            "WEB/nginx".to_string(),
            CatalogEntry {
                category: "WEB".to_string(),
                name: "nginx".to_string(),
                digest: "docker.io/library/nginx@sha256:a444a7f0e69d747d33d964fbdcfa14ef4b3df36371adccfc71d6f46644eb2fc2".to_string(),
                primary: false,
            },
        );
        m.insert(
            "WEB/php-apache".to_string(),
            CatalogEntry {
                category: "WEB".to_string(),
                name: "php-apache".to_string(),
                digest: "docker.io/library/php@sha256:1a84f3ab6be6b896ec093e0b4a441315b7c7b8863f69ee73b435272a0c64bb93".to_string(),
                primary: false,
            },
        );

        // WEB-APP
        m.insert(
            "WEB-APP/wordpress".to_string(),
            CatalogEntry {
                category: "WEB-APP".to_string(),
                name: "wordpress".to_string(),
                digest: "docker.io/library/wordpress@sha256:49a2aef12bf7045b8ed399b1a50a109a1ff77f8ed2bb80bd1c888d22ef14c3e8".to_string(),
                primary: true,
            },
        );
        m.insert(
            "WEB-APP/mariadb".to_string(),
            CatalogEntry {
                category: "WEB-APP".to_string(),
                name: "mariadb".to_string(),
                digest: "docker.io/library/mariadb@sha256:12eb4c0b49f485db1f9db390a184bf8e907d72c019dce6c41b8c0a9cf186354b".to_string(),
                primary: true,
            },
        );

        // SCIENTIFIC
        m.insert(
            "SCIENTIFIC/minimal-notebook".to_string(),
            CatalogEntry {
                category: "SCIENTIFIC".to_string(),
                name: "minimal-notebook".to_string(),
                digest: "quay.io/jupyter/minimal-notebook@sha256:0d1d6a695029e2898bfd117a2249ed1eb8319f3f4c6e917d23d8cbfadbfbcaf5".to_string(),
                primary: true,
            },
        );
        m.insert(
            "SCIENTIFIC/rstudio".to_string(),
            CatalogEntry {
                category: "SCIENTIFIC".to_string(),
                name: "rstudio".to_string(),
                digest: "docker.io/rocker/rstudio@sha256:59cc9a12c222ff466141a0e8d02251dfcb28646011409f6e632cbbeadca89117".to_string(),
                primary: false,
            },
        );

        // BIOLOGY TECH
        m.insert(
            "BIOLOGY TECH/samtools".to_string(),
            CatalogEntry {
                category: "BIOLOGY TECH".to_string(),
                name: "samtools".to_string(),
                digest: "quay.io/biocontainers/samtools@sha256:5688582f3efaf88b1ccf2bb30526be64a4d9241c8fbb172d7f8dcc25a33758df".to_string(),
                primary: true,
            },
        );
        m.insert(
            "BIOLOGY TECH/bioconductor_docker".to_string(),
            CatalogEntry {
                category: "BIOLOGY TECH".to_string(),
                name: "bioconductor_docker".to_string(),
                digest: "docker.io/bioconductor/bioconductor_docker@sha256:49fa6b216f4fc9eb1330960d7f461b1b4d084ef7010f3c051a37c96350dc1e20".to_string(),
                primary: false,
            },
        );

        // STORAGE
        m.insert(
            "STORAGE/nextcloud".to_string(),
            CatalogEntry {
                category: "STORAGE".to_string(),
                name: "nextcloud".to_string(),
                digest: "docker.io/library/nextcloud@sha256:b63d76db86e8810da30cb4cb941e7dc6c9de079d3752e50efb06602521c78dbd".to_string(),
                primary: true,
            },
        );
        m.insert(
            "STORAGE/minio".to_string(),
            CatalogEntry {
                category: "STORAGE".to_string(),
                name: "minio".to_string(),
                digest: "docker.io/minio/minio@sha256:fa2af09c53051052dc90de9fde61d9a5b3a3250f1624baf4e3ef4003eb87661f".to_string(),
                primary: false,
            },
        );
        m
    })
}

/// Resolves a requested catalog name to a pinned digest.
/// Forge requests must carry ONLY catalog names.
/// Non-catalog requests are refused with one actionable line.
#[allow(dead_code)]
pub fn resolve_catalog_entry(category: &str, name: &str) -> Result<CatalogEntry, String> {
    let key = format!("{}/{}", category, name);
    get_catalog().get(&key).cloned().ok_or_else(|| {
        format!(
            "Catalog refusal: category/name {}/{} is not in the allowlist.",
            category, name
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_catalog_resolve_success() {
        let entry = resolve_catalog_entry("WEB", "busybox").expect("should resolve");
        assert_eq!(entry.category, "WEB");
        assert!(entry.digest.contains("@sha256:"));
    }

    #[test]
    fn test_catalog_resolve_failure_tag_drift() {
        // "tag drift or non-catalog name is refused (non-zero, one-line reason)."
        let err = resolve_catalog_entry("WEB", "busybox:latest").expect_err("should fail");
        assert_eq!(
            err,
            "Catalog refusal: category/name WEB/busybox:latest is not in the allowlist."
        );
    }
}

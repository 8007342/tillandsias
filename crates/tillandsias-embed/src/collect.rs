// @trace spec:user-runtime-lifecycle, spec:observatorium-dashboard
// ORDER 1916-embd. The ONE asset collection, shared by build.rs (which embeds
// what it returns) and by the `from-source` runtime (which reads the same files
// from the source tree), so the two regimes cannot list different assets.
#![allow(dead_code)]
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Asset {
    pub source: PathBuf,
    pub dest: String,
}

/// Every runtime asset under `repo_root`, sorted by destination path.
pub fn collect_all(repo_root: &Path) -> Vec<Asset> {
    let mut assets = Vec::new();
    collect_assets(
        &repo_root.join("images"),
        &repo_root.join("images"),
        repo_root,
        "",
        &mut assets,
    );
    collect_legacy_observatorium(repo_root, &mut assets);
    collect_assets(
        &repo_root.join("skills"),
        &repo_root.join("skills"),
        repo_root,
        "images/default/skills",
        &mut assets,
    );
    // Research library (spec:research-records): repo-root research/ is staged
    // into images/default/research by build-image.sh, exactly like skills/.
    collect_assets(
        &repo_root.join("research"),
        &repo_root.join("research"),
        repo_root,
        "images/default/research",
        &mut assets,
    );

    for rel in ["scripts/manage-cache.sh", "scripts/run-observatorium.sh"] {
        let path = repo_root.join(rel);
        if path.is_file() {
            assets.push(Asset {
                source: path.clone(),
                dest: rel.to_string(),
            });
        } else {
            panic!("required runtime asset missing: {}", path.display());
        }
    }

    assets.sort_by(|a, b| a.dest.cmp(&b.dest));
    assets
}

// @trace spec:observatorium-dashboard
// The embedded legacy page is independent of the Flutter dashboard. Never
// recursively package its SDK caches, dependencies or generated web artifact.
pub fn collect_legacy_observatorium(repo_root: &Path, out: &mut Vec<Asset>) {
    for directory in ["observatorium", "observatorium/lib"] {
        let path = repo_root.join(directory);
        let meta = fs::symlink_metadata(&path)
            .unwrap_or_else(|e| panic!("metadata {}: {e}", path.display()));
        assert!(
            meta.is_dir() && !meta.file_type().is_symlink(),
            "runtime asset directory must be a real directory: {}",
            path.display()
        );
    }
    for rel in [
        "observatorium/index.html",
        "observatorium/lib/chart.umd.js",
        "observatorium/lib/highlight.min.css",
        "observatorium/lib/highlight.min.js",
    ] {
        let path = repo_root.join(rel);
        let meta = fs::symlink_metadata(&path)
            .unwrap_or_else(|e| panic!("metadata {}: {e}", path.display()));
        assert!(
            meta.is_file() && !meta.file_type().is_symlink(),
            "runtime asset must be a regular file, not a symlink: {}",
            path.display()
        );
        out.push(Asset {
            source: path,
            dest: rel.to_string(),
        });
    }
}

pub fn collect_assets(
    dir: &Path,
    collection_root: &Path,
    repo_root: &Path,
    dest_prefix: &str,
    out: &mut Vec<Asset>,
) {
    if !dir.is_dir() {
        panic!(
            "required runtime asset directory missing: {}",
            dir.display()
        );
    }

    let mut entries = fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("read_dir {}: {e}", dir.display()))
        .map(|entry| entry.unwrap().path())
        .collect::<Vec<_>>();
    entries.sort();

    for path in entries {
        let meta = fs::symlink_metadata(&path)
            .unwrap_or_else(|e| panic!("metadata {}: {e}", path.display()));
        if meta.file_type().is_symlink() {
            panic!(
                "runtime assets must not contain symlinks: {}",
                path.display()
            );
        }

        let rel_repo = path
            .strip_prefix(repo_root)
            .expect("asset under repo root")
            .to_string_lossy()
            .replace('\\', "/");

        // Skip images/default/skills if we are collecting the images/ directory recursively.
        // Same for images/default/research (staged copy of repo-root research/).
        if dest_prefix.is_empty()
            && (rel_repo.starts_with("images/default/skills")
                || rel_repo.starts_with("images/default/research"))
        {
            continue;
        }

        if meta.is_dir() {
            collect_assets(&path, collection_root, repo_root, dest_prefix, out);
        } else if meta.is_file() {
            let dest = if !dest_prefix.is_empty() {
                let sub_rel = path
                    .strip_prefix(collection_root)
                    .expect("sub-asset under collection root")
                    .to_string_lossy()
                    .replace('\\', "/");
                format!("{dest_prefix}/{sub_rel}")
            } else {
                rel_repo.clone()
            };

            out.push(Asset { source: path, dest });
        }
    }
}

pub fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        fs::metadata(path)
            .map(|m| m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        false
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn legacy_assets_ignore_dashboard_dependencies_but_reject_selected_symlinks() {
        let root = std::env::temp_dir().join(format!(
            "observatorium-embed-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(root.join("observatorium/lib")).unwrap();
        fs::create_dir_all(root.join("observatorium/node_modules/.bin")).unwrap();
        for rel in [
            "index.html",
            "lib/chart.umd.js",
            "lib/highlight.min.css",
            "lib/highlight.min.js",
        ] {
            fs::write(root.join("observatorium").join(rel), "legacy asset").unwrap();
        }
        symlink(
            "../wrangler/bin/wrangler.js",
            root.join("observatorium/node_modules/.bin/wrangler"),
        )
        .unwrap();
        let mut assets = Vec::new();
        collect_legacy_observatorium(&root, &mut assets);
        assert_eq!(assets.len(), 4);
        assert!(
            assets
                .iter()
                .all(|asset| !asset.dest.contains("node_modules"))
        );
        let selected = root.join("observatorium/lib/chart.umd.js");
        fs::remove_file(&selected).unwrap();
        symlink("highlight.min.js", &selected).unwrap();
        assert!(
            std::panic::catch_unwind(|| collect_legacy_observatorium(&root, &mut Vec::new()))
                .is_err()
        );
        fs::remove_dir_all(root).unwrap();
    }
}

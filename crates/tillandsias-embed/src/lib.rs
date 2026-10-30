// @trace spec:user-runtime-lifecycle, spec:linux-native-portable-executable, spec:init-command
//! ORDER 1916-embd. The runtime assets the headless binary materializes.
//!
//! Default: embedded at build time (build.rs), so the binary is self-contained.
//! Feature `from-source` (headless `assets-from-source`, the dev loop): nothing
//! is embedded and nothing under the asset tree is watched, so editing a
//! cheatsheet costs no rustc work; [`runtime_assets`] reads the same files
//! (the same [`collect`] rules) from the source tree at first use. The root is
//! `TILLANDSIAS_ASSET_SOURCE_ROOT`, else the checkout this crate was built in.

// The embedded regime reads nothing at runtime: collect is build.rs's (by
// #[path]) and, here, only the from-source reader's and the tests'. Without
// the cfg every non-test build warns dead_code, which clippy -D warnings
// refuses (x86_64-pc-windows-gnu cross gate, 1916-embd). collect.rs carries
// its own allow(dead_code) for the tests, which use collect_all only.
#[cfg(any(test, feature = "from-source"))]
mod collect;

#[derive(Clone, Copy, Debug)]
pub struct EmbeddedRuntimeAsset {
    pub path: &'static str,
    pub bytes: &'static [u8],
    pub executable: bool,
}

include!(concat!(env!("OUT_DIR"), "/runtime_assets_generated.rs"));

/// True when this build embeds its assets (the release and gate regime).
pub const ASSETS_EMBEDDED: bool = !cfg!(feature = "from-source");

/// Every runtime asset, sorted by path.
#[cfg(not(feature = "from-source"))]
pub fn runtime_assets() -> &'static [EmbeddedRuntimeAsset] {
    EMBEDDED_RUNTIME_ASSETS
}

/// Every runtime asset, sorted by path, read once from the source tree.
#[cfg(feature = "from-source")]
pub fn runtime_assets() -> &'static [EmbeddedRuntimeAsset] {
    use std::sync::OnceLock;
    static ASSETS: OnceLock<Vec<EmbeddedRuntimeAsset>> = OnceLock::new();
    ASSETS.get_or_init(|| {
        let root = std::env::var_os("TILLANDSIAS_ASSET_SOURCE_ROOT")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| std::path::PathBuf::from(env!("TILLANDSIAS_EMBED_REPO_ROOT")));
        collect::collect_all(&root)
            .into_iter()
            .map(|a| {
                let bytes = std::fs::read(&a.source)
                    .unwrap_or_else(|e| panic!("read {}: {e}", a.source.display()));
                EmbeddedRuntimeAsset {
                    path: Box::leak(a.dest.into_boxed_str()),
                    bytes: Box::leak(bytes.into_boxed_slice()),
                    executable: collect::is_executable(&a.source),
                }
            })
            .collect()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    /// ORDER 1916-embd. The embedded regime serves every asset the source tree
    /// holds, byte for byte, without reading the tree: the source-root override
    /// points at a path that does not exist. Run it in the release profile:
    ///   cargo test --release -p tillandsias-embed
    #[cfg(not(feature = "from-source"))]
    #[test]
    fn embedded_regime_serves_every_asset_without_the_source_tree() {
        // SAFETY: this crate's tests are the only readers of this variable.
        unsafe { std::env::set_var("TILLANDSIAS_ASSET_SOURCE_ROOT", "/nonexistent/1916-embd") };
        let served = runtime_assets();
        let root =
            Path::new(&std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"))
                .join("../..");
        let want = collect::collect_all(&root);
        const { assert!(ASSETS_EMBEDDED) };
        assert_eq!(
            served.len(),
            want.len(),
            "embedded count differs from the tree"
        );
        for (s, w) in served.iter().zip(&want) {
            assert_eq!(s.path, w.dest);
            assert_eq!(
                s.bytes,
                std::fs::read(&w.source).unwrap().as_slice(),
                "{}",
                s.path
            );
            assert_eq!(
                s.executable,
                collect::is_executable(&w.source),
                "{}",
                s.path
            );
        }
        for p in [
            "images/default/Containerfile",
            "observatorium/index.html",
            "scripts/manage-cache.sh",
            "images/default/skills/advance-work-from-plan/SKILL.md",
            "images/default/research/INDEX.md",
        ] {
            assert!(served.iter().any(|a| a.path == p), "{p} is not served");
        }
        println!("ok:embedded-assets-serve-without-source:{}", served.len());
    }

    /// The from-source regime reads the same list from the tree it is pointed at.
    #[cfg(feature = "from-source")]
    #[test]
    fn from_source_regime_embeds_nothing_and_reads_the_tree() {
        const { assert!(!ASSETS_EMBEDDED) };
        assert!(EMBEDDED_RUNTIME_ASSETS.is_empty());
        let root =
            Path::new(&std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR"))
                .join("../..");
        assert_eq!(runtime_assets().len(), collect::collect_all(&root).len());
        println!("ok:from-source-assets:{}", runtime_assets().len());
    }
}

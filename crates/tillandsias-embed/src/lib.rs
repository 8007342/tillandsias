// @trace spec:user-runtime-lifecycle, spec:linux-native-portable-executable, spec:init-command
//! ORDER 1916-embd. The runtime assets the headless binary materializes,
//! embedded here so their rerun-if-changed lines invalidate this crate and not
//! tillandsias-headless's own build script.

#[derive(Clone, Copy, Debug)]
pub struct EmbeddedRuntimeAsset {
    pub path: &'static str,
    pub bytes: &'static [u8],
    pub executable: bool,
}

include!(concat!(env!("OUT_DIR"), "/runtime_assets_generated.rs"));

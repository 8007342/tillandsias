// @trace order:2354-5biy, spec:command-policies
//
// The forge marker, baked into the forge image (images/default/Containerfile):
// `/etc/tillandsias/forge`, a regular file owned by root, mode 0444, content
// `kind=forge`. Operator ruling 2026-11-27: the marker decides whether this is
// a forge; TILLANDSIAS_HOST_KIND alone does not. The command policy's reader
// is tillandsias-plan `command_policy::marker_state`; this is the same rule
// for the tray's in-forge refusals, which use the STRICTER of the variable and
// the marker, because refusing is the safe error.

use std::path::Path;

pub const FORGE_MARKER_PATH: &str = "/etc/tillandsias/forge";

/// Whether `path` is a valid forge marker: not a symlink, root-owned, writable
/// by nobody, saying `kind=forge`. Always false off unix.
pub fn marker_is_valid(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let Ok(meta) = std::fs::symlink_metadata(path) else {
            return false;
        };
        if !meta.file_type().is_file() || meta.uid() != 0 || meta.mode() & 0o222 != 0 {
            return false;
        }
        std::fs::read_to_string(path)
            .map(|s| s.lines().any(|l| l.trim() == "kind=forge"))
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        false
    }
}

/// For a REFUSAL: this process is in a forge when the variable says so OR the
/// marker is present. Never use this to grant anything.
pub fn refuse_as_forge() -> bool {
    std::env::var("TILLANDSIAS_HOST_KIND").as_deref() == Ok("forge")
        || marker_is_valid(Path::new(FORGE_MARKER_PATH))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn a_user_written_marker_is_not_valid() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("forge");
        assert!(!marker_is_valid(&p));
        std::fs::write(&p, "kind=forge\n").unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o444)).unwrap();
        assert!(!marker_is_valid(&p), "the test runs unprivileged");
    }
}

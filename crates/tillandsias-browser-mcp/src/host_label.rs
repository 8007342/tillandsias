//! A project's name as it appears in a preview host
//! (`<service>.<label>.localhost`), order 1763-nc9d.
//!
//! The lane identity stays the project's RAW name: podman container names,
//! `/home/forge/src/<project>`, the mirror and the locks all accept it. Only
//! the host boundary maps, and every host-boundary caller (the router route,
//! the preview leaf's CN/SAN and file names, publish_local's URL, the
//! browser window's resolver rules and host map, and this crate's allowlist)
//! reads this ONE function, so no two of them can disagree about a name.
//!
//! WHY. A browser lowercases a host, and `_` is not a hostname character, so
//! `DEVxSD_gameJam` was refused at the lane identity, minted a mixed-case SAN,
//! and failed browser.open's exact project comparison (operator live finding,
//! 2026-10-17).
//!
//! @trace spec:local-web-preview, spec:host-browser-mcp

/// The longest DNS label (RFC 1035).
pub const MAX_LABEL: usize = 63;
/// The longest project part of a host: `flutter.` and `.localhost` must still
/// fit the 253-byte name.
pub const MAX_PROJECT_HOST: usize = 200;

/// Map `project` to its host label. Each dot-separated part is folded on its
/// own (a project named `macron.dev` routes as `www.macron.dev.localhost`,
/// order 1118-dwgx): ASCII letters lowercase, every other character outside
/// `[a-z0-9]` becomes `-`, runs of `-` collapse, a leading or trailing `-`
/// trims, and the part caps at 63 with no trailing `-`. An already-valid
/// lowercase name is returned unchanged.
pub fn project_host_label(project: &str) -> Result<String, String> {
    let mut parts = Vec::new();
    for part in project.split('.') {
        let mut label = String::with_capacity(part.len());
        for ch in part.chars() {
            if ch.is_ascii_alphanumeric() {
                label.push(ch.to_ascii_lowercase());
            } else if !label.is_empty() && !label.ends_with('-') {
                label.push('-');
            }
        }
        label.truncate(MAX_LABEL);
        let label = label.trim_end_matches('-');
        if label.is_empty() {
            return Err(format!(
                "invalid_project_host_label: '{project}' has a dot-separated part with no letter or digit, so it names no host; rename the project directory so every part between dots holds a letter or digit"
            ));
        }
        parts.push(label.to_string());
    }
    let host = parts.join(".");
    if host.len() > MAX_PROJECT_HOST {
        return Err(format!(
            "invalid_project_host_label: '{project}' maps to a {}-byte host label, over the {MAX_PROJECT_HOST}-byte limit that keeps <service>.<label>.localhost a valid name; use a shorter project directory name",
            host.len()
        ));
    }
    Ok(host)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_label_maps_the_operators_project() {
        assert_eq!(
            project_host_label("DEVxSD_gameJam").as_deref(),
            Ok("devxsd-gamejam")
        );
        assert_eq!(
            project_host_label("My Project__v2").as_deref(),
            Ok("my-project-v2")
        );
        assert_eq!(
            project_host_label("_lead-and-trail_").as_deref(),
            Ok("lead-and-trail")
        );
        assert_eq!(project_host_label("Café").as_deref(), Ok("caf"));
        assert_eq!(
            project_host_label("Macron.Dev").as_deref(),
            Ok("macron.dev")
        );
    }

    /// NEGATIVE CONTROL: a name that is already a valid host label is
    /// byte-identical, so no existing preview URL moves.
    #[test]
    fn host_label_leaves_a_valid_name_unchanged() {
        for name in ["acme", "my-app", "macron.dev", "tillandsias.org", "a1-b2"] {
            assert_eq!(project_host_label(name).as_deref(), Ok(name));
        }
    }

    #[test]
    fn host_label_caps_each_part_at_63_with_no_trailing_hyphen() {
        let long = format!("{}_{}", "a".repeat(62), "b".repeat(10));
        let label = project_host_label(&long).unwrap();
        assert_eq!(label.len(), 62, "the cut lands on the '-' and trims it");
        assert!(!label.ends_with('-'));
        let label = project_host_label(&"x".repeat(80)).unwrap();
        assert_eq!(label.len(), MAX_LABEL);
    }

    #[test]
    fn host_label_refuses_a_name_that_names_no_host() {
        for name in ["", "___", "a..b", ".hidden", "trailing."] {
            let err = project_host_label(name).unwrap_err();
            assert!(err.starts_with("invalid_project_host_label:"), "{err}");
        }
        let over = vec!["a".repeat(60); 4].join(".");
        assert!(project_host_label(&over).unwrap_err().contains("over the"));
    }
}

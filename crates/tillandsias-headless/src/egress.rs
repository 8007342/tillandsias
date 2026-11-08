//! Egress tier declarations (openspec change curated-egress-tiers, order 2041-jb57).
//!
//! Each image directory carries `egress.yaml` naming the tiers its container
//! may reach; `scripts/lua/check-egress-declarations.lua` refuses one without
//! it. The launcher reads the declaration to decide whether a container gets
//! the proxy environment at all. An image with no declaration, or with only
//! non-proxied tiers (`none`, `siblings`, `host`), gets none, so it fails
//! closed. Every proxied tier is still served by the strict port's union
//! (3128) until the per-tier ports land (2041-i3nk part 2).
//!
//! @trace spec:proxy-container, order:2041-jb57

/// The image directories' declarations, embedded at build time.
const DECLARATIONS: &[(&str, &str)] = &[
    (
        "builder",
        include_str!("../../../images/builder/egress.yaml"),
    ),
    (
        "chromium",
        include_str!("../../../images/chromium/egress.yaml"),
    ),
    (
        "default",
        include_str!("../../../images/default/egress.yaml"),
    ),
    (
        "flutter",
        include_str!("../../../images/flutter/egress.yaml"),
    ),
    (
        "enclave-fetch",
        include_str!("../../../images/enclave-fetch/egress.yaml"),
    ),
    ("git", include_str!("../../../images/git/egress.yaml")),
    (
        "imagegen",
        include_str!("../../../images/imagegen/egress.yaml"),
    ),
    (
        "imagegen-corridorkey",
        include_str!("../../../images/imagegen-corridorkey/egress.yaml"),
    ),
    (
        "imagegen-studio",
        include_str!("../../../images/imagegen-studio/egress.yaml"),
    ),
    (
        "inference",
        include_str!("../../../images/inference/egress.yaml"),
    ),
    ("proxy", include_str!("../../../images/proxy/egress.yaml")),
    ("router", include_str!("../../../images/router/egress.yaml")),
    ("studio", include_str!("../../../images/studio/egress.yaml")),
    ("vault", include_str!("../../../images/vault/egress.yaml")),
    ("warp", include_str!("../../../images/warp/egress.yaml")),
    ("web", include_str!("../../../images/web/egress.yaml")),
    (
        "web-wrangler",
        include_str!("../../../images/web-wrangler/egress.yaml"),
    ),
    ("webkit", include_str!("../../../images/webkit/egress.yaml")),
];

/// Tiers the proxy serves. `research` is served by the proxy only until
/// enclave-fetch (2041-csm4) takes it over.
const PROXIED: &[&str] = &[
    "registries",
    "assets",
    "providers",
    "model-hubs",
    "vcs",
    "research",
];

/// The tiers `image` declares, or `None` when it has no declaration.
pub(crate) fn declared(image: &str) -> Option<Vec<&'static str>> {
    let (_, text) = DECLARATIONS.iter().find(|(name, _)| *name == image)?;
    let line = text
        .lines()
        .find_map(|l| l.trim_start().strip_prefix("tiers:"))?;
    let list = line.trim().strip_prefix('[')?.strip_suffix(']')?;
    Some(
        list.split(',')
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .collect(),
    )
}

/// Whether `image`'s container is given the proxy environment.
pub(crate) fn wants_proxy(image: &str) -> bool {
    declared(image).is_some_and(|tiers| tiers.iter().any(|t| PROXIED.contains(t)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn proxied_images_today_still_get_the_proxy() {
        // The four launch sites that read the declaration; each had the proxy
        // environment unconditionally before 2041-jb57.
        for image in ["default", "git", "inference"] {
            assert!(wants_proxy(image), "{image} lost its proxy");
        }
    }

    #[test]
    fn vault_router_and_undeclared_images_get_no_proxy() {
        assert_eq!(declared("vault"), Some(vec!["none"]));
        assert!(!wants_proxy("vault"));
        assert!(!wants_proxy("router"));
        assert_eq!(declared("no-such-image"), None);
        assert!(!wants_proxy("no-such-image"));
    }

    #[test]
    fn every_declaration_parses_to_at_least_one_tier() {
        for (name, _) in DECLARATIONS {
            let tiers = declared(name).unwrap_or_default();
            assert!(!tiers.is_empty(), "{name}: no tiers parsed");
        }
    }
}

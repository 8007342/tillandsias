//! The images each launch site ensures before it starts containers
//! (order 1776-ch4m, epic 1776-ondm).
//!
//! These lists lived inline in four launch functions and drifted apart: the
//! status check and the web lane built Chromium, the forge launch built
//! neither Chromium nor the proxy, and the tray's browser window ensured
//! nothing at all, so a forge's first `browser.open` on a host that never ran
//! `--init` failed "image missing". One table, read by every site, and
//! `scripts/lua/check-launch-images-table.lua` refuses a module that names an
//! image it neither lists here nor ensures.
//!
//! KEEP: `Opencode` does NOT list Chromium. The operator's low-end-host ruling
//! is to never build what the session may not use; the first `browser.open`
//! builds it, once, visibly (`ChromiumWindow`).
//!
//! @trace spec:host-browser-mcp, order:1776-ch4m

/// A place that launches containers and must ensure their images first.
// The window sites are reached only from the tray's browser path.
#[cfg_attr(not(feature = "host-services"), allow(dead_code))]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum LaunchSite {
    /// `run_opencode_mode`: the CLI forge lane.
    Opencode,
    /// `run_opencode_web_mode`: the web lane, which opens a Chromium window.
    OpencodeWeb,
    /// `ensure_enclave_for_project`: the tray's forge launch.
    EnclaveForProject,
    /// `run_observatorium_mode`.
    Observatorium,
    /// `run_status_check`: the representative stack smoke.
    Status,
    /// A Chromium window from the tray (`browser.open`).
    ChromiumWindow,
    /// A WebKit window from the tray (order 1656-tjv4).
    WebKitWindow,
}

/// The images `site` ensures, in build order (a dependency's base is built
/// by the seam itself, `image_dependency`).
pub(crate) fn launch_images(site: LaunchSite) -> &'static [&'static str] {
    match site {
        // "router" before the forge: ensure_router_running starts it
        // (order-327 class; macOS cold-forge live repro 2026-07-15).
        LaunchSite::Opencode => &["proxy", "router", "git", "inference", "forge"],
        LaunchSite::OpencodeWeb => &[
            "proxy",
            "git",
            "inference",
            "chromium-core",
            "chromium-framework",
            "forge",
            "router",
        ],
        // "router" included (2026-07-11): ensure_router_running launches it.
        LaunchSite::EnclaveForProject => &["router", "git", "inference", "forge"],
        LaunchSite::Observatorium => &["web", "router", "chromium-core", "chromium-framework"],
        // router-web-images-ondemand-ensure-gap (2026-07-16): router and web
        // are started by the status smoke too.
        LaunchSite::Status => &[
            "proxy",
            "git",
            "inference",
            "chromium-core",
            "chromium-framework",
            "forge",
            "router",
            "web",
        ],
        LaunchSite::ChromiumWindow => &["chromium-framework"],
        LaunchSite::WebKitWindow => &["webkit"],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [LaunchSite; 7] = [
        LaunchSite::Opencode,
        LaunchSite::OpencodeWeb,
        LaunchSite::EnclaveForProject,
        LaunchSite::Observatorium,
        LaunchSite::Status,
        LaunchSite::ChromiumWindow,
        LaunchSite::WebKitWindow,
    ];

    #[test]
    fn every_listed_image_has_a_build_context() {
        for site in ALL {
            for name in launch_images(site) {
                assert!(
                    crate::runtime_assets::image_context_rel(name).is_ok(),
                    "{site:?} lists {name}, which has no build context"
                );
            }
        }
    }

    #[test]
    fn the_cli_forge_lane_never_builds_chromium() {
        let opencode = launch_images(LaunchSite::Opencode);
        assert!(
            !opencode.iter().any(|n| n.starts_with("chromium")),
            "the operator's low-end ruling: the first browser.open builds Chromium, \
             not the forge launch ({opencode:?})"
        );
        assert!(
            opencode.iter().position(|n| *n == "router")
                < opencode.iter().position(|n| *n == "forge"),
            "the router is ensured before the forge starts it"
        );
    }

    #[test]
    fn a_window_ensures_the_image_it_runs() {
        assert_eq!(
            launch_images(LaunchSite::ChromiumWindow),
            &["chromium-framework"]
        );
        assert_eq!(launch_images(LaunchSite::WebKitWindow), &["webkit"]);
    }
}

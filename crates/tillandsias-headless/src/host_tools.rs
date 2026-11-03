//! Order 1969-7qm7: the host tool surface, grouped by what each tool DOES.
//!
//! One lane socket (the forge registers it as the `host-browser` MCP server)
//! serves every host-side tool: the web preview lifecycle, the opt-in
//! toolchains, local image generation, the ComfyUI studio pipeline, the host
//! browser windows, the read-only Cloudflare reads and the web-studio co-edit
//! tools. Nothing in the names said so: `publish_local` / `service_*` /
//! `toolchain_prepare` / `studio_*` sat beside `browser.*`, `image.*`,
//! `studio.*` and `cloudflare.*`, and agents could not tell from the list
//! which tool starts a sibling container, which generates an image and which
//! only reads.
//!
//! This module holds the one index of the surface, in three forms that cannot
//! drift because they are rendered from the same table:
//!
//! - the `instructions` text the `initialize` reply carries (what an MCP
//!   client shows the agent FIRST, before any tool is called);
//! - the `tillandsias.index` tool, for a harness that drops `instructions`;
//! - the deprecated-alias table: every flat name keeps working for one
//!   release as an alias of its namespaced canonical name, and is listed
//!   LAST with a description that names the canonical tool.
//!
//! Behaviour is identical under either name: [`canonical`] rewrites the alias
//! before dispatch, and the dispatcher only ever sees canonical names.
//! @trace order:1969-7qm7, spec:host-browser-mcp, spec:mcp-tool-socket

/// A tool renamed into its group. `(canonical, deprecated alias)`.
///
/// The alias is accepted by `tools/call` and listed, deprecated, after every
/// canonical tool. It is removed one release after 1969-7qm7 ships.
pub(crate) const RENAMED: &[(&str, &str)] = &[
    ("preview.publish", "publish_local"),
    ("preview.status", "service_status"),
    ("preview.stop", "service_stop"),
    ("preview.reload", "service_reload"),
    ("preview.logs", "service_logs"),
    ("toolchain.prepare", "toolchain_prepare"),
    ("webstudio.options", "studio_options"),
    ("webstudio.open", "studio_open"),
    ("webstudio.changes", "studio_changes"),
    ("webstudio.publish_request", "studio_publish_request"),
];

/// The name the dispatcher runs: the canonical name for a deprecated alias,
/// `name` itself otherwise.
pub(crate) fn canonical(name: &str) -> &str {
    RENAMED
        .iter()
        .find(|(_, old)| *old == name)
        .map_or(name, |(new, _)| *new)
}

/// The deprecated alias of a canonical name, when it has one.
pub(crate) fn deprecated_alias(canonical: &str) -> Option<&'static str> {
    RENAMED
        .iter()
        .find(|(new, _)| *new == canonical)
        .map(|(_, old)| *old)
}

/// One group of the index: its prefix, what it is for, and what it starts.
pub(crate) struct Group {
    pub prefix: &'static str,
    pub does: &'static str,
    pub starts: &'static str,
    pub use_when: &'static str,
}

/// The groups in the order `tools/list` advertises them.
pub(crate) const GROUPS: &[Group] = &[
    Group {
        prefix: "preview.*",
        does: "publish, inspect, reload, stop and read the logs of this project's local WEB preview (www.<project>.localhost)",
        starts: "preview.publish starts a sibling web container on the enclave (static or local Wrangler); the others act on it",
        use_when: "the user wants the project hosted or served locally; not for a framework dev server (run that in the forge)",
    },
    Group {
        prefix: "toolchain.*",
        does: "prepare an opt-in toolchain image (flutter) shared beside the forge",
        starts: "toolchain.prepare builds the toolchain image once; the forge's `flutter` command calls it for you",
        use_when: "a toolchain command reports runtime_not_ready",
    },
    Group {
        prefix: "image.*",
        does: "generate images locally with stable-diffusion.cpp (no hosted service, no cost)",
        starts: "image.generate starts the engine container on the host GPU queue on first use; models download only with the user's consent token",
        use_when: "the user asks for a picture, sprite, texture or concept art",
    },
    Group {
        prefix: "studio.*",
        does: "the headless ComfyUI studio pipeline: run a committed workflow, validate a family spec, finish pixels, lay out a contact sheet, key footage",
        starts: "studio.run_workflow and studio.key_footage queue GPU work in the project's studio container (it must be running: studio.start {} starts it on demand, studio.status says whether it runs); validate_family, finish_pixels and contact_sheet start nothing and use no GPU",
        use_when: "the project commits ComfyUI workflows or art family specs under art/",
    },
    Group {
        prefix: "browser.*",
        does: "open and drive browser windows ON THE HOST for project-local URLs (the forge has no browser binary)",
        starts: "browser.open starts a host browser window (visible or headless); dev: true adds CDP, eval, console and network tails",
        use_when: "you need to see, screenshot, click or debug a page the preview or a dev server serves",
    },
    Group {
        prefix: "cloudflare.*",
        does: "read-only (GET) views of the operator's own Cloudflare account: accounts, zones, workers, builds, pages",
        starts: "nothing; call cloudflare.scope_probe first to learn which reads the stored sign-in permits",
        use_when: "the user asks what is deployed, built or configured on their Cloudflare account",
    },
    Group {
        prefix: "cloud.*",
        does: "read-only usage of the operator's cloud accounts: GitHub Actions and Cloudflare Workers Builds minutes used against their free-tier caps (1966-47vt)",
        starts: "nothing; cloud.usage reads with the host's stored GitHub App and Cloudflare tokens and names any permission a provider refuses",
        use_when: "before a release, a merge to main or a deploy, or when the user asks how much of the month's free build minutes are left",
    },
    Group {
        prefix: "webstudio.*",
        does: "co-edit this project in a visual web studio (GrapesJS, Decap, Tina, Puck, Onlook) that the operator opens",
        starts: "nothing from the lane today: webstudio.open names the operator command that opens the studio window; webstudio.changes reads the saves it committed",
        use_when: "the user wants to author the site interactively beside you",
    },
];

/// The index tool's name.
pub(crate) const INDEX_TOOL: &str = "tillandsias.index";

/// The text an agent sees first: the `initialize` reply's `instructions`.
pub(crate) fn instructions() -> String {
    let mut s = String::from(
        "Tillandsias host tools (one MCP socket, registered in the forge as `host-browser`). \
         Every tool acts on THIS lane's project only; the host attributes the project from the socket, never from arguments. \
         Groups, by what they do:\n",
    );
    for g in GROUPS {
        s.push_str(&format!(
            "- {}: {}. Starts: {}. Use when: {}.\n",
            g.prefix, g.does, g.starts, g.use_when
        ));
    }
    s.push_str(&format!(
        "- {INDEX_TOOL}: this index, as a tool result.\n\
         Deprecated flat names ({}) still work for one release as aliases; prefer the namespaced name.",
        RENAMED
            .iter()
            .map(|(new, old)| format!("{old} -> {new}"))
            .collect::<Vec<_>>()
            .join(", ")
    ));
    s
}

/// `tillandsias.index {}`: the same index, as a tool.
pub(crate) fn index_descriptor() -> serde_json::Value {
    serde_json::json!({
        "name": INDEX_TOOL,
        "description": "Which host tool does what, grouped: preview.* (local web preview, starts a sibling web container), toolchain.* (flutter image), image.* (local image generation), studio.* (headless ComfyUI pipeline), browser.* (host browser windows), cloudflare.* (read-only account views), webstudio.* (visual co-edit studios). Call it when you are unsure which tool starts what. Starts nothing.",
        "inputSchema": { "type": "object", "properties": {} }
    })
}

/// The index as a tool result.
pub(crate) fn index_result() -> serde_json::Value {
    serde_json::json!({
        "groups": GROUPS.iter().map(|g| serde_json::json!({
            "prefix": g.prefix, "does": g.does, "starts": g.starts, "use_when": g.use_when
        })).collect::<Vec<_>>(),
        "deprecated_aliases": RENAMED.iter().map(|(new, old)| serde_json::json!({
            "alias": old, "canonical": new
        })).collect::<Vec<_>>(),
        "instructions": instructions(),
    })
}

/// A listed descriptor for the deprecated alias of `canonical`: the same
/// schema, a description that names the canonical tool.
pub(crate) fn deprecated_descriptor(canonical: &serde_json::Value) -> Option<serde_json::Value> {
    let name = canonical["name"].as_str()?;
    let alias = deprecated_alias(name)?;
    let mut d = canonical.clone();
    d["name"] = serde_json::json!(alias);
    d["description"] = serde_json::json!(format!(
        "Deprecated alias of {name} (1969-7qm7; removed one release later). Use {name}. {}",
        canonical["description"].as_str().unwrap_or("")
    ));
    Some(d)
}

/// Re-list `canonical_tools` with every renamed tool's deprecated alias
/// appended after all of them, in table order.
pub(crate) fn with_deprecated_aliases(
    canonical_tools: Vec<serde_json::Value>,
) -> Vec<serde_json::Value> {
    let mut out = canonical_tools;
    let aliases: Vec<serde_json::Value> = RENAMED
        .iter()
        .filter_map(|(new, _)| out.iter().find(|t| t["name"] == *new))
        .filter_map(deprecated_descriptor)
        .collect();
    out.extend(aliases);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_alias_resolves_to_its_canonical_and_canonical_is_fixed() {
        for (new, old) in RENAMED {
            assert_eq!(canonical(old), *new);
            assert_eq!(canonical(new), *new);
            assert_eq!(deprecated_alias(new), Some(*old));
        }
        assert_eq!(canonical("browser.open"), "browser.open");
        assert_eq!(deprecated_alias("browser.open"), None);
    }

    #[test]
    fn canonical_names_are_namespaced_and_aliases_are_not() {
        for (new, old) in RENAMED {
            assert!(new.contains('.'), "{new}");
            assert!(!old.contains('.'), "{old}");
            let prefix = new.split('.').next().unwrap();
            assert!(
                GROUPS.iter().any(|g| g.prefix == format!("{prefix}.*")),
                "{new} belongs to a listed group"
            );
        }
    }

    #[test]
    fn the_instructions_name_what_each_group_starts() {
        let text = instructions();
        for g in GROUPS {
            assert!(text.contains(g.prefix), "{}", g.prefix);
            assert!(text.contains(g.starts), "{}", g.prefix);
        }
        assert!(text.contains("sibling web container"));
        assert!(text.contains("host browser window"));
        assert!(text.contains("studio container"));
        // 1969-cfyt: the studio starts on demand, never by config + relaunch.
        assert!(text.contains("studio.start {}"));
        assert!(!text.contains(".tillandsias/config.toml"));
        for (new, old) in RENAMED {
            assert!(text.contains(&format!("{old} -> {new}")));
        }
    }

    #[test]
    fn deprecated_descriptor_keeps_the_schema_and_names_the_canonical_tool() {
        let canon = serde_json::json!({
            "name": "preview.publish",
            "description": "Publish.",
            "inputSchema": { "type": "object", "required": ["category"] }
        });
        let d = deprecated_descriptor(&canon).unwrap();
        assert_eq!(d["name"], "publish_local");
        assert_eq!(d["inputSchema"], canon["inputSchema"]);
        let desc = d["description"].as_str().unwrap();
        assert!(desc.starts_with("Deprecated alias of preview.publish"));
        assert!(desc.ends_with("Publish."));
        assert!(deprecated_descriptor(&serde_json::json!({"name": "browser.open"})).is_none());
    }

    #[test]
    fn aliases_are_listed_after_every_canonical_tool() {
        let tools = with_deprecated_aliases(vec![
            serde_json::json!({"name": "preview.publish", "description": "a", "inputSchema": {}}),
            serde_json::json!({"name": "browser.open", "description": "b", "inputSchema": {}}),
            serde_json::json!({"name": "webstudio.open", "description": "c", "inputSchema": {}}),
        ]);
        let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            [
                "preview.publish",
                "browser.open",
                "webstudio.open",
                "publish_local",
                "studio_open"
            ]
        );
    }
}

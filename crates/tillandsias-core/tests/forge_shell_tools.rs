// Tests for forge shell tools (shell-helpers.sh and config-overlay/mcp/git-tools.sh)
// @trace spec:forge-shell-tools

use std::fs;
use std::path::PathBuf;

fn repo_root() -> PathBuf {
    // CARGO_MANIFEST_DIR points at crates/tillandsias-core; walk up two levels.
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .parent()
        .and_then(|p| p.parent())
        .expect("repo root")
        .to_path_buf()
}

fn read_helper(path: &str) -> String {
    let full = repo_root().join(path);
    fs::read_to_string(&full).unwrap_or_else(|e| panic!("read {}: {}", full.display(), e))
}

/// Shell helpers source ships every shortcut the task requires.
#[test]
fn shell_helpers_defines_tgs_tgp_and_cache_report() {
    let src = read_helper("images/default/config-overlay/shell-helpers.sh");

    assert!(src.contains("tgs()"), "shell-helpers.sh should define `tgs()`");
    assert!(src.contains("tgp()"), "shell-helpers.sh should define `tgp()`");
    assert!(
        src.contains("tgpull()"),
        "shell-helpers.sh should define `tgpull()`"
    );
    assert!(
        src.contains("cache-report()"),
        "shell-helpers.sh should define `cache-report()`"
    );
}

/// The Wave-7 cache constants are the only allowed source of cache tier paths.
#[test]
fn shell_helpers_reads_cache_constants() {
    let src = read_helper("images/default/config-overlay/shell-helpers.sh");

    for var in [
        "TILLANDSIAS_PROJECT_CACHE",
        "TILLANDSIAS_SHARED_CACHE",
        "TILLANDSIAS_WORKSPACE",
        "TILLANDSIAS_EPHEMERAL",
    ] {
        assert!(
            src.contains(var),
            "shell-helpers.sh should reference {} (Wave-7 cache constant)",
            var
        );
    }
}

/// The help text discovers all shortcuts and the cheatsheet path.
#[test]
fn shell_helpers_help_lists_shortcuts() {
    let src = read_helper("images/default/config-overlay/shell-helpers.sh");

    for needle in [
        "tgs ",
        "tgp ",
        "tgpull ",
        "cache-report ",
        "tillandsias-help",
        "$TILLANDSIAS_CHEATSHEETS",
    ] {
        assert!(
            src.contains(needle),
            "tillandsias-shell-help should mention `{}`",
            needle
        );
    }
}

/// MCP git-tools server advertises and dispatches the new tools.
#[test]
fn mcp_git_tools_lists_new_tools() {
    let src = read_helper("images/default/config-overlay/mcp/git-tools.sh");

    // tools/list registers them
    for tool in ["\"git_push\"", "\"git_pull\"", "\"cache_report\""] {
        assert!(
            src.contains(tool),
            "git-tools.sh tools/list should expose {}",
            tool
        );
    }

    // tools/call dispatches them
    for branch in ["\"git_push\")", "\"git_pull\")", "\"cache_report\")"] {
        assert!(
            src.contains(branch),
            "git-tools.sh tools/call should dispatch {}",
            branch
        );
    }
}

/// All three new owned files cite spec:forge-shell-tools for traceability.
#[test]
fn forge_shell_tools_trace_present() {
    for path in [
        "images/default/config-overlay/shell-helpers.sh",
        "images/default/config-overlay/mcp/git-tools.sh",
        "images/default/config-overlay/opencode/instructions/cache-discipline.md",
    ] {
        let src = read_helper(path);
        assert!(
            src.contains("spec:forge-shell-tools"),
            "{} should @trace spec:forge-shell-tools",
            path
        );
    }
}

/// Cache discipline doc surfaces both the shell shortcut and the MCP tool.
#[test]
fn cache_discipline_mentions_cache_report() {
    let src = read_helper("images/default/config-overlay/opencode/instructions/cache-discipline.md");

    assert!(
        src.contains("cache-report"),
        "cache-discipline.md should mention the `cache-report` shell shortcut"
    );
    assert!(
        src.contains("cache_report"),
        "cache-discipline.md should mention the `cache_report` MCP tool"
    );
    assert!(
        src.contains("When to rebuild"),
        "cache-discipline.md should explain rebuild vs clear policy"
    );
}

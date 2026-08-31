#!/usr/bin/env bash
# ORDER 799-tb7q — ONE definition of the host-preferred / toolbox-fallback
# dispatch, sourced by dev-host scripts.
#
# methodology multi_host_development.toolbox_first_scripts.tool_dispatch_pattern
# documents the shape:
#
#   command -v <tool> >/dev/null && <tool> … ||
#   toolbox run --container tillandsias-builder <tool> …
#
# WHY A LIB AND NOT THAT PATTERN INLINE. Measured 2026-08-26: 61 scripts under
# scripts/ call `jq`, 15 guard or dispatch, 46 do not. Several have many call
# sites each. Copy-pasting a six-line block 46 more times makes 48 copies of one
# rule, and a second copy of a rule can DRIFT from the first — after which a
# caller "handles" a missing tool according to a definition the project no
# longer uses. That is not hypothetical here: the only two dispatchers that
# existed before this file duplicated the block verbatim, written in the same
# cycle by the same author.
#
# SOURCED, NOT EXECUTED. It defines functions and sets nothing global beyond
# them, so a caller that sources it twice is unharmed.
#
# BASH 3.2 CLEAN — macOS ships 3.2 and some callers run there (761-g36m).
#
# NOT FOR SHIPPED DIAGNOSTICS. scripts/tray-diagnose.sh and
# scripts/diagnose-macos-provision.sh deliberately keep their own inline copies:
# they run on end-user machines where a sibling lib may not exist, and a shipped
# diagnostic that fails to SOURCE a helper is worse than one that duplicates six
# lines. Two justified copies beat a diagnostic that cannot start.

# resolve_tool <tool> [container]
#
# Echoes the command prefix to use for <tool>, or nothing when neither the host
# nor the toolbox can provide it. Callers decide what an empty answer means —
# some degrade, some refuse — because that decision is theirs and not this
# file's. Returns 0 when a tool was resolved, 1 when none was.
#
# Deliberately echoes a PREFIX rather than running the tool: callers pipe into
# it, redirect it, and pass heredocs, and a wrapper that owned invocation would
# have to reproduce all of that.
resolve_tool() {
    _rt_tool="${1:?resolve_tool: tool name required}"
    _rt_container="${2:-tillandsias-builder}"
    if command -v "$_rt_tool" >/dev/null 2>&1; then
        printf '%s' "$_rt_tool"
        return 0
    fi
    # The probe is `<tool> --version` inside the container rather than a bare
    # `toolbox run true`: the container existing does not mean the tool is in
    # it, which is the entire defect this packet was filed for. Writing the
    # dispatch line for a tool the toolbox lacks makes things WORSE — the
    # fallback arm runs and reports command-not-found, a more confusing failure
    # than the host one it replaced.
    if command -v toolbox >/dev/null 2>&1 \
       && toolbox run --container "$_rt_container" "$_rt_tool" --version >/dev/null 2>&1; then
        printf 'toolbox run --container %s %s' "$_rt_container" "$_rt_tool"
        return 0
    fi
    return 1
}

# require_tool <tool> [container]
#
# resolve_tool, but prints a diagnosis to stderr and returns 1 when nothing
# resolves. The message names BOTH places that were checked, because "jq: command
# not found" from inside a container is the confusing failure this packet exists
# to prevent.
require_tool() {
    _qt_tool="${1:?require_tool: tool name required}"
    _qt_container="${2:-tillandsias-builder}"
    if _qt_cmd="$(resolve_tool "$_qt_tool" "$_qt_container")"; then
        printf '%s' "$_qt_cmd"
        return 0
    fi
    echo "error: '$_qt_tool' is available neither on this host nor in the" >&2
    echo "       '$_qt_container' toolbox. This is a TOOLING gap on this machine," >&2
    echo "       not a fault in what the script was inspecting (799-tb7q)." >&2
    echo "       Install $_qt_tool on the host, or add it to the toolbox init set" >&2
    echo "       in scripts/with-tillandsias-builder.sh." >&2
    return 1
}

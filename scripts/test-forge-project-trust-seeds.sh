#!/usr/bin/env bash
# @trace order:1447-nmq3, spec:default-image
#
# Fixture for the forge's folder-trust seeds (images/default/lib-common.sh):
# seed_claude_project_trust, seed_codex_project_trust, seed_agy_workspace_trust.
#
# The operator was asked to trust the checked-out folder on every forge launch
# (Claude and Antigravity; Codex likewise, its trust being in an ephemeral
# CODEX_HOME). Claude's seed existed but nothing called it since 892f2e46e.
# Each case runs a seed against a scratch HOME with a project path shaped the
# way find_project_dir returns it ("$HOME/src/<p>/", trailing slash) and asserts
# the EXACT key the harness reads.
#
# Pre-fix: FAILS. seed_codex_project_trust and seed_agy_workspace_trust do not
# exist, seed_claude_project_trust is not forge-gated and keys the path WITH
# its trailing slash, and no entrypoint calls any of them.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/images/default/lib-common.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/forge-trust-seeds.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0
fail=0
ok() { echo "ok:   $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1" >&2; fail=$((fail + 1)); }
trace_lifecycle() { :; }

# The SEEDS use jq (it ships in the forge image). The fixture's own reads go
# through the plan binary's jq subset, per the jq call-site ratchet (1375-tsfu).
command -v jq >/dev/null 2>&1 || { echo "skip:forge-project-trust-seeds:no-jq"; exit 0; }
. "$ROOT/scripts/plan-binary-probe.sh"
PLAN="$(cd "$ROOT" && resolve_plan_binary)" || { echo "skip:forge-project-trust-seeds:no-plan-binary"; exit 0; }
case "$PLAN" in ./*) PLAN="$ROOT/${PLAN#./}" ;; esac
jget() { "$PLAN" json get "$@"; }
for fn in seed_claude_project_trust seed_codex_project_trust seed_agy_workspace_trust; do
    eval "$(sed -n "/^$fn()/,/^}/p" "$LIB")"
    declare -F "$fn" >/dev/null || { echo "FAIL: $fn is not defined in lib-common.sh" >&2; exit 1; }
done

fresh_home() {
    export HOME="$W/$1"
    rm -rf "$HOME"
    mkdir -p "$HOME/src/demo"
    PROJ="$HOME/src/demo/"      # as find_project_dir returns it
    KEY="$HOME/src/demo"        # as the harnesses key it
    export CODEX_HOME="$HOME/.codex-worker"
    unset CLAUDE_CONFIG_FILE AGY_SETTINGS_FILE
}

# ── 1: forge, empty HOME — each seed writes exactly the key its harness reads ─
fresh_home forge1
export TILLANDSIAS_HOST_KIND=forge
for _ in 1 2; do
    seed_claude_project_trust "$PROJ"
    seed_codex_project_trust "$PROJ"
    seed_agy_workspace_trust "$PROJ"
done
if [ "$(jget -r --arg k "$KEY" '.projects[$k].hasTrustDialogAccepted' "$HOME/.claude.json")" = true ] &&
    [ "$(jget -r '.projects | keys | length' "$HOME/.claude.json")" = 1 ]; then
    ok "claude: projects[\"$KEY\"].hasTrustDialogAccepted = true, and no trailing-slash key"
else
    bad "claude: $(cat "$HOME/.claude.json" 2>/dev/null)"
fi
codex_hdr="$(grep -cxF "[projects.\"$KEY\"]" "$CODEX_HOME/config.toml" 2>/dev/null)"
codex_lvl="$(grep -A1 -xF "[projects.\"$KEY\"]" "$CODEX_HOME/config.toml" 2>/dev/null | tail -n 1)"
if [ "$codex_hdr" = 1 ] && [ "$codex_lvl" = 'trust_level = "trusted"' ]; then
    ok "codex: exactly one [projects.\"$KEY\"] with trust_level = \"trusted\" after two runs"
else
    bad "codex: headers=$codex_hdr level=[$codex_lvl] file=[$(cat "$CODEX_HOME/config.toml" 2>/dev/null)]"
fi
agy_cfg="$HOME/.gemini/antigravity-cli/settings.json"
if [ "$(jget -c '.trustedWorkspaces' "$agy_cfg" 2>/dev/null)" = "[\"$KEY\"]" ]; then
    ok "agy: trustedWorkspaces = [\"$KEY\"] (a list, once) after two runs"
else
    bad "agy: $(cat "$agy_cfg" 2>/dev/null)"
fi

# ── 2: forge, existing configs — merge, never clobber ───────────────────────
fresh_home forge2
cat >"$HOME/.claude.json" <<EOF
{"hasCompletedOnboarding": true, "bypassPermissionsModeAccepted": true,
 "projects": {"$KEY": {"hasTrustDialogAccepted": false, "allowedTools": ["Bash"]},
              "/other/project": {"hasTrustDialogAccepted": false}}}
EOF
mkdir -p "$CODEX_HOME"
printf '[mcp_servers.forge-plan]\ncommand = "tillandsias-plan"' >"$CODEX_HOME/config.toml"   # no trailing newline
mkdir -p "$HOME/.gemini/antigravity-cli"
printf '{"colorScheme": "dark", "trustedWorkspaces": ["/else/where"]}\n' >"$HOME/.gemini/antigravity-cli/settings.json"
seed_claude_project_trust "$PROJ"
seed_codex_project_trust "$PROJ"
seed_agy_workspace_trust "$PROJ"
if [ "$(jget -c --arg k "$KEY" '[.hasCompletedOnboarding, .bypassPermissionsModeAccepted, .projects[$k].hasTrustDialogAccepted, .projects[$k].allowedTools, .projects["/other/project"].hasTrustDialogAccepted]' "$HOME/.claude.json")" = '[true,true,true,["Bash"],false]' ]; then
    ok "claude: Claude's own not-yet-asked false becomes true; other keys and projects preserved"
else
    bad "claude merge: $(cat "$HOME/.claude.json")"
fi
if grep -qxF '[mcp_servers.forge-plan]' "$CODEX_HOME/config.toml" &&
    grep -qxF 'command = "tillandsias-plan"' "$CODEX_HOME/config.toml" &&
    grep -qxF "[projects.\"$KEY\"]" "$CODEX_HOME/config.toml"; then
    ok "codex: the mcp_servers table survives; the project table is appended on its own line"
else
    bad "codex merge: [$(cat "$CODEX_HOME/config.toml")]"
fi
if [ "$(jget -c '[.colorScheme, .trustedWorkspaces]' "$HOME/.gemini/antigravity-cli/settings.json")" = "[\"dark\",[\"/else/where\",\"$KEY\"]]" ]; then
    ok "agy: other settings and trusted workspaces preserved, project appended"
else
    bad "agy merge: $(cat "$HOME/.gemini/antigravity-cli/settings.json")"
fi
# An existing Codex project table is left exactly as it is.
printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$KEY" >"$CODEX_HOME/config.toml"
before="$(cat "$CODEX_HOME/config.toml")"
seed_codex_project_trust "$PROJ"
[ "$(cat "$CODEX_HOME/config.toml")" = "$before" ] &&
    ok "codex: an existing [projects.\"<path>\"] entry is never rewritten" ||
    bad "codex: an existing project entry was rewritten"
# A settings.json agy cannot read is not ours to rewrite.
printf 'not json' >"$HOME/.gemini/antigravity-cli/settings.json"
seed_agy_workspace_trust "$PROJ"
[ "$(cat "$HOME/.gemini/antigravity-cli/settings.json")" = "not json" ] &&
    ok "agy: a settings.json that is not a JSON object is left untouched" ||
    bad "agy: an unreadable settings.json was rewritten"

# ── 3: NEGATIVE CONTROL — outside a forge, nothing is written ───────────────
fresh_home baremetal
unset TILLANDSIAS_HOST_KIND
seed_claude_project_trust "$PROJ"
seed_codex_project_trust "$PROJ"
seed_agy_workspace_trust "$PROJ"
written="$(cd "$HOME" && find . -type f | LC_ALL=C sort | tr '\n' ' ')"
[ -z "$written" ] && ok "non-forge: no file written under HOME" || bad "non-forge wrote: $written"
export TILLANDSIAS_HOST_KIND=forge

# ── 4: each entrypoint seeds after find_project_dir (and Claude after restore) ─
line_of() { grep -n -m1 -F "$2" "$ROOT/images/default/$1" | cut -d: -f1; }
for pair in "entrypoint-forge-claude.sh:seed_claude_project_trust \"\$PROJECT_DIR\"" \
            "entrypoint-forge-codex.sh:seed_codex_project_trust \"\$PROJECT_DIR\"" \
            "entrypoint-forge-antigravity.sh:seed_agy_workspace_trust \"\$PROJECT_DIR\""; do
    ep="${pair%%:*}"
    call="${pair#*:}"
    c="$(line_of "$ep" "$call")"
    f="$(line_of "$ep" "find_project_dir")"
    if [ -n "$c" ] && [ -n "$f" ] && [ "$c" -gt "$f" ]; then
        ok "$ep calls the seed after find_project_dir"
    else
        bad "$ep: seed call line=[$c], find_project_dir line=[$f]"
    fi
done
c="$(line_of entrypoint-forge-claude.sh 'seed_claude_project_trust "$PROJECT_DIR"')"
r="$(line_of entrypoint-forge-claude.sh 'claude-approvals-vault restore')"
b="$(line_of entrypoint-forge-claude.sh 'seed_claude_bypass_consent')"
if [ -n "$r" ] && [ -n "$b" ] && [ "$b" -lt "$r" ] && [ "$r" -lt "$c" ]; then
    ok "claude order: bypass seed < approvals restore < project trust seed"
else
    bad "claude order: bypass=$b restore=$r trust=$c"
fi

# ── 5 (optional): the real agy accepts what the seed writes ─────────────────
AGY="$(command -v agy 2>/dev/null || true)"
if [ -n "$AGY" ] && [ -x "$AGY" ]; then
    fresh_home agyreal
    seed_agy_workspace_trust "$PROJ"
    (cd "$KEY" && HOME="$HOME" timeout 12 "$AGY" -p ping </dev/null >/dev/null 2>&1)
    log="$(cat "$HOME"/.gemini/antigravity-cli/log/*.log 2>/dev/null)"
    if [ -n "$log" ] && ! grep -q "invalid settings" <<<"$log"; then
        ok "agy $("$AGY" --version 2>/dev/null | tail -n 1): loads the seeded settings.json without 'invalid settings'"
    else
        bad "agy rejected or never read the seeded settings: $(grep -m1 'settings' <<<"$log")"
    fi
    # Control: the map form really is rejected, so the case above has teeth.
    printf '{"trustedWorkspaces": {"%s": true}}\n' "$KEY" >"$HOME/.gemini/antigravity-cli/settings.json"
    rm -rf "$HOME/.gemini/antigravity-cli/log"
    (cd "$KEY" && HOME="$HOME" timeout 12 "$AGY" -p ping </dev/null >/dev/null 2>&1)
    if grep -q "invalid settings: trustedWorkspaces" "$HOME"/.gemini/antigravity-cli/log/*.log 2>/dev/null; then
        ok "agy control: a map-shaped trustedWorkspaces IS rejected (so the check above can fail)"
    else
        bad "agy control: the map form was not rejected; the acceptance check proves nothing"
    fi
else
    echo "note:forge-project-trust-seeds:optional-arm-skipped:real-agy-absent"
fi

# ── 6 (optional): the real codex parses and VALIDATES what the seed writes ───
CODEX="$(command -v codex 2>/dev/null || true)"
if [ -n "$CODEX" ] && [ -x "$CODEX" ]; then
    fresh_home codexreal
    mkdir -p "$CODEX_HOME"
    printf '[mcp_servers.demo]\ncommand = "true"' >"$CODEX_HOME/config.toml"
    seed_codex_project_trust "$PROJ"
    if out="$(CODEX_HOME="$CODEX_HOME" timeout 30 "$CODEX" mcp list 2>&1)" && grep -q '^demo ' <<<"$out"; then
        ok "codex $("$CODEX" --version 2>/dev/null | tail -n 1): loads the seeded config.toml (mcp table intact)"
    else
        bad "codex could not load the seeded config: $(tail -n 2 <<<"$out")"
    fi
    # Control: codex validates projects.<path>.trust_level, so the key is the
    # one it reads, not an ignored one.
    printf '\n[projects."%s"]\ntrust_level = 42\n' "$HOME/src/other" >>"$CODEX_HOME/config.toml"
    out="$(CODEX_HOME="$CODEX_HOME" timeout 30 "$CODEX" mcp list 2>&1)"
    if grep -q 'trust_level' <<<"$out"; then
        ok "codex control: a wrong-typed projects.<path>.trust_level is rejected by name"
    else
        bad "codex control: a wrong-typed trust_level was accepted; the key may be ignored"
    fi
else
    echo "note:forge-project-trust-seeds:optional-arm-skipped:real-codex-absent"
fi

total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    echo "PASS: forge-project-trust-seeds $pass/$total (1447-nmq3)"
    exit 0
fi
echo "FAIL: forge-project-trust-seeds $pass/$total (1447-nmq3)"
exit 1

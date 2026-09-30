#!/usr/bin/env bash
# @trace order:1517-p83m
#
# test-forge-entrypoints-source-agent-profile.sh — every agent entrypoint loads
# agent-profile.sh from where the image installs it, and says so when it can't.
#
# WHY THIS EXISTS. From 2026-05-14 (b837eae09) the four agent entrypoints
# sourced /opt/config-overlay/mcp/agent-profile.sh behind a silent [ -f ]
# guard. The image installs it at /home/forge/.config-overlay/mcp/. So no forge
# exported AGENT_PROFILE, and 1446-qkx4's generic-skill link never ran;
# measured on lenovinha's live forge 2026-09-30 (~/.claude/skills absent while
# /opt/skills/project-discipline was present). 1446's fixture sourced the file
# directly, so it could not see it.
#
# Arms:
#   1 STATIC       each entrypoint calls load_agent_profile after sourcing
#                  lib-common, none names /opt/config-overlay, and the loader's
#                  default path is the Containerfile's COPY target
#   2 BEHAVIOUR    the loader, against a scratch HOME laid out like the image,
#                  exports AGENT_PROFILE and links project-discipline under the
#                  scratch ~/.claude/skills
#   3 LOUD MISS    no profile at the path: a named warning with why and remedy
#                  on stderr, rc 0 (the forge still starts)
#   4 OPTIONS      the profile's own `set -euo pipefail` does not leak into
#                  the entrypoint that loaded it
#   5 NEGATIVE     the pre-fix block, same scratch HOME: nothing exported,
#                  nothing linked, NOTHING printed (the silence this row fixes)
#   6 HOSTILE      from a `set -e` caller (as an entrypoint is), a profile that
#                  fails mid-body, trips -u, or ends on a failure never kills
#                  the caller; the last two print a warning naming the path
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "ok:   $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
LIB="$ROOT/images/default/lib-common.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/entry-profile.XXXXXX")"; trap 'rm -rf "$W"' EXIT INT TERM

# ── ARM 1: STATIC ──────────────────────────────────────────────────────────
target="$(grep -E '^COPY config-overlay/mcp/ ' "$ROOT/images/default/Containerfile" | awk '{print $3}')"
target="${target%/}"
default="$(grep -oE 'HOME:-/home/forge\}/[^}"]*agent-profile\.sh' "$LIB" | head -n 1)"
default="/home/forge/${default#*\}/}"
arm1=ok; why1=""
[ "$default" = "$target/agent-profile.sh" ] || { arm1=bad; why1="loader default '$default' != COPY target '$target/agent-profile.sh'"; }
for a in claude codex opencode-web antigravity; do
    e="$ROOT/images/default/entrypoint-forge-$a.sh"
    lc="$(grep -n 'source /usr/local/lib/tillandsias/lib-common.sh' "$e" | head -n 1 | cut -d: -f1)"
    lp="$(grep -n '^load_agent_profile' "$e" | head -n 1 | cut -d: -f1)"
    if grep -q '/opt/config-overlay' "$e"; then arm1=bad; why1="$why1 $a names /opt/config-overlay;"; fi
    if [ -z "$lp" ] || [ -z "$lc" ] || [ "$lp" -le "$lc" ]; then arm1=bad; why1="$why1 $a: load_agent_profile missing or before lib-common;"; fi
done
[ "$arm1" = ok ] && ok "ARM 1: all four entrypoints call load_agent_profile after lib-common, and its default is the COPY target $target" \
    || bad "ARM 1:$why1"

# The loader, extracted from lib-common (a function, so no container setup runs).
LOADER="$(awk '/^load_agent_profile\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$LIB")"
[ -n "$LOADER" ] || bad "load_agent_profile not found in lib-common.sh"
mkhome() { # mkhome <dir> : a HOME laid out like the image, plus /opt/skills
    mkdir -p "$1/home/.config-overlay/mcp" "$1/opt-skills"
    cp "$ROOT/images/default/config-overlay/mcp/agent-profile.sh" "$1/home/.config-overlay/mcp/"
    cp -R "$ROOT/skills/project-discipline" "$1/opt-skills/"
}

# ── ARM 2: BEHAVIOUR ───────────────────────────────────────────────────────
H="$W/fixed"; mkhome "$H"
out="$(env -i PATH="$PATH" HOME="$H/home" TILLANDSIAS_AGENT=codex TILLANDSIAS_SHARED_SKILLS_ROOT="$H/opt-skills" \
    bash -c "$LOADER"'; load_agent_profile; printf "AGENT_PROFILE=%s\n" "${AGENT_PROFILE:-}"' 2>"$W/err2")"; rc=$?
if [ "$rc" -eq 0 ] && grep -qx 'AGENT_PROFILE=codex' <<<"$out" && [ -L "$H/home/.claude/skills/project-discipline" ] && [ ! -s "$W/err2" ]; then
    ok "ARM 2: against an image-shaped HOME the loader exports AGENT_PROFILE=codex and links ~/.claude/skills/project-discipline, silently"
else
    bad "ARM 2: rc=$rc out='$out' link=$([ -L "$H/home/.claude/skills/project-discipline" ] && echo yes || echo no) err='$(head -c 200 "$W/err2")'"
fi

# ── ARM 3: LOUD MISS ───────────────────────────────────────────────────────
mkdir -p "$W/empty"
out3="$(env -i PATH="$PATH" HOME="$W/empty" bash -c "$LOADER"'; load_agent_profile; echo "rc=$?"' 2>"$W/err3")"
if grep -qx 'rc=0' <<<"$out3" && grep -q 'WARNING: agent profile not found' "$W/err3" \
   && grep -q 'why:' "$W/err3" && grep -q 'remedy:' "$W/err3" && grep -q '1517-p83m' "$W/err3"; then
    ok "ARM 3: a missing profile prints a named warning with why and remedy on stderr, and the forge still starts"
else
    bad "ARM 3: out='$out3' err='$(tr '\n' '|' < "$W/err3")'"
fi

# ── ARM 4: OPTIONS DO NOT LEAK ─────────────────────────────────────────────
out4="$(env -i PATH="$PATH" HOME="$H/home" TILLANDSIAS_SHARED_SKILLS_ROOT="$H/opt-skills" \
    bash -c "$LOADER"'; set +eu; set +o pipefail; load_agent_profile; case $- in *e*|*u*) echo leaked;; *) echo clean;; esac; shopt -qo pipefail && echo leaked-pipefail' 2>/dev/null)"
[ "$out4" = clean ] && ok "ARM 4: the profile's set -euo pipefail does not leak into the entrypoint" \
    || bad "ARM 4: after loading, the shell reports '$out4'"

# ── ARM 5: NEGATIVE CONTROL — the pre-fix block ────────────────────────────
H5="$W/prefix"; mkhome "$H5"
out5="$(env -i PATH="$PATH" HOME="$H5/home" TILLANDSIAS_AGENT=codex TILLANDSIAS_SHARED_SKILLS_ROOT="$H5/opt-skills" \
    bash -c 'if [ -f /opt/config-overlay/mcp/agent-profile.sh ]; then source /opt/config-overlay/mcp/agent-profile.sh; fi; printf "AGENT_PROFILE=%s\n" "${AGENT_PROFILE:-}"' 2>"$W/err5")"
if grep -qx 'AGENT_PROFILE=' <<<"$out5" && [ ! -e "$H5/home/.claude/skills/project-discipline" ] && [ ! -s "$W/err5" ]; then
    ok "ARM 5: negative control — the pre-fix block exports nothing, links nothing and prints NOTHING"
else
    bad "ARM 5: pre-fix block out='$out5' (a host with a real /opt/config-overlay would explain this)"
fi

# ── ARM 6: A FAILING PROFILE NEVER KILLS THE ENTRYPOINT ────────────────────
# The profile opens with set -euo pipefail and had never run in a real forge.
# Sourced bare from a set -e entrypoint, one failing line exits the forge.
arm6=ok; why6=""
for case in 'mid:false; export AGENT_PROFILE=x' 'nounset:echo "$TILLANDSIAS_SURELY_UNSET_1517"' 'last:export AGENT_PROFILE=y; false'; do
    label="${case%%:*}"; body="${case#*:}"
    H6="$W/h6-$label"; mkdir -p "$H6/.config-overlay/mcp"
    printf '#!/usr/bin/env bash\nset -euo pipefail\n%s\n' "$body" > "$H6/.config-overlay/mcp/agent-profile.sh"
    o6="$(env -i PATH="$PATH" HOME="$H6" bash -c "set -e; $LOADER"'; load_agent_profile; echo "survived AGENT_PROFILE=${AGENT_PROFILE:-}"' 2>"$W/err6")"
    grep -q '^survived' <<<"$o6" || { arm6=bad; why6="$why6 $label: the caller died;"; continue; }
    if [ "$label" != mid ]; then
        grep -q "agent profile at $H6/.config-overlay/mcp/agent-profile.sh failed" "$W/err6" \
            || { arm6=bad; why6="$why6 $label: no warning naming the path;"; }
    fi
done
[ "$arm6" = ok ] && ok "ARM 6: a profile failing mid-body, on -u, or at its last line never kills a set -e entrypoint; a failed profile is named on stderr" \
    || bad "ARM 6:$why6"

echo "forge-entrypoints-source-agent-profile: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# freshness: added 2026-08-29 linux-yoga (order 923-rmtw)
# @trace order:923-rmtw, order:801-kqme, order:653-zzkb, spec:proxy-container
#
# check-containers-conf-proxy-env.sh — does this host's containers.conf still
# carry the orphaned `[engine] env` proxy block?
#
# ── THE DEFECT (order 923-rmtw) ──────────────────────────────────────────────
#
# `[engine] env` in ~/.config/containers/containers.conf is injected by Podman
# into EVERY container this user launches, on every network. The block named
# `http_proxy=http://proxy:3128` and a no_proxy allowlist — and `proxy` is an
# alias that resolves only inside the enclave.
#
# Init used to WRITE that block and could never converge it: its guard was
#     content.contains("[engine]") && content.contains("HTTP_PROXY")
# a PRESENCE test. When ENCLAVE_NO_PROXY_BASE gained `nix-cache` (801-kqme,
# 2026-08-17), every host provisioned earlier kept the old list forever. That
# cost four days of phantom 883-ncrs "cache RSTs" — squid CONNECTing for
# https://nix-cache:5000 — plus a broken e2e, and macuahuitl and lenovinha
# repaired theirs BY HAND. This check is why nobody hand-repairs again.
#
# The list was only half the blast radius. The other half is that an unreachable
# http_proxy breaks any container off the enclave regardless of no_proxy, which
# is a documented RECURRING class: the "proxy-exemption class (orders
# 116/118/119, 4th instance 2026-07-11)" in tillandsias-podman/src/client.rs, a
# 5th instance inside the control arm of a p0 security audit (606-9wqd) that was
# filed INCONCLUSIVE while reproducible, scripts/podman-neutralize-proxy.sh
# (653-zzkb) existing solely to undo it, and the nix-builder e2e losing a build
# to `curl: (5) Could not resolve proxy: proxy` on 2026-08-28.
#
# So the canonical compiled state is NO BLOCK: containers get proxy env
# per-container from proxy_env_args() (8 Rust call sites) and, for the one
# launcher that bypasses Rust, from run-forge-project.sh's own --env flags.
# Nothing consumes the global block, which is the measurement that decided
# removal over correcting the list.
#
# ── WHAT THIS COMPARES ───────────────────────────────────────────────────────
#
# DEPLOYED: the [engine] env line in the host's containers.conf, if any.
# COMPILED: read out of crates/tillandsias-headless/src/main.rs — that the
# converger REMOVES the block, and that no writer creates one. Read from source
# rather than restated here, so the next constant change cannot strand this
# check the way it stranded the fleet.
#
# A COMMENTED line counts as present. That is not pedantry: on yoga the block
# was commented out and still satisfied init's presence guard, so the host had
# no proxy env at all while init reported success.
#
# ── GRAMMAR (exactly one line) ───────────────────────────────────────────────
#   ok:containers-conf-proxy-env-absent          converged; nothing to do   (0)
#   drift:containers-conf-proxy-env-present:<n>  the orphaned block is still
#                                                here on <n> line(s) — run
#                                                `tillandsias --init`        (1)
#   drift:compiled-writer-recreates-the-block    THE NEGATIVE CONTROL ON THE
#                                                CODE: something in the init
#                                                path writes an [engine] env
#                                                proxy block again            (1)
#   unavailable:<reason>                         could not determine          (2)
#
# Exit 0 clean, 1 drift, 2 undetermined. ADVISORY — a stale conf is a degraded
# host, not a failed build.
#
# Seams (used by the fixture):
#   TILLANDSIAS_CONTAINERS_CONF   the conf to inspect
#   TILLANDSIAS_HEADLESS_MAIN     the source to read the compiled intent from
#   TILLANDSIAS_SKIP_SOURCE_CHECK set to skip the compiled half (conf-only hosts)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || ROOT="."
CONF="${TILLANDSIAS_CONTAINERS_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/containers/containers.conf}"
MAIN="${TILLANDSIAS_HEADLESS_MAIN:-$ROOT/crates/tillandsias-headless/src/main.rs}"

# Count [engine] env lines naming a proxy variable, commented or not. Section
# tracking matters: a [containers] env is a different key and not ours.
deployed_hits() {
    [ -r "$1" ] || { printf '0\n'; return 0; }
    awk '
        /^[ \t]*\[.*\][ \t]*$/ {
            gsub(/^[ \t]+|[ \t]+$/, "");
            in_engine = ($0 == "[engine]");
            next
        }
        in_engine {
            line = $0
            sub(/^[ \t]*#?[ \t]*/, "", line)
            if (line ~ /^env[ \t]*=/ && (tolower(line) ~ /http_proxy/ || tolower(line) ~ /https_proxy/)) n++
        }
        END { print n + 0 }
    ' "$1" 2>/dev/null || printf '0\n'
}

case "${1:-check}" in
    check)
        if [ ! -e "$CONF" ]; then
            # No file is the canonical state, not an error: init does not create
            # one merely to record an absence.
            echo "ok:containers-conf-proxy-env-absent"
            exit 0
        fi
        if [ ! -r "$CONF" ]; then
            echo "unavailable:containers-conf-unreadable"
            exit 2
        fi

        # THE COMPILED HALF. If some future edit reintroduces a writer, a host
        # can be converged and drift straight back on the next init — so the
        # code is checked too, and its failure is its own token.
        if [ -z "${TILLANDSIAS_SKIP_SOURCE_CHECK:-}" ]; then
            if [ ! -r "$MAIN" ]; then
                echo "unavailable:headless-source-unreadable"
                exit 2
            fi
            writers="$(grep -c 'fn ensure_containers_conf_proxy_env' "$MAIN" 2>/dev/null)"
            case "$writers" in
                '' | 0) ;;
                *)
                    echo "drift:compiled-writer-recreates-the-block"
                    exit 1
                    ;;
            esac
            removers="$(grep -c 'fn ensure_containers_conf_no_proxy_env' "$MAIN" 2>/dev/null)"
            case "$removers" in
                '' | 0)
                    echo "unavailable:no-converger-in-source"
                    exit 2
                    ;;
            esac
        fi

        hits="$(deployed_hits "$CONF")"
        case "$hits" in
            '' | *[!0-9]*) echo "unavailable:containers-conf-unparsable"; exit 2 ;;
            0) echo "ok:containers-conf-proxy-env-absent"; exit 0 ;;
            *) echo "drift:containers-conf-proxy-env-present:$hits"; exit 1 ;;
        esac
        ;;
    fixture)
        _fx_fail=0
        _fx_dir="$(mktemp -d)"
        _fx_self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
        # `env` is required: extra args arrive as VAR=value assignments, and
        # without it the shell tries to EXECUTE the first one (rc=127).
        _run() { TILLANDSIAS_CONTAINERS_CONF="$_fx_dir/conf" env "$@" bash "$_fx_self" check; }
        _expect() {
            _n="$1"; _want="$2"; _rc="$3"; shift 3
            _got="$(_run "$@" 2>/dev/null)"; _grc=$?
            if [ "$_got" = "$_want" ] && [ "$_grc" = "$_rc" ]; then
                echo "ok: $_n ($_got rc=$_grc)"
            else
                echo "FAIL: $_n expected '$_want' rc=$_rc, got '$_got' rc=$_grc"
                _fx_fail=1
            fi
        }

        # 1. THE DEFECT, PINNED: the pre-801-kqme list macuahuitl and lenovinha
        #    hand-repaired — git-service present, nix-cache absent.
        printf '%s\n' '[network]' 'dns_servers = ["1.1.1.1"]' '' '[engine]' \
            'env = ["http_proxy=http://proxy:3128", "no_proxy=localhost,inference,proxy,git-service,tillandsias-git"]' \
            >"$_fx_dir/conf"
        _expect "a-stale-block-is-drift" "drift:containers-conf-proxy-env-present:1" 1

        # 2. MEASURED ON yoga: commented out, and still state. It satisfied
        #    init's old presence guard, so that host had no proxy env at all
        #    while init said it had written one.
        printf '%s\n' '[engine]' \
            '#env = ["http_proxy=http://proxy:3128", "HTTP_PROXY=http://proxy:3128"]' \
            >"$_fx_dir/conf"
        _expect "a-commented-block-is-still-drift" "drift:containers-conf-proxy-env-present:1" 1

        # 3. The converged state.
        printf '%s\n' '[network]' 'dns_servers = ["1.1.1.1"]' 'pasta_options = ["--ipv4-only"]' \
            >"$_fx_dir/conf"
        _expect "a-converged-conf-is-ok" "ok:containers-conf-proxy-env-absent" 0

        # 4. NEGATIVE CONTROL: the check must not fire on config that is not
        #    ours. An [engine] env of the operator's own variables, and a
        #    proxy env under a DIFFERENT section, are both clean.
        printf '%s\n' '[containers]' 'env = ["http_proxy=http://mine:8080"]' '' \
            '[engine]' 'env = ["EDITOR=vim"]' 'runtime = "crun"' >"$_fx_dir/conf"
        _expect "another-sections-env-and-a-non-proxy-engine-env-are-clean" \
            "ok:containers-conf-proxy-env-absent" 0

        # 5. No file at all is the canonical state, not a failure.
        rm -f "$_fx_dir/conf"
        _expect "an-absent-conf-is-ok" "ok:containers-conf-proxy-env-absent" 0

        # 6. THE COMPILED NEGATIVE CONTROL. A source that still defines the
        #    create-only writer means a converged host drifts back on the next
        #    init, so it is drift even when the deployed file is clean — and it
        #    gets its OWN token, because the remedy is a code change, not
        #    `tillandsias --init`.
        printf '%s\n' '[network]' 'dns_servers = ["1.1.1.1"]' >"$_fx_dir/conf"
        printf '%s\n' 'fn ensure_containers_conf_proxy_env(path: &Path) {}' >"$_fx_dir/main.rs"
        _expect "a-reintroduced-writer-is-its-own-drift" \
            "drift:compiled-writer-recreates-the-block" 1 \
            TILLANDSIAS_HEADLESS_MAIN="$_fx_dir/main.rs"

        # 7. A source with NEITHER writer nor converger cannot be ruled on.
        printf '%s\n' 'fn something_else() {}' >"$_fx_dir/main.rs"
        _expect "a-source-with-no-converger-is-unavailable" \
            "unavailable:no-converger-in-source" 2 \
            TILLANDSIAS_HEADLESS_MAIN="$_fx_dir/main.rs"

        # 8. THE REAL SOURCE honours the contract. Without this the fixture is
        #    talking to itself: the shipped code must carry the converger and
        #    must NOT carry the old writer.
        _real="$ROOT/crates/tillandsias-headless/src/main.rs"
        if grep -q 'fn ensure_containers_conf_no_proxy_env' "$_real" 2>/dev/null \
           && ! grep -q 'fn ensure_containers_conf_proxy_env' "$_real" 2>/dev/null; then
            echo "ok: the-shipped-init-path-converges-and-does-not-recreate"
        else
            echo "FAIL: $_real must define the converger and not the create-only writer"
            _fx_fail=1
        fi

        # 9. Grammar: exactly one well-formed line.
        printf '%s\n' '[engine]' 'env = ["http_proxy=http://proxy:3128"]' >"$_fx_dir/conf"
        _lines="$(_run 2>/dev/null | grep -cE '^(ok:containers-conf-proxy-env-absent|drift:containers-conf-proxy-env-present:[0-9]+|drift:compiled-writer-recreates-the-block|unavailable:[a-z-]+)$')"
        if [ "$_lines" = "1" ]; then
            echo "ok: grammar-exactly-one-line"
        else
            echo "FAIL: grammar expected 1 well-formed line, got $_lines"
            _fx_fail=1
        fi

        rm -rf "$_fx_dir"
        [ "$_fx_fail" = 0 ] && echo "ok:containers-conf-proxy-env-fixture:9"
        exit "$_fx_fail"
        ;;
    *)
        echo "usage: check-containers-conf-proxy-env.sh [check|fixture]" >&2
        exit 2
        ;;
esac

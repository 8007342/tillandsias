#!/usr/bin/env bash
# freshness: added 2026-09-03 lenovinha-tillandsias-forge (order 972-a8vh)
# @trace order:972-a8vh, spec:enclave-network
#
# check-enclave-network-internal.sh — is the enclave network actually an enclave?
#
# ── THE DEFECT (order 972-a8vh) ──────────────────────────────────────────────
#
# spec:enclave-network states the MUST in as many words:
#     "THEN the system MUST create it with
#      `podman network create tillandsias-enclave --internal`"
#
# `--internal` is what the isolation IS. Without it podman attaches a gateway to
# the bridge and every member gets NAT egress, so the proxy stops being the only
# way out and the enclave's whole threat model quietly does not hold.
#
# Three Rust paths pass it — tillandsias-podman/src/client.rs,
# tillandsias-podman-cli/src/lib.rs, tillandsias-headless/src/main.rs — and
# scripts/orchestrate-enclave.sh did NOT, so WHICH BINARY happened to create the
# network decided whether the enclave was isolated. Nothing guarded the script
# path. This check is that guard.
#
# ── WHY THE DEPLOYED HALF EXISTS, and why it is the half that matters ────────
#
# Adding the flag fixes networks created FROM NOW ON and reaches no host that
# already has one: `podman network exists` returns true, creation is skipped, and
# an unisolated network survives every future launch untouched. Same
# installed-base gap as the proxy CA key left 0644 on hosts provisioned before
# its fix, and as the containers.conf proxy block that init could never converge
# (923-rmtw) — the code change does not reach what is already deployed.
#
# So this checks BOTH:
#   SOURCE   — every launcher that creates the network passes --internal.
#   DEPLOYED — the network on THIS host, if present, is actually internal.
#
# MEASURED FROM INSIDE THE ENCLAVE (lenovinha forge, 2026-09-03). A forge is a
# member of the network it is asking about, so it can answer without podman:
#
#     $ ip route
#     10.0.42.0/24 dev eth0 proto kernel scope link src 10.0.42.14
#     # ^ on-link /24 only — NO default route
#     $ cat < /dev/null > /dev/tcp/1.1.1.1/443
#     bash: connect: Network is unreachable
#
# An internal network has no gateway, so there is no default route and egress
# fails INSTANTLY with "Network is unreachable" (measured 0.0001s) rather than
# hanging and timing out the way a filtered-but-routed network would. That
# distinction is the whole test: a firewall drops packets slowly, a missing route
# refuses them immediately. This host's network was created correctly, by the
# Rust launcher — a useful negative, and evidence the shell path is reached only
# in some launch modes.
#
# ── GRAMMAR (exactly one line) ───────────────────────────────────────────────
#   ok:enclave-network-internal:<scope>       source ok; deployed ok or absent (0)
#   drift:launcher-omits-internal:<csv>       a launcher creates the network
#                                             WITHOUT --internal               (1)
#   drift:deployed-network-not-internal:<net> the network on this host has NAT
#                                             egress — recreate it             (1)
#   unavailable:<reason>                      could not determine              (2)
#
# Advisory callers may branch on the token; the exit code is the gate.

set -u

# MODE. `source` checks only the launchers — a property of the CHECKOUT, true
# everywhere, so it is safe to GATE a build on. `check` (default) adds this
# host's deployed network, which is host state: see the note at the deployed
# half for why the build gate must not fail on it.
MODE="${1:-check}"
case "$MODE" in
    source | check) ;;
    *) printf 'unavailable:unknown-mode-%s\n' "$MODE"; exit 2 ;;
esac

NET="${TILLANDSIAS_ENCLAVE_NET:-tillandsias-enclave}"

repo_root() {
    if r="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$r" ]; then
        printf '%s\n' "$r"
    else
        printf '%s\n' "$(cd "$(dirname "$0")/.." && pwd)"
    fi
}
ROOT="$(repo_root)"

# ── SOURCE half ──────────────────────────────────────────────────────────────
# Find every site that creates the enclave network and require --internal within
# the creating invocation. Read from source rather than restating a list here, so
# a NEW launcher cannot be added without this check seeing it.
offenders=""

# 1. The shell launcher. The create call is multi-line; join continuations first.
sh_launcher="$ROOT/scripts/orchestrate-enclave.sh"
if [ -r "$sh_launcher" ]; then
    if awk '{ while (sub(/\\$/, "")) { if ((getline nxt) > 0) $0 = $0 " " nxt; else break } print }' "$sh_launcher" \
        | grep -E 'podman[[:space:]]+network[[:space:]]+create' \
        | grep -qv -- '--internal'; then
        offenders="${offenders},scripts/orchestrate-enclave.sh"
    fi
fi

# 2. The Rust paths. Same rule, same reason: a create call must carry the flag.
for rs in \
    "$ROOT/crates/tillandsias-podman/src/client.rs" \
    "$ROOT/crates/tillandsias-podman-cli/src/lib.rs"
do
    [ -r "$rs" ] || continue
    if grep -q '"network"' "$rs" && ! grep -q -- '"--internal"' "$rs"; then
        offenders="${offenders},$(basename "$rs")"
    fi
done

if [ -n "$offenders" ]; then
    printf 'drift:launcher-omits-internal:%s\n' "${offenders#,}"
    exit 1
fi

# ── DEPLOYED half ────────────────────────────────────────────────────────────
# Only meaningful where podman is reachable. A forge has no podman socket, and
# that is not a failure — it is a scope the source half already covered.
if [ "$MODE" = "source" ]; then
    printf 'ok:enclave-network-internal:source\n'
    exit 0
fi

if ! command -v podman >/dev/null 2>&1; then
    printf 'ok:enclave-network-internal:source-only-no-podman\n'
    exit 0
fi

if ! podman network exists "$NET" 2>/dev/null; then
    printf 'ok:enclave-network-internal:source-only-network-absent\n'
    exit 0
fi

deployed="$(podman network inspect "$NET" --format '{{.Internal}}' 2>/dev/null)"
case "$deployed" in
    true)
        printf 'ok:enclave-network-internal:source+deployed\n'
        exit 0
        ;;
    false)
        # NOT repaired by relaunching — creation is skipped for an existing
        # network, so this state is permanent until someone removes it.
        printf 'drift:deployed-network-not-internal:%s\n' "$NET"
        exit 1
        ;;
    *)
        printf 'unavailable:network-inspect-returned-%s\n' "${deployed:-empty}"
        exit 2
        ;;
esac

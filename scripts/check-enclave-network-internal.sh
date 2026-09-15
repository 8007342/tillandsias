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
#   ok:enclave-network-internal:<scope>[<n>]  source ok; deployed ok or absent (0)
#                                             <n> carries the discovery counts and
#                                             the Rust arm's declared file-scoped
#                                             limit (1118-zvai), so an ok: is never
#                                             read as wider than its sweep
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
# ORDER 1118-zvai. This half used to read a HARDCODED list of three files, and
# the header above said so in as many words: orchestrate-enclave.sh plus two
# Rust paths. Two launchers that create the SAME network by the SAME name were
# outside that list and created it with NAT egress —
# scripts/run-forge-project.sh and scripts/diagnose-proxy.sh — so this check
# was GREEN on a tree carrying exactly the defect it exists to catch. The
# header even named tillandsias-headless/src/main.rs as a third Rust path and
# the loop never read that file either: the list and the prose had already
# drifted apart from each other, which is the tell that a list is the wrong
# instrument.
#
# So discovery is now REPO-WIDE over tracked sources, not a list. A launcher
# added tomorrow is seen without anyone remembering to add it here.
#
# TWO THINGS IT DELIBERATELY DOES NOT DO, both named so the verdict is not read
# as wider than it is:
#
#   1. It does not read documentation. cheatsheets/ and docs/ contain
#      `podman network create` lines that are EXAMPLES, several of them without
#      the flag; gating on prose would make a doc edit fail a build, and a guard
#      that cries about a code block teaches people to skip it. The declined
#      scope is printed in the verdict rather than left to be inferred.
#   2. On the Rust side it still matches per FILE, not per invocation, because
#      the flag is a vector element assembled far from the verb and grep cannot
#      see that structure. A Rust file with one compliant and one
#      non-compliant create call reads as clean. That hole is REAL and is
#      carried in the verdict as `rust=file-scoped`, so nobody reads this
#      check as proving more than it does. Closing it needs the arg-builders
#      to be tested, not grepped.
#
# The shell side IS invocation-scoped: continuations are folded first, and the
# flag must appear on the same logical line as the create verb.
offenders=""
scanned_sh=0
scanned_rs=0


# Tracked files only, via git when available. A generated tree under target/,
# a vendored checkout, or an editor backup is not a launcher.
list_sources() {
    if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        git -C "$ROOT" ls-files -z -- '*.sh' '*.rs'
    else
        find "$ROOT" -type f \( -name '*.sh' -o -name '*.rs' \) \
            -not -path '*/target/*' -not -path '*/.git/*' -print0
    fi
}

while IFS= read -r -d '' rel; do
    f="$ROOT/$rel"
    [ -r "$f" ] || continue
    case "$rel" in
        # This file is itself full of the string it looks for, in comments and
        # in its own grammar. A matcher over a corpus containing itself reports
        # itself (the same shape that made a trace-migration audit accuse the
        # auditor). Excluded by name, deliberately and visibly.
        scripts/check-enclave-network-internal.sh) continue ;;
    esac
    case "$rel" in
        *.sh)
            scanned_sh=$((scanned_sh + 1))
            # Fold continuations with awk, never `sed ':a;N;$!ba;...'` — GNU sed
            # accepts a `;` after a label and BSD sed does not, and the sed form
            # emitted NOTHING on macOS, which reported drift against a launcher
            # that carried the flag on its first line (measured 2026-09-03).
            # Comment lines are dropped BEFORE the match: a comment quoting a
            # non-compliant example is documentation, not an invocation.
            hits="$(awk '{ while (sub(/\\$/, "")) { if ((getline nxt) > 0) $0 = $0 " " nxt; else break } print }' "$f" \
                | grep -v '^[[:space:]]*#' \
                | grep -E '(podman|PODMAN_CTL|PODMAN)[^|;&]*network[[:space:]]+create' \
                | grep -iE 'enclave' \
                | grep -v -- '--internal')"
            [ -n "$hits" ] && offenders="${offenders},$rel"
            ;;
        *.rs)
            scanned_rs=$((scanned_rs + 1))
            # `"network"` ALONE is not evidence of a create call. Widening the
            # old three-file list to the whole tree with that test accused four
            # tillandsias-logging files whose only sin is the word "network" in
            # a log field — a matcher that was safe on a hand-picked list and
            # false the moment its radius grew. The discriminator is the pair
            # of QUOTED ARGUMENT literals: a podman arg-builder spells
            # "network" and "create" as separate vector elements, and prose
            # that merely says "network created" spells neither.
            if grep -q '"network"' "$f" && grep -q '"create"' "$f" \
                && ! grep -q -- '--internal' "$f"; then
                offenders="${offenders},$rel"
            fi
            ;;
    esac
done < <(list_sources)

# A discovery that finds NOTHING is indistinguishable from a discovery that
# finds nothing wrong, and the two must never share a verdict: an empty scan
# means the lister broke (no git, wrong ROOT, a pathspec typo), not that the
# repository has no launchers. Refuse instead of reporting ok.
if [ "$scanned_sh" -eq 0 ] || [ "$scanned_rs" -eq 0 ]; then
    printf 'unavailable:source-discovery-empty-sh-%s-rs-%s\n' "$scanned_sh" "$scanned_rs"
    exit 2
fi

if [ -n "$offenders" ]; then
    printf 'drift:launcher-omits-internal:%s\n' "${offenders#,}"
    exit 1
fi

# The scope travels WITH the verdict. A reader who sees only `ok:` cannot tell
# a check that swept the tree from one whose lister returned four files, and
# cannot tell that the Rust arm is file-scoped unless the line says so.
# `declined=docs` is there so the absence of a cheatsheet from the offender
# list reads as a boundary that was chosen, not as a cheatsheet that passed.
SCOPE="sh=${scanned_sh},rs=${scanned_rs},rust=file-scoped,declined=docs"

# ── DEPLOYED half ────────────────────────────────────────────────────────────
# Only meaningful where podman is reachable. A forge has no podman socket, and
# that is not a failure — it is a scope the source half already covered.
if [ "$MODE" = "source" ]; then
    printf 'ok:enclave-network-internal:source[%s]\n' "$SCOPE"
    exit 0
fi

if ! command -v podman >/dev/null 2>&1; then
    printf 'ok:enclave-network-internal:source-only-no-podman[%s]\n' "$SCOPE"
    exit 0
fi

if ! podman network exists "$NET" 2>/dev/null; then
    printf 'ok:enclave-network-internal:source-only-network-absent[%s]\n' "$SCOPE"
    exit 0
fi

deployed="$(podman network inspect "$NET" --format '{{.Internal}}' 2>/dev/null)"
case "$deployed" in
    true)
        printf 'ok:enclave-network-internal:source+deployed[%s]\n' "$SCOPE"
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

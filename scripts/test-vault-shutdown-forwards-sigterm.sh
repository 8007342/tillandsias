#!/usr/bin/env bash
# @trace order:1134-u934, order:1140-i6ct, spec:tillandsias-vault
#
# test-vault-shutdown-forwards-sigterm.sh — the closure 1134-u934 named.
#
# WHAT IT ASSERTS, against a LIVE container rather than against the script's
# text: `podman stop -t <grace> <container>` returns in well under the grace
# AND the container's ExitCode is 0. Both halves matter and neither one alone
# is the bug:
#
#   * elapsed alone would pass a container that exits fast for a bad reason;
#   * ExitCode alone would pass a container that takes the full grace and is
#     then reported 0 by some future podman.
#
# WHY NOT A UNIT TEST OF THE SCRIPT. The defect 1134-u934 filed was a PID-1
# shell that traps nothing, plus `$!` after a backgrounded PIPELINE holding
# TEE's pid instead of vault's. Both are properties of the PROCESS TREE at
# runtime; a text fixture that greps for `trap` would have passed the wrong
# fix — a trap forwarding to tee — which is the exact trap the packet warned
# about ("worse than no trap, because it looks fixed").
#
# ── ORDER 1140-i6ct: WHICH ENTRYPOINT DID WE JUST MEASURE? ──────────────────
#
# MEASURED ON YOGA 2026-09-13, minutes after the fix landed and before that
# host rebuilt: this fixture printed "FAIL: vault's shutdown path is the
# 1134-u934 defect" with the fix present in the source tree. The verdict was
# FALSE ABOUT THE SOURCE and TRUE ABOUT THE HOST — yoga's image was built 23
# hours before the fix existed, and the running container was that image.
#
# The class, which is why this is handled and not commented: a fixture that
# measures a DEPLOYED artifact while living in the repository that DEFINES it
# disagrees with its own tree for the whole interval between a fix landing and
# that host rebuilding, and the disagreement is indistinguishable from the
# defect it was written to catch. After 1134-u934 that interval covers EVERY
# installed host until the next daily is cut, because the tray embeds its own
# copy of the image sources.
#
# So a red measurement is attributed before it is reported, by comparing what
# the IMAGE carries against what the TREE carries — the entrypoint bytes the
# container actually runs, hashed, against images/vault/entrypoint.sh here.
# Bytes rather than build timestamps or a git HEAD: a timestamp compares two
# clocks, and HEAD would pass on a host that never rebuilt, which is exactly
# the case this handles.
#
# THE ATTRIBUTION NEVER SHORT-CIRCUITS THE MEASUREMENT, and that is the whole
# discipline of it. The stop ALWAYS runs. The comparison only decides how to
# READ a red one. A vintage check consulted BEFORE measuring would make this
# fixture unable to fail at all — strictly worse than the defect it fixes —
# so a container running THIS TREE's entrypoint that stalls still FAILS.
#
# FOUR OUTCOMES, FOUR EXIT CODES, because a verdict that is only prose is a
# verdict no caller can branch on:
#   0  pass         — stopped inside the budget with exit 0
#   1  FAIL         — stalled or exited non-zero, running THIS TREE's entrypoint
#   3  could-not-run — no podman, no container, would not start, never healthy,
#                      or a red we could not attribute to an entrypoint
#   4  stale-image   — red, but the container is running a DIFFERENT entrypoint
#                      than this tree's; the host is behind, the source is not
#                      indicted
#
# Exit 3 is the 923-ws3r could-not-run channel, as used by
# archive-plan-packets.sh: a host with no provisioned enclave gets a stable
# token rather than ok: printed over an assertion that never executed (the
# 1024-c3h3 could-not-run-reported-as-clean shape).
#
# KEY ON THE TOKEN, NOT THE INTEGER. `could-not-run:stale-image (1140-i6ct)`
# is the stable contract; 4 is this script's local spelling of it. There is no
# shared exit-code table in this tree, so each script owns its own grammar —
# and 4 is spoken elsewhere with the OPPOSITE sense: measured by yoga across
# 15 sites, check-resumable-claim-dirt.sh:34 documents "4 — ok:clean-tree" and
# check-opsx-generated-dirt.sh:28 "4 — ok-with-clean-tree", both GOOD outcomes.
# A caller that branches on the number will therefore read a stale image as a
# clean tree the moment it is pointed at a sibling script. The number is not
# renumbered here on purpose: four DISTINGUISHABLE codes is 1140-i6ct's own
# exit criterion, and collapsing two of them to dodge a collision that only
# exists across files would trade a naming clash for the defect the row fixes.
#
# The classifier is sourceable for its hermetic negative control — see
# scripts/test-vault-shutdown-fixture-classifier.sh, which is the guard that
# keeps all four outcomes reachable and keeps a real regression failing.
set -uo pipefail

# ── The classifier, deliberately pure: no podman, no clock, no filesystem ───
# args: elapsed budget exit_code entrypoint_verdict(match|differs|unknown)
# Prints the verdict line; returns this script's exit code.
vault_shutdown_classify() {
    local elapsed="$1" budget="$2" exit_code="$3" entrypoint="$4"
    local stalled=0 bad_exit=0

    [ "$elapsed" -ge "$budget" ] && stalled=1
    [ "$exit_code" != "0" ] && bad_exit=1

    if [ "$stalled" -eq 0 ] && [ "$bad_exit" -eq 0 ]; then
        if [ "$entrypoint" = "differs" ]; then
            # A GREEN is still a green — it is a fact about the container that
            # was measured. Say whose entrypoint earned it, so nobody reads it
            # as this tree passing.
            echo "ok: stopped in ${elapsed}s (< ${budget}s) with exit 0 — NOTE: the container is not running this tree's entrypoint, so this passes the IMAGE, not the checkout"
        else
            echo "ok: stopped in ${elapsed}s (< ${budget}s) with exit 0 — SIGTERM is forwarded"
        fi
        return 0
    fi

    # From here the measurement is RED. What it means depends on what ran.
    if [ "$stalled" -eq 1 ]; then
        echo "measured: stop took ${elapsed}s, at or over the ${budget}s budget — SIGTERM did not reach the server"
    fi
    if [ "$bad_exit" -eq 1 ]; then
        if [ "$exit_code" = "137" ]; then
            echo "measured: ExitCode 137 — the container was SIGKILLed at the end of its grace"
        else
            echo "measured: ExitCode $exit_code, want 0"
        fi
    fi

    case "$entrypoint" in
        differs)
            echo "could-not-run:stale-image (1140-i6ct) — the container runs a DIFFERENT entrypoint than images/vault/entrypoint.sh in this checkout, so this red is about the IMAGE, not the source. Rebuild the vault image and re-run; do not file it as 1134-u934."
            return 4
            ;;
        unknown)
            echo "could-not-run:cannot-attribute (1140-i6ct) — the measurement is red but the container's entrypoint could not be read, so it cannot be attributed to this tree or to a stale image. 965-sxec: a check that could not evaluate the thing it names does not get to report a verdict about it."
            return 3
            ;;
        *)
            echo "FAIL: the container runs THIS TREE's entrypoint and still did not stop cleanly — the 1134-u934 defect (1134-u934)"
            return 1
            ;;
    esac
}

# Sourced for the hermetic control: define and stop. Nothing below runs.
if [ -n "${TILLANDSIAS_VAULT_FIXTURE_LIB:-}" ]; then
    return 0 2>/dev/null || exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

CONTAINER="${TILLANDSIAS_VAULT_CONTAINER:-tillandsias-vault}"
GRACE="${TILLANDSIAS_VAULT_STOP_GRACE:-30}"
TREE_ENTRYPOINT="${TILLANDSIAS_VAULT_ENTRYPOINT:-images/vault/entrypoint.sh}"
# The bar. A forwarded SIGTERM lets vault seal and exit in about a second; the
# unfixed path takes the whole grace. Half the grace separates those two
# regimes by a wide margin without pinning a number this host's speed sets.
BUDGET=$(( GRACE / 2 ))

command -v podman >/dev/null 2>&1 || {
    echo "could-not-run:no-podman (1134-u934)"; exit 3; }

podman container exists "$CONTAINER" 2>/dev/null || {
    echo "could-not-run:no-vault-container:$CONTAINER (1134-u934) — run \`tillandsias --init\` first"; exit 3; }

WAS_RUNNING=0
if [ "$(podman inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null)" = "true" ]; then
    WAS_RUNNING=1
else
    echo "test: $CONTAINER is not running — starting it for the measurement"
    podman start "$CONTAINER" >/dev/null 2>&1 || {
        echo "could-not-run:vault-would-not-start (1134-u934)"; exit 3; }
fi

# Let it reach the state whose shutdown is under test. An unsealed, serving
# vault is the case the packet measured; stopping one that is still booting
# measures the boot path instead.
i=0
until [ "$(podman inspect "$CONTAINER" --format '{{.State.Health.Status}}' 2>/dev/null)" = "healthy" ]; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
        echo "could-not-run:vault-never-became-healthy-in-60s (1134-u934)"
        [ "$WAS_RUNNING" -eq 1 ] || podman stop -t 5 "$CONTAINER" >/dev/null 2>&1
        exit 3
    fi
    sleep 1
done

# ── Attribution, read BEFORE the stop because it needs a running container ──
# Read, not judged: the comparison is made, the verdict is not consulted until
# there is a red measurement to read.
ENTRYPOINT_VERDICT=unknown
_tree_hash=""; _image_hash=""
if [ -r "$TREE_ENTRYPOINT" ]; then
    _tree_hash="$(sha256sum < "$TREE_ENTRYPOINT" 2>/dev/null | cut -d' ' -f1)"
fi
# HASHED ON THE HOST, ALWAYS. The only thing asked of the container is that it
# hand over bytes — never that it compute anything. yoga measured why while
# producing the baseline for this row: `podman exec tillandsias-vault
# /usr/bin/grep ...` fails with "crun: executable file `/usr/bin/grep` not
# found", because the hashicorp/vault base is minimal and does not ship it.
# sha256sum happens to be present TODAY, which is luck rather than a property
# anyone checked. Running the digest inside the container would therefore exit
# non-zero on any image that drops the tool, and — this is the part that
# matters — that failure would read as `cannot-attribute` on precisely the
# host where the comparison is the thing needed.
#
# `podman cp` first, which asks the image for NOTHING: it reads the layer from
# the host side, so an image with no shell and no coreutils still answers. It
# is tried first for that reason and not merely as a fallback. `cat` is the
# second arm, for a podman too old for `cp` on a running container.
#
# THE STREAM FORM IS REJECTED, and this is the paragraph to read before
# "simplifying" the mktemp away. `podman cp <ctr>:<path> -` writes a TAR to
# stdout, so hashing it hashes the header too. MEASURED on yoga against the
# same container that produced the file digest below:
#
#   podman cp <ctr>:<path> - | sha256sum   -> 2b077df6896b
#   the same command, again                -> 2b077df6896b
#   tar -tvf -  ->  -rwxr-xr-x 101/0 10518 2026-09-11 19:00 tillandsias-vault-entrypoint.sh
#
# The digest is not the file's (e1d17131198a), and the header carries the
# image's BUILD TIME. So the stream form compares timestamps and would report
# `differs` for two byte-identical entrypoints — this row's own defect, one
# layer down.
#
# AND ONE DEGREE QUIETER, which is the part that makes it dangerous rather
# than merely wrong: the stream digest is STABLE across repeated runs on one
# host. A developer testing locally sees a reproducible number, concludes the
# mechanism is sound, and only discovers otherwise when comparing two hosts or
# two builds of identical content. It is silent exactly where it would be
# tested and loud only in production — the same shape as the row itself, an
# instrument that disagrees with reality only in the interval nobody
# exercises.
#
# THAT PREDICTION WAS THEN MEASURED ACROSS THE TWO HOSTS, which is the only
# place it is visible at all. Same file, byte-identical, e1d17131198a on both:
#
#   yoga    stream digest 2b077df6896b   tar header mtime 2026-09-11 19:00
#   pirria  stream digest 5b5735e0808b   tar header mtime 2026-09-12 03:29
#
# Two hosts, two reproducible-looking numbers, one identical file. Each host
# would have been satisfied by its own repeatability. The stream form does not
# compare entrypoints; it compares when each host happened to build its image.
_image_hash=""
_cp_dir="$(mktemp -d 2>/dev/null)"
if [ -n "$_cp_dir" ]; then
    if podman cp "$CONTAINER:/usr/local/bin/tillandsias-vault-entrypoint.sh" \
            "$_cp_dir/entrypoint.sh" >/dev/null 2>&1 \
       && [ -s "$_cp_dir/entrypoint.sh" ]; then
        _image_hash="$(sha256sum < "$_cp_dir/entrypoint.sh" 2>/dev/null | cut -d' ' -f1)"
    fi
    rm -rf "$_cp_dir"
fi
if [ -z "$_image_hash" ]; then
    _image_hash="$(podman exec "$CONTAINER" cat /usr/local/bin/tillandsias-vault-entrypoint.sh 2>/dev/null \
        | sha256sum 2>/dev/null | cut -d' ' -f1)"
fi
# `cat | sha256sum` of a MISSING file yields the hash of the empty string, which
# would silently become a "differs" verdict on a container where exec is broken.
# Pin that case to unknown by requiring a non-empty file.
_empty_sha="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
if [ -n "$_tree_hash" ] && [ -n "$_image_hash" ] \
   && [ "$_image_hash" != "$_empty_sha" ]; then
    if [ "$_tree_hash" = "$_image_hash" ]; then
        ENTRYPOINT_VERDICT=match
    else
        ENTRYPOINT_VERDICT=differs
    fi
fi
echo "entrypoint: container=${_image_hash:0:12} tree=${_tree_hash:0:12} -> $ENTRYPOINT_VERDICT"

echo "test: stopping $CONTAINER with -t $GRACE (budget: under ${BUDGET}s, exit 0)"
_t0="$(date +%s)"
podman stop -t "$GRACE" "$CONTAINER" >/dev/null 2>&1
_t1="$(date +%s)"
ELAPSED=$(( _t1 - _t0 ))

EXIT_CODE="$(podman inspect "$CONTAINER" --format '{{.State.ExitCode}}' 2>/dev/null)"
OOM="$(podman inspect "$CONTAINER" --format '{{.State.OOMKilled}}' 2>/dev/null)"
echo "measured: elapsed=${ELAPSED}s exit_code=${EXIT_CODE} oom_killed=${OOM} grace=${GRACE}s"

# Put the host back the way it was found. This runs before the verdict on
# purpose: a red assertion must not also leave the enclave down.
if [ "$WAS_RUNNING" -eq 1 ]; then
    podman start "$CONTAINER" >/dev/null 2>&1 || \
        echo "warn: could not restart $CONTAINER after the measurement" >&2
fi

vault_shutdown_classify "$ELAPSED" "$BUDGET" "${EXIT_CODE:-unreadable}" "$ENTRYPOINT_VERDICT"

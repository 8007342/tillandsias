#!/usr/bin/env bash
# @trace order:1027-539s, order:998-qrwu
#
# check-state-root-literals.sh — the state ROOT may be declared once and derived
# everywhere else. This counts RUST literals of it outside the declaration and
# its readers, and refuses a rise.
#
# ── WHY THIS IS A NEW GUARD AND NOT A WIDENING ─────────────────────────────
#
# scripts/check-ca-path-literals.sh counts the PRE-migration /tmp path (that
# script names the literal; this one deliberately does not restate it, because
# restating a single-sourced string in prose is the defect both guards exist to
# stop — and it trips that guard, which is how this line was found).
# It has never watched the post-migration CA path and never
# watched the root. So there was no coverage here to extend: 1019-ivia's
# duplicate root literal did not slip past a guard, it walked through a gap.
#
# ── TWO CONCEPTS THAT ARE THE SAME STRING ON A DEFAULT LINUX HOST ──────────
#
# This guard watches exactly ONE of them, and getting that wrong is worse than
# having no guard at all.
#
#   A — THE XDG STATE DIR. Platform-idiomatic, honours XDG_STATE_HOME,
#       deliberately ~/Library/Logs on macOS. THESE SITES ARE CORRECT and are
#       NOT this guard's subject:
#         crates/tillandsias-core/src/config.rs   (log_dir/state_dir, 3 platform arms)
#         crates/tillandsias-logging/src/event_collector.rs (reads XDG_STATE_HOME)
#         scripts/uninstall.sh                    (six-variable platform table)
#         scripts/build-image.sh                  (telemetry dir, XDG_STATE_HOME branch)
#
#   B — THE MANIFEST ROOT, declared in images/default/ca-path.txt. HOME-relative
#       BY MEASUREMENT (998-3z6g), because it must be byte-identical on a
#       rootless host and inside the guest where HOME=/root. THIS is the subject.
#
# MAKING A AGREE WITH B IS A BUG, NOT A CLEANUP. Pointing uninstall.sh's LOG_DIR
# at the manifest root would delete ~/.local/state on a Mac and leave
# ~/Library/Logs behind — an uninstall that silently fails to uninstall, on the
# platform where the divergence is deliberate. A string-keyed guard cannot tell A
# from B, so this one is scoped to RUST under crates/ and says so rather than
# counting shell sites it would only mislead someone into "fixing".
#
# ── SCOPE, STATED SO NOBODY READS IT AS MORE ───────────────────────────────
#
# Rust sources under crates/, EXCLUDING the declaration's readers. Shell
# constructions and the config.rs platform divergence are OUT OF SCOPE and are
# concept A. A green verdict here means "no new Rust literal of the manifest
# root", not "the root is declared once everywhere".
#
# THE ACCIDENTAL TEST (yoga, 2026-09-04): guest_bin_path.rs must NOT need an
# exemption. It derives its root from the manifest via ca_path::state_root_
# expanded, so a literal there would mean the derivation was abandoned. If a
# future edit adds it to the exemption list, that is the signal the change is
# wrong — not that the list was too short.
#
# COUNT OCCURRENCES, NOT LINES, and say which. check-ca-path-literals.sh records
# the scar: its first baseline was a line count (36), it refused on its own first
# run at 37, and the true occurrence count was 38 — three numbers for one
# quantity, from choosing the convenient unit.
#
# Verdict grammar (single line, falsifiable):
#   ok:state-root-literals:<n> of <baseline>
#   violation:state-root-literals-grew:<n> of <baseline>
# Exit 0 on ok, 1 on violation.
set -euo pipefail

BASELINE="${TILLANDSIAS_STATE_ROOT_LITERAL_BASELINE:-0}"

# CODE ONLY, and excluding prose is deliberate rather than lazy.
#
# Counting doc comments too was this guard's first version and it baselined at 4
# — all four legitimate prose, and TWO of them describing concept A rather than
# this root. A baseline of 4 then goes GREEN on a commit that adds a real
# declaration while deleting a doc comment, which is exactly the defect the
# guard exists to catch. A number that moves for reasons unrelated to its
# subject is worse than no number.
#
# Stale prose copies are a real problem and are NOT this guard's job.
#
# Occurrences, not lines, and this says which — see the scar in
# check-ca-path-literals.sh's header.
count="$(grep -rn '\.local/state/tillandsias' \
            --include='*.rs' \
            --exclude=ca_path.rs \
            --exclude=config.rs \
            --exclude=event_collector.rs \
            crates/ 2>/dev/null \
          | grep -vE ':[[:space:]]*(///|//!|//|\*)' \
          | grep -o '\.local/state/tillandsias' | wc -l | tr -d ' ' || true)"
# The `|| true` is LOAD-BEARING under `set -euo pipefail`: grep exits 1 when it
# finds nothing, which here is the SUCCESS case. Without it this guard dies at
# exit 1 and prints no verdict — failing silently exactly when the tree is
# clean, which is the worst possible direction for a guard to fail. Measured
# while writing it.

if [ "$count" -gt "$BASELINE" ]; then
    echo "violation:state-root-literals-grew:$count of $BASELINE"
    {
        echo ""
        echo "  A new Rust literal of the state root was added. The root is DECLARED in"
        echo "  images/default/ca-path.txt and every consumer must DERIVE from it:"
        echo "      tillandsias_core::ca_path::state_root_expanded(&home)"
        echo "  A second literal is 998-qrwu's defect returning — that packet removed 38"
        echo "  copies of one path, and 1019-ivia reintroduced the root at N=2."
        echo ""
        echo "  If your site is the XDG STATE DIR (platform-idiomatic, honours"
        echo "  XDG_STATE_HOME, ~/Library/Logs on macOS) it is a DIFFERENT CONCEPT that"
        echo "  merely coincides on a default Linux host. Do not point it at the"
        echo "  manifest root — see this script's header for why that breaks macOS."
    } >&2
    exit 1
fi

echo "ok:state-root-literals:$count of $BASELINE"

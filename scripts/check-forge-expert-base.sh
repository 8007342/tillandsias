#!/bin/sh
# freshness: refreshed 2026-07-30 linux-mutable-macuahuitl-opus5-20260730
# @trace spec:meta-orchestration
# check-forge-expert-base.sh: executable Forge Expert Base Guard (plan order 531).
#
# Makes "a forge must not be launched from a base that cannot build the plan
# expert" a verifiable check with a pass/fail exit code, instead of something an
# agent notices after the fact. Breach record: on 2026-07-30 an in-forge Claude
# session found BOTH experts returning confidence=unsupported to the milestone's
# own exemplar question, while the launch state truthfully read `experts: ready`.
# Two earlier cycles had absorbed the same condition by noticing and
# hand-rebasing (plan/loop_status.md:203, :243) — the guard-by-attentive-agent
# pattern this project forbids.
#
# ROOT CAUSE this guard closes. The launcher seeds a forge's branch from the HOST
# CHECKOUT's current branch (read_host_project_current_branch, main.rs:2701 ->
# TILLANDSIAS_FORGE_SEED_BRANCH), and the guest converges to it
# (images/default/lib-common.sh checkout_forge_seed_branch). So whatever branch
# this checkout is parked on becomes the next forge's base. `main` carries no
# crates/tillandsias-plan/src/answer.rs, so a forge seeded from it builds a
# PRE-EXPERT binary and then reports itself ready — truthful state, wrong
# artifact, which is the hardest kind to catch.
#
# WHY THE TEST IS SOURCE PRESENCE, NOT A BRANCH NAME. The names linux-next /
# windows-next / osx-next / main are Tillandsias's OWN conventions and are
# explicitly "NOT a runtime convention of the product"
# (methodology/multi-host-development.yaml:21-27): a forge launched on an end
# user's project must not assume them. Source presence is a fact about the
# checkout and is therefore safe to assert anywhere. It also catches the case a
# branch-name test cannot — when the seed and the actual branch AGREE because the
# host checkout was itself parked on a pre-expert base, nothing looks wrong.
#
# Emits exactly one line on stdout matching the falsifiable grammar
#   ^(ok:(expert-base-ready|no-plan-crate)|blocked:(expert-sources-absent|not-a-git-repo))$
# and exits 0 (safe to launch a forge) or 1 (blocked).
#
#   ok:expert-base-ready        the plan crate is present AND carries the expert
#                               engine sources; a forge seeded here can answer
#   ok:no-plan-crate            this project has no plan-expert crate at all —
#                               normal off-Tillandsias, nothing to expect
#   blocked:expert-sources-absent  a plan crate exists but the expert engine
#                               sources do not; a forge seeded here will report
#                               `experts: ready` and answer `unsupported`
#   blocked:not-a-git-repo      cwd is not inside a git worktree (fail closed)
#
# Run it from the checkout a forge will be launched FROM, which is the host
# checkout — not from inside the forge.

set -u

# The modules that make the difference between an expert binary and a pre-expert
# one. answer.rs carries the cited-envelope engine; methodology.rs the YAML path
# query. Either being absent means the built binary cannot serve an expert query.
EXPERT_SOURCES="crates/tillandsias-plan/src/answer.rs crates/tillandsias-plan/src/methodology.rs"

forge_expert_base_verdict() {
    root=$(git rev-parse --show-toplevel 2>/dev/null) || {
        echo "blocked:not-a-git-repo"
        return 1
    }

    if [ ! -d "$root/crates/tillandsias-plan" ]; then
        echo "ok:no-plan-crate"
        return 0
    fi

    missing=""
    for rel in $EXPERT_SOURCES; do
        [ -f "$root/$rel" ] || missing="${missing}${missing:+ }$rel"
    done

    if [ -n "$missing" ]; then
        echo "blocked:expert-sources-absent"
        {
            echo "[forge-expert-base] This checkout has crates/tillandsias-plan but is MISSING: $missing"
            echo "[forge-expert-base] A forge launched from here is seeded with this branch"
            echo "[forge-expert-base] (read_host_project_current_branch -> TILLANDSIAS_FORGE_SEED_BRANCH),"
            echo "[forge-expert-base] so it will build a PRE-EXPERT binary, report 'experts: ready',"
            echo "[forge-expert-base] and answer every plan_answer / methodology_path with"
            echo "[forge-expert-base] confidence=unsupported. Order 531."
            echo "[forge-expert-base] REMEDY: switch this checkout to a branch carrying the expert"
            echo "[forge-expert-base] sources before launching a forge:"
            echo "[forge-expert-base]     git branch -a --contains \$(git rev-list -1 HEAD -- crates/tillandsias-plan/src/answer.rs)"
            echo "[forge-expert-base] On the Tillandsias repo itself that is the host's platform branch"
            echo "[forge-expert-base] (see methodology/multi-host-development.yaml branch_canon)."
        } >&2
        return 1
    fi

    echo "ok:expert-base-ready"
    return 0
}

forge_expert_base_verdict

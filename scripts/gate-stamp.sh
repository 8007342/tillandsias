#!/usr/bin/env bash
# gate-stamp.sh — record and verify that the local gate ran against THIS tree.
# @trace spec:methodology-accountability
#
# WHY
#
# Push CI was removed on 2026-08-03 (operator directive: only the release may
# consume cloud minutes). `./build.sh --check` is now the only thing standing
# between an agent and a broken trunk — and within hours of the removal a
# sibling landed an always-true clippy expression on linux-next, because nothing
# required the gate to have been run.
#
# The obvious fix — run the whole gate inside the pre-push hook — fails in
# practice: a hook that takes minutes gets `--no-verify`'d on its second use,
# and then enforces nothing at all. So instead the gate STAMPS what it
# validated, and the hook verifies the stamp is current. Push-time cost is a
# hash of the diff; the guarantee is the same.
#
# WHAT THE STAMP COVERS
# (930-i6x4: everything EXCEPT the plan fast lane — plan/index.d/*.yaml,
# plan/loop_status.d/*.md, plan/mo-full-attestations.d/*.md — see `compute`.)
#
# HEAD plus the full working-tree diff against it, including untracked files.
# Any edit after the gate ran invalidates the stamp. This is deliberately strict:
# "I ran --check ten commits ago" is exactly the state that lets a regression
# through.
#
# The stamp lives in the git dir, never in the worktree — it is local machine
# state, not project content, and must never be committed or merged.
#
# WHAT THE STAMP DOES **NOT** COVER, AND WHY THAT NEEDED A FIELD (order 765-dt8h)
#
# Until 2026-08-17 the stamp recorded THAT a gate passed against these bytes,
# never WHICH gate — `_write_gate_stamp` writes identically from `--check`,
# `--ci` and `--ci-full`, which validate materially different things (`--check`
# never runs the test suite, the all-features clippy, or the litmus lane). That
# was harmless only because every gate validated the whole tree. The moment a
# scoped gate exists (diff-scoped litmus, change-class selectors, memoization —
# all blocked on this file), a scoped run writing the old format would let
# pre-push bless a push whose Rust the scoped run never compiled. The audit
# calls this the silent-green pivot for all scoping work.
#
# So the stamp now records its SCOPE, and the pre-push hook refuses when the
# outgoing diff reaches outside it. Scope is either `full` (everything — what
# every gate writes today) or a set of CHANGE CLASSES. The class vocabulary is
# closed and TOTAL: every path maps to exactly one class, and anything the
# taxonomy does not recognise maps to `other`, which only `full` covers. A
# scoped stamp can therefore never accidentally vouch for a path nobody
# classified.
#
# STAMP FORMAT
#
#   v2 (current) — keyed lines, extensible without another format change:
#       version 2
#       digest <64-hex>
#       scope full            # or: scope plan-ledger,docs
#       dispatch check        # provenance: which gate wrote it
#
#   v1 (legacy)  — a bare digest line. REFUSED, loudly, with the re-run
#       command: a v1 stamp carries no scope, and inferring one would be
#       exactly the assumption this packet exists to remove. The cost is one
#       `./build.sh --check` per host, once.
#
# TWO ADDITIONAL FIELDS FOR MEMOIZATION (order 765-tkq2)
#
#   toolchain <64-hex>   digest of `rustc -V` + `cargo clippy -V`
#   stamped   <iso8601>  when the recorded gate passed
#
# These are ADDITIVE and deliberately do NOT change what `verify` accepts. The
# distinction matters and is easy to get backwards:
#
#   `verify` answers "did the gate validate these BYTES", which is what
#   pre-push needs — trunk correctness is a property of the code, and every
#   other host compiles it with its own toolchain anyway. Requiring a
#   toolchain match there would force a second fleet-wide re-stamp for no
#   gain in trunk protection.
#
#   `memo-check` answers "would re-running the gate RIGHT HERE produce the
#   same verdict", which is a strictly stronger question: a clippy bump with
#   identical bytes yields new lints, so skipping the local re-run would hide
#   them. Hence memoization requires the toolchain to match and treats a
#   stamp without the field as stale.
#
# So a stamp written before this change keeps working for pre-push and simply
# never memoizes — fail-closed, no migration.
#
# SUBCOMMANDS
#   compute   print the stamp for the current tree
#   write     record the current stamp (call after the gate PASSES)
#             [--scope full|<class,...>] [--dispatch <name>]
#   verify    ok:gate-fresh | stale:<reason>   (exit 0 / non-zero)
#   scope     print the recorded scope (`full` or a class list) | stale:<reason>
#   classify  read paths on stdin, print the sorted unique class set
#   memo-check <dispatch>
#             ok:gate-fresh <iso8601> | stale:<reason>   (exit 0 / non-zero)
#             Every condition below must hold, or the answer is stale:
#               v2 stamp, digest matches, scope is full, toolchain matches,
#               recorded dispatch equals <dispatch>, stamped timestamp present.
#
# THE PASS TOKEN: WHAT IT GATES, AND WHAT IT DOES NOT (order 1039-b64k)
# --------------------------------------------------------------------
# `<git-dir>/tillandsias-gate-pass-token` is a MECHANISM, not a workaround, and
# it is narrower than its name suggests. Writing this down because the 1039-b64k
# packet was filed on the belief that the pre-push hook consults it — it does
# not, and a remedy was ruled on that belief before the code was read.
#
# WHAT IT GATES: `write`, and only `write`. build.sh mints the token after every
# check has passed (build.sh, in the stamp-writing function), and `write`
# consumes it below — refusing `refused:no-gate-pass-token` without one and
# `refused:gate-pass-token-is-for-another-tree` when its digest names a
# different tree. That makes an UNEARNED STAMP impossible by accident (940-f77j:
# `./build.sh --check; scripts/gate-stamp.sh write; git push` with semicolons
# rather than `&&` stamped a red gate on 2026-08-29). The token is consumed on
# use, so one green run authorises exactly one stamp.
#
# WHAT IT DOES NOT GATE: the push. scripts/hooks/pre-push-local-gate.sh calls
# `verify`, and `verify` compares the RECORDED digest against `compute()` for
# the current tree — that is its entire decision. No branch of the hook reads
# the token, including the stale: arms and the unknown-verdict arm. So:
#
#   * a push does not need a token; it needs a stamp whose digest matches the
#     tree being pushed;
#   * a MEMOISED gate mints no token and writes no stamp, and pushes fine
#     anyway, because the EXISTING stamp still covers an unchanged tree.
#     Verified 2026-09-05 on linux: after `ok:gate-fresh` the token file is
#     ABSENT and `verify` returns ok:gate-fresh;
#   * therefore minting a token on the memo path would defend nothing. That was
#     1039-b64k's remedy (1); it was dropped once the push path was read, on the
#     grounds that a change touching nothing in the push path cannot defend it.
#
# WHEN THE HOOK FALLS BACK. `verify` returning stale does not always refuse: a
# fragments-only push takes the plan-only lane (668-2xeh) which never consults
# the stamp's scope, a `stale:legacy-stamp-format` re-runs the gate once, and an
# UNRECOGNISED verdict warns without blocking — a stamp bug must not strand a
# push. Only `stale:never-run` / `stale:tree-changed-since-gate` on a
# non-plan-only push actually refuse.
#
# THE WINDOWS DEADLOCK THIS SECTION IS NAMED AFTER was never the token's doing.
# It was writer/verifier digest disagreement across the drvfs boundary, caused
# by a worktree exec-bit read added at 1034-ihxw against the standing warning in
# `compute` below, and closed by reverting it (0a1419ffe). yolanda confirmed on
# Windows with two equal computes, MSYS and WSL, on one tree at one moment.
# Index-sourced digests agree across that boundary; worktree-sourced ones cannot.

set -uo pipefail

# ── Portable SHA-256 (order 851-gpb5) ─────────────────────────────────────────
# `sha256sum` is coreutils (Linux/forge/WSL); Apple only added /sbin/sha256sum
# in macOS 13, and stock macOS otherwise ships `shasum`. Both print the same
# digest in the same "<hex>  <name>" line shape, so every first-field parse
# below works with either tool and the emitted frames — and therefore existing
# stamps — stay byte-identical across hosts (pinned by
# scripts/test-gate-stamp-portable-digest.sh). Same dispatch as
# scripts/build-sidecar.sh::_sha256; kept local because this script is
# deliberately self-contained.
if command -v sha256sum >/dev/null 2>&1; then
    GATE_STAMP_SHA256=(sha256sum)
else
    GATE_STAMP_SHA256=(shasum -a 256)
fi

# ── Change-class taxonomy (order 765-dt8h) ────────────────────────────────────
# TOTAL by construction: the final `*)` arm is what makes an unclassified path
# fail closed instead of silently belonging to whatever a scoped gate claimed.
# Keep the arms ordered most-specific-first; `plan/` must precede nothing else
# that could swallow it.
gate_stamp_classify_path() {
    case "$1" in
        plan/*)                                   echo plan-ledger ;;
        crates/*|Cargo.toml|Cargo.lock|rust-toolchain*) echo rust ;;
        images/*)                                 echo images ;;
        openspec/*)                               echo specs ;;
        methodology.yaml|methodology/*)           echo methodology ;;
        scripts/*|build.sh|flake.nix|flake.lock)  echo build-scripts ;;
        .github/*)                                echo ci ;;
        cheatsheets/*|docs/*|*.md)                echo docs ;;
        *)                                        echo other ;;
    esac
}

GATE_STAMP_KNOWN_CLASSES="plan-ledger rust images specs methodology build-scripts ci docs other"

# Digest of the toolchain whose verdict the stamp records (order 765-tkq2).
# Only the two compilers whose OUTPUT the gate consumes: rustc decides whether
# the tree builds, clippy decides whether it is clean. `cargo -V` is
# deliberately absent — a cargo bump with an identical rustc/clippy cannot
# change a lint verdict, and every input added here costs a re-run.
#
# A probe that cannot run yields the literal "unknown", which never equals a
# recorded digest, so a host without a toolchain simply never memoizes. That
# is the correct direction: the failure mode of guessing here is skipping a
# gate that would have failed.
gate_stamp_toolchain_digest() {
    local rustc_v clippy_v
    rustc_v="$(rustc -V 2>/dev/null)" || rustc_v="unknown"
    clippy_v="$(cargo clippy -V 2>/dev/null)" || clippy_v="unknown"
    [[ -n "$rustc_v" ]] || rustc_v="unknown"
    [[ -n "$clippy_v" ]] || clippy_v="unknown"
    printf 'rustc:%s\nclippy:%s\n' "$rustc_v" "$clippy_v" | "${GATE_STAMP_SHA256[@]}" | cut -d' ' -f1
}

gate_stamp_class_is_known() {
    local c
    for c in $GATE_STAMP_KNOWN_CLASSES; do
        [[ "$c" == "$1" ]] && return 0
    done
    return 1
}

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "stale:not-a-git-repo"
    exit 2
}
GIT_DIR="$(git rev-parse --absolute-git-dir 2>/dev/null)" || {
    echo "stale:no-git-dir"
    exit 2
}
STAMP_FILE="$GIT_DIR/tillandsias-gate-stamp"

compute() {
    # Hash the CONTENT of every tracked and untracked file in the worktree.
    #
    # This deliberately ignores HEAD and the index. An earlier version hashed
    # `HEAD + git diff HEAD`, which was wrong in a way that made the gate
    # unusable: committing changes HEAD without changing a single byte of
    # content, so the stamp went stale at exactly the moment you push. `git add`
    # broke it the same way. The property we actually want is "the gate
    # validated these bytes", and bytes do not care which commit they are on.
    #
    # ORDER 887-bz88 — st_mode IS part of "these bytes were validated". This
    # hashed path + kind + CONTENT and nothing else, so `chmod -x` moved the
    # stamp not at all and the pre-push hook accepted a tree the gate had never
    # seen in that shape. MEASURED: on 2026-08-25 lenovinha's cycle rewrote
    # scripts/check-credential-channel.sh through a temp file (`mv` drops the
    # exec bit), ran the gate, staged, committed and pushed; origin/linux-next
    # was left failing `violation:script-not-executable:1` on a pristine clone,
    # on the CREDENTIAL CHANNEL GUARD itself — a script every host invokes by
    # path before any committable work, where a lost exec bit is a permission
    # error rather than a verdict.
    #
    # TWO BLIND SPOTS COMPOSED, and neither alone would have done it:
    #   1. check-script-exec-bits.sh reads the INDEX (`git ls-files -s`), and the
    #      skill runs the gate BEFORE `git add`. The regression was still
    #      worktree-only, so the guard that exists for exactly this saw 100755
    #      and passed. (Closed separately, in that script: it now reads the
    #      worktree too, so the failure lands at gate time.)
    #   2. This fingerprint then made the subsequent `git add` — which is what
    #      wrote 100644 into the index — invisible, because it changed no bytes.
    #      The stamp stayed fresh and the hook accepted.
    #
    # Including the bit closes 2: any chmod now goes stale, the gate re-runs,
    # and by then the mode IS staged, so blind spot 1's guard sees it too.
    #
    # So: staging is invisible, committing is invisible, editing is not. A
    # deleted file drops its line and therefore changes the stamp, which is
    # correct. The path list is folded in explicitly so a deletion cannot be
    # confused with an unreadable file.
    #
    # Cost is ~60ms over ~4000 files — cheap enough that the hook can do this on
    # every push, which is the whole reason the stamp exists instead of re-running
    # the multi-minute gate.
    # Hash path, filesystem type, and content as NUL-framed records. A plain
    # `sha256sum <path>` follows symlinks; Tillandsias deliberately tracks the
    # runtime skill entries as symlinks to directories, so that implementation
    # failed every real checkout with "Is a directory" and never wrote a stamp.
    # Hash the link target text instead. Refuse any other non-file entry rather
    # than silently claiming that an unmeasured tree was validated.
    # PROCESS COUNT IS THE BUDGET (order 675-dkif, 2026-08-10). The original loop
    # spawned sha256sum once (twice, with the $() subshell) PER FILE, which is
    # the "multi-minute hook gets --no-verify'd" failure this stamp exists to
    # avoid. The batching below is still the right call — but the NUMBER that
    # justified it was a ghost, and it is corrected here.
    #
    # MEASURED by yolanda on yolanda (Windows), 2026-08-26, 1000 iterations:
    #
    #   Git Bash     /bin/true 17.58 ms    sha256sum 18.51 ms
    #   WSL          /bin/true  0.69 ms    sha256sum  1.33 ms
    #   yoga native  /bin/true  0.32 ms    sha256sum  0.80 ms
    #
    # This comment used to claim "~100-150 ms per spawn on a Windows/MSYS host",
    # inherited and never measured. The real MSYS floor is 17.6 ms — 6-9x lower
    # — and the figure was stale in the direction that made it scarier, which is
    # the direction that quietly justifies whatever it is cited for.
    #
    # It was also aimed at the wrong process. `./build.sh --check` runs INSIDE
    # WSL, where a spawn costs 0.69 ms — 2.2x yoga's native floor, not 55x — so
    # Windows spawn cost was never what made the gate slow there. The 9P/drvfs
    # filesystem bridge is (macbook measured a no-op cargo probe at 11.4 s over
    # /mnt/c against ~165 ms on two native hosts).
    #
    # WHAT SURVIVES, and it is why the batching stays: the pre-push HOOK runs in
    # Git Bash, at 17.6 ms a spawn. Thousands of per-file spawns there is still
    # tens of seconds of pure overhead on every push. A handful of batched
    # invocations beats that comfortably. The design was right; only its
    # arithmetic was fiction. Classification uses bash builtins (no
    # forks), regular files are batch-hashed by xargs in a handful of
    # sha256sum invocations, and only symlinks (rare) pay a per-entry spawn.
    # The emitted frames were BYTE-IDENTICAL to the per-file implementation,
    # so existing stamps stayed valid across THAT change. Order 887-bz88 adds
    # the exec-bit field below, which DOES change the frame: every existing
    # stamp goes stale once, and the next `./build.sh --check` on each host
    # writes a current one. That is a single re-run per host, it is self-healing,
    # and it is the price of the stamp no longer lying about st_mode.
    # ORDER 889-8tcb. The index modes, as a SORTED LIST consumed in lockstep —
    # not an associative array. `local -A` is bash 4 and macOS ships bash 3.2
    # (761-g36m); the gate caught it, which is the gate working. And not a
    # per-path lookup either: order 675-dkif established that a fork per file
    # turns this into a ~20-minute pre-push hook on Windows, which is precisely
    # how a hook gets --no-verify'd.
    #
    # Both streams are path-sorted in C collation — git orders index entries by
    # byte, and the enumeration below sorts with LC_ALL=C — so a single forward
    # pointer resolves every path in one linear sweep with no forks at all.
    # Byte collation for the whole sweep, matching the LC_ALL=C sorts below.
    local LC_ALL=C
    local -a _gs_xpaths=()
    local _xline
    while IFS= read -r _xline; do
        [ -n "$_xline" ] && _gs_xpaths+=("$_xline")
    done < <(git -C "$REPO_ROOT" ls-files -s 2>/dev/null \
             | LC_ALL=C sed -n 's/^100755 [0-9a-f]* [0-9]*\t//p' \
             | LC_ALL=C sort)
    local _gs_xi=0 _gs_xn=${#_gs_xpaths[@]}

    local -a paths=() kinds=() execbits=() file_digests=() symlink_digests=()
    local path absolute digest line i
    while IFS= read -r -d '' path; do
        # ORDER 930-i6x4 — THE PLAN FAST LANE NEVER ENTERS THE STAMP.
        # plan/index.d/*.yaml, plan/loop_status.d/*.md and
        # plan/mo-full-attestations.d/*.md are append-only ledger traffic the
        # pre-push plan-only lane already accepts WITHOUT a stamp (668-2xeh).
        # Hashing them here meant every sibling landing rebased into a
        # checkout staled a stamp that remained true of every byte of code:
        # nine commits inside one ~10-minute gate on 2026-08-29 (four rounds
        # to push a cheatsheet), three merge-check-push rounds on 2026-09-02.
        # The stale stamp was judged against the whole tree instead of against
        # what moved. Code, specs, scripts, images, methodology and
        # plan/index.yaml itself (the compacted BASE, which a fold rewrites)
        # all still hash; a change to any of them re-gates. Negative control:
        # scripts/test-gate-stamp.sh cases 6-7. Skipping here cannot desync the
        # exec-bit lockstep below: the pointer catches up on the next path.
        case "$path" in
            plan/index.d/*.yaml|plan/loop_status.d/*.md|plan/mo-full-attestations.d/*.md) continue ;;
        esac
        absolute="$REPO_ROOT/$path"
        if [[ -L "$absolute" ]]; then
            kinds+=(symlink) paths+=("$path") execbits+=(-)
        elif [[ -f "$absolute" ]]; then
            # ORDER 887-bz88 — the exec bit is part of "these bytes were
            # validated", and it was not hashed. See the note above `compute`.
            #
            # ORDER 889-8tcb — SOURCED FROM THE INDEX, NEVER THE WORKTREE.
            # The first version tested `[[ -x "$absolute" ]]` and DEADLOCKED
            # EVERY WINDOWS HOST. `./build.sh --check` dispatches into WSL and
            # hashes through /mnt/c (drvfs), which reports every file
            # executable; the pre-push hook runs in Git Bash and sees real
            # bits. Measured on one tree at one moment: WSL `x README.md`,
            # Git Bash `- README.md`. The two digests can never agree, so
            # `verify` returned stale immediately after a green 287s gate,
            # forever — and the memo said ok:gate-fresh, so the gate would not
            # re-run either. yolanda could not push anything at all.
            #
            # A CAPABILITY PROBE WAS TRIED AND IS THE WRONG SHAPE, which is the
            # part worth keeping: a probe answers PER ENVIRONMENT. Git Bash on
            # NTFS honours chmod 0644 and concludes "bits work"; WSL on drvfs
            # concludes "bits do not". Both answers are true about the ASKER and
            # useless about the TREE, so the two sides pick different sources
            # and diverge exactly as before (measured: 8ca8074b vs 83e63835).
            # `core.fileMode` fixes the axis — it is git being TOLD the bits are
            # untrustworthy, a DECLARATION both sides read identically, not an
            # inference the broken filesystem gets to answer. Sourcing from the
            # index under it made both sides agree (68b6a93b from both).
            #
            # Index-always goes further and takes NO branch, because a branch
            # means a path that cannot be exercised from the host writing it —
            # which is precisely how the worktree version shipped. Safe on
            # POSIX by measurement, not assumption: across all tracked files
            # the index mode and `[[ -x ]]` disagree ZERO times, verified
            # independently on yoga (4537 files) and lenovinha (4553).
            #
            # It also makes the stamp agree with its own sibling: this file's
            # comment at :195 already notes that check-script-exec-bits.sh reads
            # the index. The stamp was the outlier, not the accommodation.
            #
            # WHAT THIS GIVES UP, stated because it narrows a pinned assertion:
            # a bare unstaged `chmod -x` no longer moves the stamp. Blind spot 2
            # still closes — the `git add` that writes 100644 moves the index —
            # and blind spot 1 (the worktree arm of check-script-exec-bits.sh)
            # is untouched and still refuses at GATE time, which is the guard
            # that actually caught the original regression.
            #
            # Untracked files have no index entry and record `-`: constant and
            # portable, and an untracked file's bit is not part of what a commit
            # would carry. Staging it gives it a real mode.
            # Advance past every executable path that sorts BEFORE this one,
            # then test for equality. Linear over both lists, zero forks.
            # `[[ < ]]` is a bash builtin comparison — no subshell. The first
            # draft wrapped it in $(...), which forks once per comparison and
            # reintroduces exactly the per-file spawn cost 675-dkif removed.
            while [[ "$_gs_xi" -lt "$_gs_xn" && "${_gs_xpaths[$_gs_xi]}" < "$path" ]]; do
                _gs_xi=$((_gs_xi + 1))
            done
            if [ "$_gs_xi" -lt "$_gs_xn" ] && [ "${_gs_xpaths[$_gs_xi]}" = "$path" ]; then
                execbits+=(x)
            else
                execbits+=(-)
            fi
            kinds+=(file) paths+=("$path")
        elif [[ ! -e "$absolute" ]]; then
            # DELETED tracked entry (order 695-nvnd). `ls-files --cached` reads the
            # INDEX, so a file deleted from the worktree is still listed here and
            # used to hit the refusal below — on a tree where every gate check had
            # just passed. `tillandsias-plan compact` deletes the fragments it
            # folded, which IS compaction, so every compacting cycle paid the
            # slowest step in the cycle twice: once green-but-unstamped, once
            # green-and-stamped.
            #
            # The entry is DROPPED from the hashed list, not recorded as deleted.
            # That is what keeps the stamp commit-invariant, which is the property
            # the whole design rests on ("staging is invisible, committing is
            # invisible, editing is not"): committing a deletion removes the path
            # from the index, so a `deleted` frame would vanish at commit time and
            # go stale at exactly the moment the hook checks it. Dropping it makes
            # the two enumerations agree.
            #
            # This does not weaken the stamp. The deleted path's frame — its name
            # AND its content digest — disappears from the hash, so a deletion
            # still changes the stamp exactly as an edit does; it cannot ride an
            # older stamp to the trunk. And it stays distinct from an unreadable
            # file: an unreadable file EXISTS, so it falls through to the refusal
            # below. Absent is not the same as unmeasured.
            continue
        else
            echo "gate-stamp: unsupported worktree entry: $path" >&2
            return 1
        fi
    done < <(git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard 2>/dev/null \
        | LC_ALL=C sort -z)

    local nfiles=0
    while IFS= read -r line; do
        file_digests+=("${line%% *}")
    done < <(
        for ((i = 0; i < ${#paths[@]}; i++)); do
            [[ "${kinds[i]}" == file ]] && printf '%s\0' "$REPO_ROOT/${paths[i]}"
        done | xargs -0 -r "${GATE_STAMP_SHA256[@]}"
    )
    for ((i = 0; i < ${#paths[@]}; i++)); do
        [[ "${kinds[i]}" == file ]] && nfiles=$((nfiles + 1))
    done
    if [[ "${#file_digests[@]}" -ne "$nfiles" ]]; then
        # A missing digest means an unreadable file; claiming an unmeasured
        # tree was validated is the one thing this stamp must never do.
        echo "gate-stamp: hashed ${#file_digests[@]} of $nfiles regular files" >&2
        return 1
    fi
    for ((i = 0; i < ${#paths[@]}; i++)); do
        if [[ "${kinds[i]}" == symlink ]]; then
            digest="$(readlink "$REPO_ROOT/${paths[i]}" | "${GATE_STAMP_SHA256[@]}" | cut -d' ' -f1)" || return 1
            symlink_digests+=("$digest")
        fi
    done

    local fidx=0 sidx=0
    for ((i = 0; i < ${#paths[@]}; i++)); do
        if [[ "${kinds[i]}" == symlink ]]; then
            printf 'symlink\0%s\0%s\0' "${paths[i]}" "${symlink_digests[sidx]}"
            sidx=$((sidx + 1))
        else
            printf 'file\0%s\0%s\0%s\0' "${paths[i]}" "${execbits[i]}" "${file_digests[fidx]}"
            fidx=$((fidx + 1))
        fi
    done | "${GATE_STAMP_SHA256[@]}" | cut -d' ' -f1
}

# Read one keyed field out of a v2 stamp. Prints nothing for a v1/legacy or
# malformed file — every caller treats "no value" as fail-closed.
stamp_field() {
    local key="$1" k v
    while read -r k v; do
        [[ "$k" == "$key" ]] && { printf '%s\n' "$v"; return 0; }
    done < "$STAMP_FILE"
    return 1
}

stamp_is_v2() {
    [[ -f "$STAMP_FILE" ]] || return 1
    [[ "$(stamp_field version 2>/dev/null)" == "2" ]]
}

case "${1:-verify}" in
    compute)
        compute
        ;;
    write)
        shift
        scope_spec="full"
        dispatch="unknown"
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --scope)    scope_spec="${2:-}"; shift 2 ;;
                --scope=*)  scope_spec="${1#*=}"; shift ;;
                --dispatch) dispatch="${2:-}"; shift 2 ;;
                --dispatch=*) dispatch="${1#*=}"; shift ;;
                *) echo "gate-stamp: unknown write option '$1'" >&2; exit 2 ;;
            esac
        done

        # ORDER 940-f77j — A STAMP MUST BE EARNED, NOT MERELY WRITTEN.
        #
        # build.sh has always reached `_write_gate_stamp` only after every check
        # passed, so ITS stamps were honest. But `write` is a public entry point,
        # and the invariant lived in build.sh's control flow rather than here —
        # so any caller could assert a pass the gate never granted. On
        # 2026-08-29 one did: `./build.sh --check; scripts/gate-stamp.sh write;
        # git push`, semicolons rather than `&&`. The gate exited 1, the next
        # command stamped anyway, and a red tree pushed under a stamp saying it
        # was green.
        #
        # The vulnerability was never the punctuation. A guarantee whose
        # enforcement lives in every caller's shell is not enforced, it is
        # documented — and this one had a real checker sitting right beside it
        # whose verdict simply was not wired to the artifact that spoke for it.
        #
        # So the gate now hands over a PASS TOKEN naming the tree it validated,
        # and `write` refuses without one. The token is consumed here, which
        # bounds it to the single run that earned it: a second `write` after the
        # same gate is refused exactly like the first unearned one.
        #
        # SCOPE OF THE GUARANTEE, stated rather than implied: this makes an
        # unearned stamp impossible BY ACCIDENT. It does not make one impossible
        # by intent — anyone who can write the stamp file can write the token
        # file. Unforgeable-by-accident is achievable here and is the whole of
        # what is claimed; a determined caller was always able to write
        # $STAMP_FILE directly and still is.
        _pass_token="$(git rev-parse --absolute-git-dir 2>/dev/null)/tillandsias-gate-pass-token"
        if [[ "${GATE_STAMP_REQUIRE_TOKEN:-1}" != "0" ]]; then
            if [[ ! -f "$_pass_token" ]]; then
                echo "refused:no-gate-pass-token"
                echo "  A stamp says './build.sh --check PASSED against this tree'. Nothing in this" >&2
                echo "  invocation establishes that it did, so writing one would be an assertion" >&2
                echo "  rather than a record (940-f77j)." >&2
                echo "  Run the gate and let it stamp: ./build.sh --check" >&2
                echo "  Note the gate writes the stamp itself on success — a separate 'gate-stamp.sh" >&2
                echo "  write' was never needed after a green run, and after a RED one it is the bug." >&2
                exit 1
            fi
            _token_digest="$(sed -n 's/^digest //p' "$_pass_token" 2>/dev/null | head -1)"
            _tree_digest="$(compute)" || {
                echo "stale:cannot-write-stamp"
                exit 1
            }
            # A token keyed to a DIFFERENT tree is the same defect one step
            # subtler: "a gate passed" wearing "this tree passed" as a costume.
            if [[ "$_token_digest" != "$_tree_digest" ]]; then
                rm -f "$_pass_token" 2>/dev/null || true
                echo "refused:gate-pass-token-is-for-another-tree"
                echo "  The gate passed against ${_token_digest:-<unreadable>}; this tree is ${_tree_digest}." >&2
                echo "  The tree changed after the gate ran, so its verdict does not cover these bytes." >&2
                echo "  Re-run: ./build.sh --check" >&2
                exit 1
            fi
            # One-shot: consuming the token bounds it to the run that earned it.
            rm -f "$_pass_token" 2>/dev/null || true
        fi
        # Refuse an unknown class AT WRITE TIME too. A stamp is only as
        # trustworthy as the vocabulary both sides share; letting a typo become
        # a scope token would make the hook's subset test silently wrong in the
        # permissive direction.
        if [[ "$scope_spec" != "full" ]]; then
            IFS=',' read -r -a _scope_classes <<< "$scope_spec"
            if [[ ${#_scope_classes[@]} -eq 0 ]]; then
                echo "stale:empty-scope"
                exit 1
            fi
            for _c in "${_scope_classes[@]}"; do
                if ! gate_stamp_class_is_known "$_c"; then
                    echo "stale:unknown-scope-class:$_c"
                    exit 1
                fi
            done
        fi
        digest="$(compute)" || {
            echo "stale:cannot-write-stamp"
            exit 1
        }
        {
            printf 'version 2\n'
            printf 'digest %s\n' "$digest"
            printf 'scope %s\n' "$scope_spec"
            printf 'dispatch %s\n' "$dispatch"
            printf 'toolchain %s\n' "$(gate_stamp_toolchain_digest)"
            printf 'stamped %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } > "$STAMP_FILE" || {
            echo "stale:cannot-write-stamp"
            exit 1
        }
        echo "ok:gate-stamped"
        ;;
    verify)
        if [[ ! -f "$STAMP_FILE" ]]; then
            echo "stale:never-run"
            exit 1
        fi
        if [[ ! -s "$STAMP_FILE" ]]; then
            echo "stale:empty-stamp"
            exit 1
        fi
        if ! stamp_is_v2; then
            # A bare-digest stamp from before 765-dt8h. It almost certainly came
            # from a full gate — but "almost certainly" is the inference this
            # packet exists to delete, so migrate loudly instead of assuming.
            echo "stale:legacy-stamp-format"
            exit 1
        fi
        recorded="$(stamp_field digest 2>/dev/null)"
        if [[ -z "$recorded" ]]; then
            echo "stale:empty-stamp"
            exit 1
        fi
        current="$(compute)"
        if [[ "$recorded" != "$current" ]]; then
            echo "stale:tree-changed-since-gate"
            exit 1
        fi
        echo "ok:gate-fresh"
        ;;
    scope)
        if [[ ! -f "$STAMP_FILE" ]]; then
            echo "stale:never-run"
            exit 1
        fi
        if ! stamp_is_v2; then
            echo "stale:legacy-stamp-format"
            exit 1
        fi
        recorded_scope="$(stamp_field scope 2>/dev/null)"
        if [[ -z "$recorded_scope" ]]; then
            echo "stale:no-scope-recorded"
            exit 1
        fi
        if [[ "$recorded_scope" != "full" ]]; then
            IFS=',' read -r -a _scope_classes <<< "$recorded_scope"
            for _c in "${_scope_classes[@]}"; do
                if ! gate_stamp_class_is_known "$_c"; then
                    # An unknown token cannot be reasoned about; the packet's
                    # rule is that ambiguity is staleness.
                    echo "stale:unknown-scope-class:$_c"
                    exit 1
                fi
            done
        fi
        printf '%s\n' "$recorded_scope"
        ;;
    memo-check)
        # "Would re-running the gate right here produce the same verdict?"
        #
        # Every arm below is fail-CLOSED: the only path to exit 0 is one where
        # each condition was affirmatively checked. The reasons are distinct
        # strings on purpose — a memo that refuses should say which assumption
        # broke, or the next reader learns nothing from it.
        expected_dispatch="${2:-}"
        if [[ -z "$expected_dispatch" ]]; then
            echo "stale:memo-check-needs-a-dispatch"
            exit 2
        fi
        if [[ ! -f "$STAMP_FILE" ]]; then
            echo "stale:never-run"
            exit 1
        fi
        if ! stamp_is_v2; then
            echo "stale:legacy-stamp-format"
            exit 1
        fi
        recorded_scope="$(stamp_field scope 2>/dev/null)"
        # Only a whole-tree gate may be memoized. A scoped stamp vouches for a
        # subset of the tree, and this memo skips the WHOLE gate — trusting a
        # subset stamp for that is precisely the silent-green the scope field
        # was added to prevent. When scoped gates land (765-xpct), the memo
        # they need is per-class and belongs with them, not here.
        if [[ "$recorded_scope" != "full" ]]; then
            echo "stale:scoped-stamp-cannot-memoize-full-gate"
            exit 1
        fi
        recorded_dispatch="$(stamp_field dispatch 2>/dev/null)"
        # Deliberately an EQUALITY test, not a superset test. `--ci-full` is
        # documented as the stronger gate and would in fact cover a `--check`,
        # but "stronger" is a claim nobody has encoded — the dispatch field is
        # provenance, not an ordering. Inventing an ordering here would be the
        # same unverified inference the v1-stamp refusal exists to reject. The
        # cost is one honest re-run after a ci-full; the alternative is a memo
        # whose soundness rests on a comment.
        if [[ "$recorded_dispatch" != "$expected_dispatch" ]]; then
            echo "stale:dispatch-mismatch:${recorded_dispatch:-none}"
            exit 1
        fi
        recorded_toolchain="$(stamp_field toolchain 2>/dev/null)"
        if [[ -z "$recorded_toolchain" ]]; then
            # Written before 765-tkq2. Absent is not "assume unchanged".
            echo "stale:no-toolchain-recorded"
            exit 1
        fi
        if [[ "$recorded_toolchain" != "$(gate_stamp_toolchain_digest)" ]]; then
            echo "stale:toolchain-changed"
            exit 1
        fi
        recorded_stamped="$(stamp_field stamped 2>/dev/null)"
        if [[ -z "$recorded_stamped" ]]; then
            echo "stale:no-timestamp-recorded"
            exit 1
        fi
        recorded="$(stamp_field digest 2>/dev/null)"
        if [[ -z "$recorded" ]]; then
            echo "stale:empty-stamp"
            exit 1
        fi
        # Content digest LAST: it is the expensive check (~60ms over ~4200
        # files) and every cheap disqualifier above has already run.
        if [[ "$recorded" != "$(compute)" ]]; then
            echo "stale:tree-changed-since-gate"
            exit 1
        fi
        # ── WORKTREE MODE DRIFT (order 1036-e5w9) ────────────────────────────
        #
        # THE MEMO KEYS ON A DIGEST THAT DELIBERATELY CANNOT SEE THIS. `compute`
        # sources exec bits from the INDEX (889-8tcb, and that is not negotiable
        # — the worktree read deadlocked every Windows host). So a worktree-only
        # `chmod -x` leaves the digest identical, the memo says ok:gate-fresh,
        # and the gate never runs — including `check-script-exec-bits`, the
        # guard that exists to refuse exactly that defect.
        #
        # MEASURED on lenovinha 2026-09-04, which is why this packet exists:
        #     chmod -x scripts/check-litmus-pin-claims.sh   # worktree only
        #     ./build.sh --check                  -> rc=0 in 2s, ok:gate-fresh
        #     TILLANDSIAS_FORCE_CHECK=1 …         -> rc=1, violation:script-not-executable:1
        # Both components were correct; the memo's safety argument ("the gate is
        # a pure function of tree bytes and toolchain") is true and INSUFFICIENT,
        # because at least one guard is not a function of tree bytes alone.
        #
        # THE FIX IS IN THE MEMO, NEVER IN THE DIGEST. I tried the digest first
        # (1034-ihxw, obsoleted) and reintroduced the drvfs deadlock; the revert
        # is 0a1419ffe and it cost yolanda ~40 minutes rediscovering a defect
        # documented eighty lines above the line they were debugging. The digest
        # is the one thing here that must not change, and this check does not
        # touch it — measured before and after a chmod, `compute` returns the
        # same 38456419… either way.
        #
        # WHY `git diff --summary` AND NOT A STAT (yolanda's shape). A stat asks
        # the FILESYSTEM, and on drvfs the filesystem lies — that is the whole of
        # 889-8tcb. git's answer is governed by `core.fileMode`, which 889-8tcb
        # itself calls "a DECLARATION both sides read identically, not an
        # inference the broken filesystem gets to answer". So this reads modes
        # through the same declaration the digest already trusts.
        #
        # MEASURED, on one tree, one moment, toggling only that setting:
        #     core.fileMode=true   -> mode changes seen: 1   (POSIX: memo refuses)
        #     core.fileMode=false  -> mode changes seen: 0   (drvfs/Windows: memo
        #                                                     behaves exactly as
        #                                                     today, no deadlock)
        # A Windows host therefore sees NO behaviour change from this block,
        # which is the property the previous attempt failed to have.
        #
        # COST, stated because the packet asked for it: one `git diff --summary`
        # on the memo path (~20ms here), against the ~2s memoised gate it
        # protects. It is scoped to mode changes only — a content edit already
        # moves the digest and is caught above, so this adds no coverage there
        # and no cost beyond the single call.
        #
        # SCOPE: worktree-vs-index only. A STAGED mode change moves the index,
        # therefore the digest, therefore `stale:tree-changed-since-gate` above.
        # CAPTURE BEFORE MATCHING (792-ksr8). The first version of this was
        # `git diff --summary | grep -q '^ mode change '`, and the gate refused
        # it: `grep -q` exits on the FIRST match, SIGPIPEs `git diff`, and the
        # pipeline's status then depends on which side won a race. A memo
        # verdict decided by a signal is precisely the class this block exists
        # to close, so the guard was right to refuse it in the same change.
        _mode_drift="$(git diff --summary 2>/dev/null || true)"
        case $'\n'"$_mode_drift" in
            *$'\n'" mode change "*)
                echo "stale:worktree-mode-drift"
                exit 1
                ;;
        esac
        echo "ok:gate-fresh $recorded_stamped"
        ;;
    classify)
        # Paths on stdin (one per line) -> the sorted unique class set, one per
        # line. One spawn for a whole diff; the hook must not fork per path.
        while IFS= read -r p; do
            [[ -n "$p" ]] || continue
            gate_stamp_classify_path "$p"
        done | LC_ALL=C sort -u
        ;;
    *)
        echo "usage: gate-stamp.sh [compute|write [--scope S] [--dispatch D]|verify|scope|classify|memo-check <dispatch>]" >&2
        exit 2
        ;;
esac

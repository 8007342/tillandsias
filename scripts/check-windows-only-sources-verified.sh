#!/usr/bin/env bash
# @trace spec:windows-native-tray, spec:methodology-accountability
#
# Order 716-f5kc. Say out loud when a Windows-only source has changed since the
# last time a Windows toolchain actually compiled it.
#
# THE SILENCE THIS REPLACES
#
# `crates/tillandsias-windows-tray/src/main.rs` declares, for every
# Windows-only module, a `#[cfg(not(target_os = "windows"))] #[path =
# "stubs/X.rs"] mod X;` substitute. That is correct and deliberate — it lets the
# portable code paths and their tests compile on Linux. What it also does is
# make `cargo check -p tillandsias-windows-tray` on a Linux host compile the
# STUB and report success WITHOUT PARSING the file the agent just edited.
#
# So the failure mode is a green that means nothing, and it is silent in the
# direction that matters. It happened twice in one session (2026-08-13): once
# caught by a deliberate second look on order 648-772y, once unavoidable on
# order 664-frz0 when Smart App Control blocked the native toolchain
# (`os error 4551`) and left this host with no way to compile the file at all.
#
# This does not fix that. It makes it VISIBLE: a cycle can no longer edit
# wsl_lifecycle.rs, watch a Linux build go green, and be unaware that nothing
# read the change.
#
# WHY IT IS NOT A HARD GATE (yet)
#
# Refusing the push when the toolchain is blocked would strand finished work on
# a host that cannot verify — which the meta-orchestration exit contract forbids
# more strongly than it forbids an unverified commit. So this reports, and the
# report is what a cycle must carry into its handoff. Promoting it to a refusal
# is a decision for the operator, and the natural moment is when dev binaries
# are signed and SAC stops being a coin flip.
#
# ORDER 738-3pft — A RESULT ONLY ITS AUTHOR CAN SEE IS NOT EVIDENCE
#
# The stamp above lives under $GIT_DIR, so it cannot cross a host boundary. The
# consequence was not cosmetic: on 2026-08-14 the linux host quoted
# `stale:windows-sources-never-verified:4` to the operator as "the largest
# unverified surface in this release" and HELD A RELEASE on it, while the
# Windows host had run `cargo test -p tillandsias-windows-tray --bins` natively,
# 89 passed, twice, once against the exact merge candidate, and stamped both
# times. A statement about MY VISIBILITY was read as a statement about THE
# SOURCES, and the vocabulary made that misreading easy.
#
# So `attest` writes a TRACKED, host-attributed file under plan/attestations/
# that any host can read and any host can watch go stale. It is deliberately NOT
# a trust decision about the other host: the file records a `git hash-object`
# blob sha per source, which the reader RECOMPUTES from its own checkout. You
# are not believing someone's "89 passed" — you are checking that the bytes they
# ran against are the bytes you have.
#
# STALENESS KEYS ON SOURCE CONTENT, NOT ON THE COMMIT SHA (the Windows writer's
# design decision, and the one that matters). Keyed on the commit, an
# attestation would go stale on the very next commit — and on this project the
# next commit is almost always a plan fragment. It would read `stale` within
# minutes of being written, permanently, and we would have rebuilt the original
# defect with extra steps: a verdict that says something about the sources while
# actually reporting something else. The commit is recorded as provenance only.
#
# Hashes are FILTERED (`git hash-object -- <path>`, the default with a path
# argument, never --no-filters): with `* text=auto eol=lf` in .gitattributes a
# CRLF Windows worktree and an LF Linux checkout agree. Raw-byte hashing would
# make every cross-platform comparison fail silently.
#
# GRAMMAR (exactly one line on stdout). ONE grammar, `scope` as a FIELD — not
# the platform baked into the token — so the macOS writer (739-6r6n) reuses this
# vocabulary instead of inventing a second one.
#   ok:sources-verified:<scope>:<n>             all n sources match the evidence
#   stale:sources-drifted:<scope>:<n>:<f>       n moved since the evidence, first is f
#   missing:sources-no-attestation:<scope>      THIS REPOSITORY holds no attestation
#                                               for <scope>, and this host has no
#                                               local stamp
#   skip:no-sources:<scope>                     nothing to check (crate moved?)
#   ok:sources-attested:<scope>:<n>             `attest` wrote the tracked file
#   refused:stamp-needs-evidence:<why>          `stamp`/`attest` called without a
#                                               transcript (<why> begins
#                                               `usage: <argv>` — that argv is
#                                               copy-pasteable and is executed by
#                                               the fixture, order 801-ajcd)
#   refused:undeclared-failure:<test>           a red test nobody has declared
#
# WHY `missing:` AND NOT `never-verified` (exit criterion, and the whole point):
# absence of an attestation is a statement about THIS REPOSITORY, not about
# whether anyone ever ran the tests. The old spelling is what got read as a
# claim about the sources. `stale:` now means one thing only — the sources MOVED
# since the evidence — and can never mean "I cannot see it".
#
# Exit 0 always: this is a report, not a refusal. Branch on the verdict, and
# never on the exit code, which is the mistake that would let it be ignored.
#
# SUBCOMMANDS
#   check   (default) print the verdict
#   stamp   record the current contents as verified in the HOST-LOCAL stamp —
#           call ONLY after a native `cargo test -p tillandsias-windows-tray`
#           has actually run, with every failure accounted for in KNOWN-RED
#   attest  the same checked claim, written to a TRACKED file the whole fleet
#           reads. Same evidence gate as `stamp`; `--from -` reads the
#           transcript from stdin so the writer stays one command.
#
# KNOWN-RED, and why it exists rather than a blanket "suite must be green":
# `embedded_guest_headless_matches_workspace_version` fails on any tree whose
# build counter has moved without the committed guest asset being rebuilt — a
# standing condition on this host, filed as
# plan/issues/research-windows-tray-embedded-guest-binary-staleness-2026-08-13.md.
# Refusing to ever stamp because of it would leave this report reading `stale`
# permanently, which is the decay this check's own fixture (case 5) exists to
# prevent: a report that is always red is one nobody reads. So a failure is
# tolerated ONLY when it is named in scripts/windows-only-known-red.txt, which
# is a list someone has to edit deliberately.

set -uo pipefail

# Portable SHA-256 (851-28b5): coreutils sha256sum on Linux/forge/WSL; stock
# macOS before 13 ships only `shasum`. Identical "<hex>  <name>" output.
if command -v sha256sum >/dev/null 2>&1; then
    PORTABLE_SHA256=(sha256sum)
else
    PORTABLE_SHA256=(shasum -a 256)
fi

ROOT="${WINDOWS_ONLY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
GIT_DIR="$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null || echo "$ROOT/.git")"
STAMP_FILE="${WINDOWS_ONLY_STAMP:-$GIT_DIR/tillandsias-windows-only-verified}"
TRAY_SRC="$ROOT/crates/tillandsias-windows-tray/src"
MAIN_RS="$TRAY_SRC/main.rs"

# ORDER 738-3pft. Scope is a FIELD in one shared grammar, so a macOS writer
# reuses this vocabulary rather than minting `macos-sources-*` tokens.
SCOPE="windows-only"
ATTEST_DIR="${WINDOWS_ONLY_ATTEST_DIR:-$ROOT/plan/attestations}"

# One file per scope+host, so two hosts never write the same path and git has
# nothing to merge — the same reason plan/index.d/ fragments are per-host.
default_host_label() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin)                 echo "macos" ;;
        MINGW*|MSYS*|CYGWIN*)   echo "windows" ;;
        Linux)                  echo "linux" ;;
        *)                      echo "unknown" ;;
    esac
}

# FILTERED hashing, deliberately. `git hash-object -- <path>` applies the
# .gitattributes `* text=auto eol=lf` filter, which is what makes a Windows CRLF
# worktree and a Linux checkout agree on the same source. Contrast
# scripts/meta-orchestration-worktree-guard.sh, which wants raw bytes and
# therefore passes --no-filters; copying that here would make every
# cross-platform comparison fail silently, which is this packet's own defect
# wearing a different hat.
blob_hash_of() {
    git -C "$ROOT" hash-object -- "$1" 2>/dev/null
}

# `--from -` reads stdin. A path argument forces the writer to materialise a
# temp file, which makes the "one command" claim false — the macOS reviewer's
# constraint 1. GNU/BSD `cat` happen to treat the operand `-` as stdin already,
# so this can look like a no-op; the point is that it is now EXPLICIT and pinned
# by a fixture case, rather than an accident of the local cat implementation.
read_transcript() {
    if [ "$1" = "-" ]; then
        cat
    else
        cat "$1" 2>/dev/null
    fi
}

# The Windows-only set is DERIVED from main.rs rather than listed here, so a new
# Windows-only module cannot forget to join the check. It reads the
# `#[cfg(target_os = "windows")] mod X;` declarations — NOT the `#[path =
# "stubs/…"]` lines, which was the first attempt and quietly missed `hvsocket`:
# that module is Windows-only and has no stub, so it is equally invisible to a
# Linux build and equally needs saying so.
windows_only_sources() {
    [ -f "$MAIN_RS" ] || return 0
    # `grep -A 1` over the cfg attribute, keep the `mod X;` line, strip to X.
    grep -A 1 -F '#[cfg(target_os = "windows")]' "$MAIN_RS" 2>/dev/null |
        grep -oE '^mod [a-z_]+;' |
        cut -d' ' -f2 |
        tr -d ';' |
        sort -u |
        while IFS= read -r m; do
            [ -n "$m" ] && [ -f "$TRAY_SRC/$m.rs" ] && echo "$TRAY_SRC/$m.rs"
        done
}

digest_of() {
    # Path + content, so a rename is a change too.
    while IFS= read -r f; do
        printf '%s\0' "${f#"$ROOT"/}"
        "${PORTABLE_SHA256[@]}" "$f" | cut -d' ' -f1
    done | "${PORTABLE_SHA256[@]}" | cut -d' ' -f1
}

# NOT `mapfile -t` (order 723-b9cn, measured on macOS 2026-08-13). `mapfile` is
# bash 4+; this host is GNU bash 3.2.57 (Apple ships 3.2 and `/usr/bin/env bash`
# resolves to it), where the line failed with "mapfile: command not found" and
# then SOURCES was unbound on three further lines — yet the script still exited
# 0, so ./build.sh printed "Windows-only sources: " with an empty list and the
# reader saw a verdict rather than a broken guard. That is the precise inversion
# order 716-f5kc exists to prevent: it was written to make an invisible gap
# visible, and on macOS it was reporting the gap as empty.
SOURCES=()
while IFS= read -r _line; do
    [ -n "$_line" ] && SOURCES+=("$_line")
done < <(windows_only_sources)
if [ "${#SOURCES[@]}" -eq 0 ]; then
    echo "skip:no-sources:$SCOPE"
    exit 0
fi

current="$(printf '%s\n' "${SOURCES[@]}" | digest_of)"

# ── Shared evidence gate (order 738-3pft) ─────────────────────────────────────
# FACTORED so `stamp` and `attest` cannot drift apart. A tracked attestation
# written on weaker evidence than a host-local stamp would be strictly worse
# than the stamp it replaces: it is the one the whole fleet reads.
#
# Sets: TRANSCRIPT_FROM (the --from operand), TRANSCRIPT, RESULT_LINE.
# Prints a `refused:` verdict and exits 1 when the claim is not backed.
parse_from_arg() {
    # Tolerates the pre-801-ajcd `pass` token (see the block below).
    TRANSCRIPT_FROM=""
    case "${1:-}" in
        --from) TRANSCRIPT_FROM="${2:-}" ;;
        pass)
            case "${2:-}" in
                --from) TRANSCRIPT_FROM="${3:-}" ;;
            esac
            ;;
    esac
}

require_evidence() {
    _subcmd="$1"
    if [ -z "$TRANSCRIPT_FROM" ]; then
        echo "refused:stamp-needs-evidence:usage: check-windows-only-sources-verified.sh $_subcmd --from <cargo-test-output>; a stamp with no transcript is an assertion, not a verification"
        exit 1
    fi
    TRANSCRIPT="$(read_transcript "$TRANSCRIPT_FROM")"
    # HERE-STRING, NOT A PIPE (order 792-ksr8). `$TRANSCRIPT` is a whole cargo
    # test transcript; `grep -q` exits on first match and SIGPIPEs the still
    # writing producer, which `set -uo pipefail` then promotes to the pipeline's
    # status even on a MATCH. A false "no tests ran" here would record a
    # verification that never happened.
    if ! grep -qE '^test .* \.\.\. (ok|FAILED|ignored)' <<<"$TRANSCRIPT"; then # sigpipe-ok: safe pipeline
        echo "refused:stamp-needs-evidence:the transcript contains no test results"
        exit 1
    fi
    known_red="$ROOT/scripts/windows-only-known-red.txt"
    undeclared=""
    failures="$(grep -E '^test .* \.\.\. FAILED' <<<"$TRANSCRIPT" | awk '{print $2}' | sed 's/.*:://')"
    for name in $failures; do
        if [ -f "$known_red" ] && grep -qxF "$name" "$known_red"; then
            continue
        fi
        [ -z "$undeclared" ] && undeclared="$name"
    done
    if [ -n "$undeclared" ]; then
        echo "refused:undeclared-failure:$undeclared"
        exit 1
    fi
    # A multi-binary run emits one `test result:` line per binary; join them all
    # rather than taking the first, which would under-record what was proven.
    RESULT_LINE="$(grep -E '^test result:' <<<"$TRANSCRIPT" | sed 's/"/'"'"'/g' | tr '\n' ';' | sed 's/;$//')"
    [ -n "$RESULT_LINE" ] || RESULT_LINE="test results present; no summary line"
}

case "${1:-check}" in
    stamp)
        # The stamp is a CLAIM, so it is checked rather than trusted. Feed it the
        # test transcript: any FAILED test not declared known-red refuses the
        # stamp. Without this the subcommand is an honour system, and an honour
        # system is what this whole report was built to replace.
        # ORDER 801-ajcd — THE REFUSAL MUST PARSE AS THE COMMAND IT DEMANDS.
        #
        # This message used to read `pass --from <cargo-test-output>`, where
        # "pass" was an English verb. Read as what it looks like — an argument
        # list — obeying it verbatim produces
        # `… stamp pass --from out.txt`, whose $2 is `pass`, which matches
        # nothing here, so the refusal repeats identically. A guard whose own
        # instructions are refused teaches the reader that the guard is broken
        # rather than that the evidence is missing, and the next move after that
        # is to route around it.
        #
        # Two changes, both directions of the mismatch:
        #   * the message now prints the EXACT argv after `usage: `, so copying
        #     it works (the fixture extracts and executes that substring, so the
        #     text can never drift from the parser again);
        #   * the parser accepts a leading `pass` token, so anyone who obeyed the
        #     old wording — or a script written from it during the weeks it was
        #     live — is answered rather than refused twice.
        # CONCURRENT CORRECT FIXES, resolved 2026-08-20, both preserved inside
        # require_evidence(): 801-ajcd made the refusal message parse as the
        # command it demands, and 792-ksr8 replaced a verdict pipe with a
        # here-string. Neither supersedes the other and taking either side alone
        # silently drops a real fix. Recorded because the merge machinery cannot
        # tell this case from a genuine either/or.
        parse_from_arg "${2:-}" "${3:-}" "${4:-}"
        require_evidence stamp
        printf '%s\n' "$current" > "$STAMP_FILE"
        # Per-file records too, so `check` can NAME the file that moved rather
        # than reporting the aggregate and picking whichever source sorts first
        # as the culprit. That first version gave a confident wrong answer,
        # which is the failure this whole check exists to prevent.
        rm -rf "$STAMP_FILE.d"
        mkdir -p "$STAMP_FILE.d"
        for f in "${SOURCES[@]}"; do
            rel="${f#"$ROOT"/}"
            printf '%s\n' "$f" | digest_of \
                > "$STAMP_FILE.d/$(printf '%s' "$rel" | tr '/' '_')"
        done
        echo "ok:sources-verified:$SCOPE:${#SOURCES[@]}"
        ;;
    attest)
        # ORDER 738-3pft. The same checked claim as `stamp`, written where the
        # OTHER hosts can read it. One command: `--from -` takes the transcript
        # on stdin, so a native run pipes straight into it.
        _host_label=""
        _args_start=2
        if [ "${2:-}" = "--host" ]; then
            _host_label="${3:-}"
            _args_start=4
        fi
        [ -n "$_host_label" ] || _host_label="$(default_host_label)"
        eval "parse_from_arg \"\${$_args_start:-}\" \"\${$((_args_start + 1)):-}\" \"\${$((_args_start + 2)):-}\""
        require_evidence attest
        # Provenance only, never the staleness key — and it must not be fatal:
        # the fixture runs against a throwaway tree that is not a git repo, and
        # a writer that dies there could not be proven to work at all.
        _commit="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || _commit=""
        [ -n "$_commit" ] || _commit="unknown"
        _known_red_list=""
        if [ -f "$ROOT/scripts/windows-only-known-red.txt" ]; then
            while IFS= read -r _kr; do
                [ -n "$_kr" ] || continue
                if [ -n "$_known_red_list" ]; then
                    _known_red_list="$_known_red_list, \"$_kr\""
                else
                    _known_red_list="\"$_kr\""
                fi
            done < "$ROOT/scripts/windows-only-known-red.txt"
        fi
        mkdir -p "$ATTEST_DIR"
        _out="$ATTEST_DIR/$SCOPE-sources.$_host_label.json"
        {
            printf '{\n'
            printf '  "scope": "%s",\n' "$SCOPE"
            printf '  "host": "%s",\n' "$_host_label"
            printf '  "attested_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            printf '  "commit": "%s",\n' "$_commit"
            printf '  "command": "%s",\n' "${WINDOWS_ONLY_ATTEST_COMMAND:-cargo test -p tillandsias-windows-tray --bins}"
            printf '  "result": "%s",\n' "$RESULT_LINE"
            printf '  "sources": {\n'
            _n=0
            for f in "${SOURCES[@]}"; do
                rel="${f#"$ROOT"/}"
                _n=$((_n + 1))
                if [ "$_n" -lt "${#SOURCES[@]}" ]; then
                    printf '    "%s": "%s",\n' "$rel" "$(blob_hash_of "$f")"
                else
                    printf '    "%s": "%s"\n' "$rel" "$(blob_hash_of "$f")"
                fi
            done
            printf '  },\n'
            printf '  "known_red": [%s]\n' "$_known_red_list"
            printf '}\n'
        } > "$_out"
        echo "wrote $_out" >&2
        echo "ok:sources-attested:$SCOPE:${#SOURCES[@]}"
        ;;
    check)
        # EVIDENCE ORDER (order 738-3pft): a TRACKED attestation first, then the
        # host-local stamp. The tracked file is the one every host can see, so a
        # repository carrying one must never report as if nothing were verified —
        # that misreport is the defect this packet exists to close.
        _attestation=""
        for _cand in "$ATTEST_DIR/$SCOPE-sources."*.json; do
            [ -f "$_cand" ] || continue
            _attestation="$_cand"
            break
        done

        if [ -n "$_attestation" ]; then
            # Recompute every hash locally. This is what makes the file evidence
            # rather than a promise: the reader never trusts the writer's
            # "89 passed", it checks that the bytes they ran against are the
            # bytes it has.
            _drifted=0
            _first=""
            for f in "${SOURCES[@]}"; do
                rel="${f#"$ROOT"/}"
                _have="$(blob_hash_of "$f")"
                # Line-oriented read of the one field that matters; no YAML/JSON
                # interpreter, because this gate runs in the forge, on the bare
                # host and in the builder toolbox and no parser exists in all
                # three (order 746-htj9).
                _want="$(grep -F "\"$rel\":" "$_attestation" 2>/dev/null | head -1 | sed 's/.*: *"//; s/".*//')"
                if [ -n "$_want" ] && [ "$_want" = "$_have" ]; then
                    continue
                fi
                _drifted=$((_drifted + 1))
                [ -z "$_first" ] && _first="$rel"
            done
            if [ "$_drifted" -eq 0 ]; then
                echo "ok:sources-verified:$SCOPE:${#SOURCES[@]}"
                exit 0
            fi
            echo "stale:sources-drifted:$SCOPE:$_drifted:$_first"
            exit 0
        fi

        if [ ! -f "$STAMP_FILE" ]; then
            # A statement about THIS REPOSITORY, not about whether anyone ever
            # ran the tests. See the header: the old `never-verified` spelling is
            # what got quoted to an operator as a claim about the sources.
            echo "missing:sources-no-attestation:$SCOPE"
            exit 0
        fi
        recorded="$(cat "$STAMP_FILE" 2>/dev/null)"
        if [ "$recorded" = "$current" ]; then
            echo "ok:sources-verified:$SCOPE:${#SOURCES[@]}"
            exit 0
        fi
        # Name the first changed file. "Something changed" sends the next agent
        # diffing the whole crate; naming it is the difference between a report
        # and a rumour.
        changed=0
        first=""
        for f in "${SOURCES[@]}"; do
            rel="${f#"$ROOT"/}"
            per_file="$(printf '%s\n' "$f" | digest_of)"
            prev_file="$STAMP_FILE.d/$(printf '%s' "$rel" | tr '/' '_')"
            if [ -f "$prev_file" ] && [ "$(cat "$prev_file")" = "$per_file" ]; then
                continue
            fi
            changed=$((changed + 1))
            [ -z "$first" ] && first="$rel"
        done
        # If per-file records are absent (a stamp written by an older version),
        # say the whole set moved rather than inventing a culprit.
        if [ "$changed" -eq 0 ]; then
            changed="${#SOURCES[@]}"
            first="all(no-per-file-records)"
        fi
        echo "stale:sources-drifted:$SCOPE:$changed:$first"
        ;;
    *)
        echo "usage: check-windows-only-sources-verified.sh [check|stamp|attest]" >&2
        exit 2
        ;;
esac
exit 0

#!/usr/bin/env bash
# @trace spec:meta-orchestration
# @trace order:989-ykks, order:988-7kxf
#
# check-host-tools.sh — does THIS host have the tools the gate needs?
#
# WHY THIS EXISTS. The host-tool prerequisites were prose in a skill that a
# human maintained, and in one week that prose was wrong in two ways at once:
# `coreutils` was missing from it and is a HARD requirement of the credential
# gate (988-7kxf), and `pkg-config` was missing from it without which
# `./build.sh --check` could not start at all. A factory-fresh Mac surfaced six
# assumed-present tools in a single day.
#
# THE COST IS PAID BY THE HOST THAT LACKS THE TOOL, and it is paid as an
# UNRELATED failure hours later: a missing `timeout(1)` produced a
# keyring-shaped verdict about a platform with no keyring. Nobody debugging that
# would think to check for GNU coreutils.
#
# WORSE, THE HOST THAT HAS THE TOOL CANNOT DETECT ANY OF THIS. It reports
# `ok:` and lands all night. That asymmetry — the lucky host producing green
# evidence that makes the unlucky host's failure look local to them — is why
# this must be a probe and not a list. A list is only ever written by someone
# whose machine already works.
#
# Verdict grammar, one line on stdout:
#   ok:host-tools:<platform>:<n> required present            exit 0
#   missing:host-tools:<platform>:<csv>                      exit 1
#   blocked:<reason>                                         exit 2
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$(uname -s)" in
    Darwin)                       PLATFORM=macos ;;
    Linux)                        PLATFORM=linux ;;
    MINGW*|MSYS*|CYGWIN*)         PLATFORM=windows ;;
    *)                            PLATFORM=unknown ;;
esac
ADVISORY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --platform) PLATFORM="${2:-$PLATFORM}"; shift 2 ;;
        --advisory) ADVISORY=1; shift ;;
        *) echo "usage: check-host-tools.sh [--platform <macos|linux|windows>] [--advisory]" >&2; exit 2 ;;
    esac
done

# ── the REQUIRED set ────────────────────────────────────────────────────────
#
# EVERY ENTRY HERE IS EMPIRICALLY VERIFIED, not asserted:
# scripts/test-host-tools.sh hides each one and asserts the gate actually fails
# without it. That is what keeps this list from becoming the same prose it
# replaces — a wrong entry is caught by its own fixture.
#
# It is deliberately SHORT. Most `command -v` sites in scripts/ are probes with
# a fallback, and listing those would report a working host as broken. The
# question here is only: without this tool, does `./build.sh --check` FAIL?
#
# Format: <tool>|<platforms>|<why>|<remedy>
required_tools() {
    # <tool>|<kind>|<scope>|<platforms>|<prover>|<expect>|<why>|<remedy>
    #
    # ORDER 1004-cp6p. TWO COLUMNS, BOTH ADDED BECAUSE ONE UNDIFFERENTIATED LIST
    # ANSWERED A QUESTION NOBODY ASKED.
    #
    # <scope> names the CONSUMER that requires the entry. Until now every entry
    # was implicitly gate-scoped, so a Mac read `ok:host-tools:macos:5 required
    # present` and concluded "this host is equipped" — then died at
    # build-macos-tray.sh:45 in under a second on a missing zig. The verdict was
    # TRUE as written and MISLEADING as used: those five are what ./build.sh
    # --check needs, and the reader was about to run the platform's own build.
    #   gate ......... ./build.sh --check cannot start without it. Terminal.
    #   tray-build ... scripts/build-macos-tray.sh cannot start without it.
    #                  ADVISORY to the gate: a host that never builds the tray is
    #                  not broken, and failing --check on it would enforce more
    #                  than this packet describes.
    #
    # <kind> exists because A PREREQUISITE IS NOT ALWAYS A BINARY. Every entry
    # was resolved with `command -v`, so a missing rustup target was invisible by
    # construction — macneo lost 166 seconds to `E0463 can't find crate for
    # core` on x86_64-unknown-linux-musl while aarch64 succeeded, an asymmetry no
    # `command -v` could ever have reported.
    #   binary ......... resolved with command -v, through the prefix search.
    #   rustup-target .. resolved by asking `rustup target list --installed`.
    #                    ASK THE SUBSYSTEM WHAT IT HAS; do not stat a path and
    #                    infer. The triple is the tool name.
    #
    # <prover> is a check script that FAILS without the tool, so every claim
    # carries its own falsification and scripts/test-host-tools.sh runs it.
    # `-` means no cheap prover exists and the gate itself is the evidence;
    # the fixture then REPORTS how many entries it could not verify rather
    # than pretending it verified them.
    #
    # jq is NOT here, and that is a measurement rather than an omission:
    # with jq absent the credential guard and the long-running view both
    # still pass, because each prefers the compiled plan binary and only
    # falls back to jq. Listing it would report a working host as broken.
    cat <<'SPEC'
git|binary|gate|macos,linux,windows|check-committable-branch.sh|blocked:not-a-git-repo|every check reads the outgoing diff|xcode-select --install
timeout|binary|gate|macos|check-credential-channel.sh|blocked:gh-cli-only|GNU coreutils. check-credential-channel.sh bounds gh api with it; without it the probe returns 127 and the guard reported a KEYRING fault on a platform with no keyring (988-7kxf). MEASURED here: omitting timeout AND gtimeout flips ok:gh-keyring-push-verified to blocked:gh-cli-only. PRECONDITION (1004-x9ua): this prover only reaches the timeout dependency AFTER the credential guard gets past its token arm, so on a host with a dead or absent gh token it answers missing:no-credential-channel either way and proves nothing about coreutils. test-host-tools.sh detects that by comparing the with-tool and without-tool verdicts and SKIPS, named, rather than reporting a coreutils fault|brew install coreutils
cargo|binary|gate|macos,linux,windows|-|-|the gate compiles and clippies the workspace|rustup toolchain install stable
rustc|binary|gate|macos,linux,windows|-|-|same as cargo|rustup toolchain install stable
pkg-config|binary|gate|macos|-|-|the workspace build needs it to locate native deps; without it --check cannot start. NOT self-measured: reported by macneo-macos on a factory-fresh Mac 2026-09-03|brew install pkg-config
openssl|binary|gate|linux|-|-|ORDER 1042-svey. The gate's CA-generating test (source_built_init_and_status_check_smoke_uses_fake_podman -> ensure_ca_bundle) shells out to the openssl COMMAND. Without it that test dies with os error 2 ELEVEN MINUTES into the run, long after this step passed. Tagged linux because on Windows the gate re-execs into the tillandsias-build WSL2 distro and this check reports ok:host-tools:linux — a windows tag would never fire during a gate. NOT self-measured by a prover: the only thing that fails is a Rust test, not a check script, so the honest entry is '-' and the fixture counts it unverified rather than pretending otherwise|dnf install -y openssl
codesign|binary|tray-build|macos|-|-|build-macos-tray.sh:43 signs the .app; without it the build dies before compiling|xcode-select --install
shasum|binary|tray-build|macos|-|-|build-macos-tray.sh:44 hashes the staged guest binary for the provenance sidecar|xcode-select --install
zig|binary|tray-build|macos|-|-|build-macos-tray.sh:45. MEASURED by macneo-macos 2026-09-04: absent, the build exits rc=1 in under a second with its whole output being "ERROR: zig not in PATH", while check-host-tools said ok:host-tools:macos:5 required present|brew install zig
cargo-zigbuild|binary|tray-build|macos|-|-|build-macos-tray.sh:46, the linker driver for the musl guest cross-builds below|cargo install cargo-zigbuild
aarch64-unknown-linux-musl|rustup-target|tray-build|macos|-|-|build-macos-tray.sh:141 builds the guest binary for this triple|rustup target add aarch64-unknown-linux-musl
x86_64-unknown-linux-musl|rustup-target|tray-build|macos|-|-|build-macos-tray.sh:142. MEASURED: installed for aarch64 and NOT x86_64, so the first cross-build succeeded and the second died with E0463 "can't find crate for core" after 166 seconds. A command -v could not have seen either|rustup target add x86_64-unknown-linux-musl
SPEC
}

# ── advisory: tools the scripts THEMSELVES probe for, that are absent ────────
#
# DERIVED, not listed — this scan updates itself when a new check adds a
# `command -v` guard, which is the drift the packet names. These are NOT
# failures: a `command -v` site by definition has a fallback path, and this host
# passes its gate today with `yq` absent, which is the proof.
#
# Reported anyway because "the fallback is being taken" is worth knowing before
# it becomes "the fallback was wrong" — that is exactly how the credential guard
# failed.
derived_probed_tools() {
    grep -rhoE 'command -v "?[a-z0-9][a-z0-9_.-]*"?' "$ROOT"/scripts/*.sh "$ROOT"/build.sh 2>/dev/null \
        | sed 's/command -v //; s/"//g' \
        | sort -u
}

# ── resolving a tool before declaring it absent (1004-x9ua) ─────────────────
#
# ORDER 1004-x9ua. This check answered a question about the OPERATOR'S SHELL and
# reported it as a question about the HOST. rustup and Homebrew both write their
# PATH edit into a shell rc file, and a non-login non-interactive shell never
# sources it — which is EXACTLY the kind of shell every agent tool call gets.
#
# MEASURED on tlatoanis-macbook-air 2026-09-05, under the PATH such a call sees:
#   env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin bash scripts/check-host-tools.sh
#   -> missing:host-tools:macos:timeout,cargo,rustc,pkg-config
# with ALL FOUR installed: timeout, gtimeout and pkg-config in /opt/homebrew/bin,
# cargo and rustc in ~/.cargo/bin (cargo 1.96.1 runs). Two prefixes, not one —
# the filed diagnosis named ~/.cargo/bin and would have left timeout and
# pkg-config still lying.
#
# WHY THAT IS WORSE THAN A WRONG ANSWER. Every one of those four printed a
# remedy telling the operator to install what they already had. An operator who
# follows `brew install coreutils` installs a package that is present and the
# check stays red, which is the 980-xcaf `brew install qemu` shape this file's
# own header warns about.
#
# THIS IS 876-irn7 AGAIN, AND IT IS THE FIFTH SITE. The registry is
# scripts/lib-cargo-sites.sh, which asks that the next site be ADDED there rather
# than discovered on a floor host; this file is now listed in it, together with
# the reason it resolves through its own list instead of calling cargo_resolve
# (it must cover /opt/homebrew/bin too, and its fixture has to be able to
# construct absence for an absolute prefix). check-cheatsheet-tiers.sh:57, named
# in this packet as an open third site, was ALREADY FIXED by 1005-m6rz before
# this cycle — verified here, not assumed: under `env -i PATH=/usr/bin:/bin` it
# resolves and reports OK rather than a bare command-not-found.
#
# The shape below is deliberately the one cycle-preflight already established
# rather than a second convention: CARGO_HOME first (a host that set it meant
# it), then the standard prefixes, and put the resolved directory ON PATH so
# every later caller in this process sees it too.
#
# THE GENUINELY-ABSENT CASE KEEPS ITS VERDICT AND ITS TERMINAL FORCE. This
# narrows a false positive; it must not weaken the true one.
tool_prefixes() {
    # A TEST SEAM, and the reason it has to exist: every prefix below except the
    # cargo ones is an ABSOLUTE path, so a fixture on a host that really has
    # /opt/homebrew/bin cannot construct the genuinely-absent case for a tool
    # living there — it can farm $HOME and $CARGO_HOME and nothing else. Without
    # this seam, criterion 4's "a host with no cargo anywhere still fails" is
    # provable for cargo and UNPROVABLE for timeout and pkg-config, and the arm
    # would quietly cover half of what it claims.
    #
    # Distinct from the CYCLE_PREFLIGHT_SKIP_BUILD shape 1004-ws5q declined: that
    # was a production escape hatch a human had to remember. This is exercised by
    # scripts/test-host-tools.sh on every gate run, so it cannot rot unnoticed,
    # and unset it changes nothing about how the check behaves on a real host.
    if [ -n "${TILLANDSIAS_HOST_TOOL_PREFIXES:-}" ]; then
        printf '%s\n' "$TILLANDSIAS_HOST_TOOL_PREFIXES" | tr ':' '\n'
        return 0
    fi
    # CARGO_HOME first, then rustup's default, then Homebrew's three standard
    # prefixes (Apple silicon, Intel, linuxbrew). Not derived from `brew
    # --prefix`, because brew itself is off the same PATH this is repairing.
    [ -n "${CARGO_HOME:-}" ] && echo "$CARGO_HOME/bin"
    echo "$HOME/.cargo/bin"
    echo "/opt/homebrew/bin"
    echo "/usr/local/bin"
    echo "/home/linuxbrew/.linuxbrew/bin"
}

# Names that satisfy a requirement without carrying it. NOT a convenience list:
# each is read off the CONSUMER's own fallback, so this file cannot drift into
# accepting something the gate would then reject.
#   timeout -> gtimeout: check-credential-channel.sh:17-20 takes either.
alternates_for() {
    case "$1" in
        timeout) [ "$PLATFORM" = macos ] && echo gtimeout ;;
        *) : ;;
    esac
}

# Resolve $1 onto PATH if it exists in a standard prefix. Returns 0 if the name
# is callable afterwards. Exports PATH so later callers inherit the repair.
_resolve_onto_path() {
    command -v "$1" >/dev/null 2>&1 && return 0
    local _dir
    while IFS= read -r _dir; do
        [ -n "$_dir" ] || continue
        case "$_dir" in /bin) continue ;; esac
        if [ -x "$_dir/$1" ]; then
            PATH="$_dir:$PATH"
            export PATH
            return 0
        fi
    done <<EOF
$(tool_prefixes)
EOF
    return 1
}

have() {
    _resolve_onto_path "$1" && return 0
    local _alt
    for _alt in $(alternates_for "$1"); do
        _resolve_onto_path "$_alt" && return 0
    done
    return 1
}

missing=""
present=0
# ORDER 1004-cp6p. `rustup target list --installed` is asked ONCE and cached:
# it is a subprocess, and the alternative is one per declared target. Empty when
# rustup is absent, which is correct — no rustup means no installed targets, and
# every rustup-target entry then reports missing with `rustup target add` as its
# remedy, which is the actionable line.
_installed_targets=""
if command -v rustup >/dev/null 2>&1; then
    _installed_targets="$(rustup target list --installed 2>/dev/null || true)"
fi

# Is this declared prerequisite present? Dispatches on <kind>, because a rustup
# target is not on PATH and `command -v` would report it missing forever.
have_kind() { # $1=kind $2=name
    case "$1" in
        rustup-target)
            printf '%s\n' "$_installed_targets" | grep -qx -- "$2"
            ;;
        *)
            have "$2"
            ;;
    esac
}

tray_missing=""
tray_present=0
while IFS='|' read -r tool kind scope platforms prover expect why remedy; do
    [ -n "$tool" ] || continue
    case ",$platforms," in *",$PLATFORM,"*) ;; *) continue ;; esac
    if have_kind "$kind" "$tool"; then
        if [ "$scope" = tray-build ]; then
            tray_present=$((tray_present + 1))
        else
            present=$((present + 1))
        fi
        continue
    fi
    # ABSENT. Which scope decides whether this is terminal.
    if [ "$scope" = tray-build ]; then
        tray_missing="${tray_missing:+$tray_missing,}$tool"
        {
            echo "  MISSING (tray-build): $tool"
            echo "    needed because: $why"
            echo "    remedy: $remedy"
        } >&2
        continue
    fi
    missing="${missing:+$missing,}$tool"
    {
        echo "  MISSING: $tool"
        echo "    needed because: $why"
        echo "    remedy: $remedy"
        # ORDER 1066-dkkb: state the boundary of what was inspected, so a
        # reader can tell "not installed" from "not where I looked". The
        # prefix list below is standard, not exhaustive, and a tool sitting
        # somewhere else would otherwise get the same confident remedy that
        # sent an operator to reinstall what they already had.
        echo "    searched PATH plus: $(tool_prefixes | tr '\n' ' ')"
        echo "    if it IS installed elsewhere this is a PATH fault, not a missing tool — put its directory on PATH (agent shells are non-login and never source your rc file)"
    } >&2
done <<EOF
$(required_tools)
EOF

# The advisory half, on stderr so it never competes with the verdict.
absent_probed=""
while IFS= read -r t; do
    [ -n "$t" ] || continue
    # Skip repo-defined shell functions and project binaries: they are not host
    # tools, and reporting them would bury the real answer in noise.
    case "$t" in tillandsias*|resolve_*|timing_emit|metrics_default_log|fast_tool|materialize_tool|make_no_tool_path|ensure_forge_git_index|harness_contract_ok) continue ;; esac
    have "$t" || absent_probed="${absent_probed:+$absent_probed,}$t"
done <<EOF
$(derived_probed_tools)
EOF
# OPT-IN. On macOS this list legitimately includes apt-get, dnf, wsl.exe and
# other platforms' tools, so printing it every run buries the verdict in names
# nobody on this host can act on. --advisory when you want it.
if [ "$ADVISORY" = 1 ] && [ -n "$absent_probed" ]; then
    echo "  advisory (probed-for, absent, each has a fallback path): $absent_probed" >&2
fi

# ORDER 1004-cp6p. THE VERDICT NAMES THE SCOPE IT COVERED.
#
# `ok:host-tools:macos:5 required present` was true and misleading: a reader on
# a Mac took it as "this host is equipped" and then could not start the tray
# build. A bare count cannot say which question it answered, so it gets read as
# answering the one the reader has in mind. Naming the scope is the difference
# between "nothing is wrong" and "nothing is wrong WITHIN WHAT I LOOKED AT" —
# the 1066-dkkb rule applied to a verdict rather than to a guard's coverage.
#
# GATE SCOPE KEEPS ITS TERMINAL FORCE. A tray-build shortfall is reported and
# does NOT fail: a host that never builds the tray is not broken, and failing
# --check there would enforce more than this packet describes.
if [ -n "$missing" ]; then
    echo "missing:host-tools:$PLATFORM:gate:$missing"
    exit 1
fi
if [ -n "$tray_missing" ]; then
    echo "ok:host-tools:$PLATFORM:gate:$present present; tray-build:$tray_present present, missing $tray_missing"
else
    echo "ok:host-tools:$PLATFORM:gate:$present present; tray-build:$tray_present present"
fi

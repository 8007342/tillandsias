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
    # <tool>|<platforms>|<prover>|<expect>|<why>|<remedy>
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
git|macos,linux,windows|check-committable-branch.sh|blocked:not-a-git-repo|every check reads the outgoing diff|xcode-select --install
timeout|macos|check-credential-channel.sh|blocked:gh-cli-only|GNU coreutils. check-credential-channel.sh bounds gh api with it; without it the probe returns 127 and the guard reported a KEYRING fault on a platform with no keyring (988-7kxf). MEASURED here: omitting timeout AND gtimeout flips ok:gh-keyring-push-verified to blocked:gh-cli-only|brew install coreutils
cargo|macos,linux,windows|-|-|the gate compiles and clippies the workspace|rustup toolchain install stable
rustc|macos,linux,windows|-|-|same as cargo|rustup toolchain install stable
pkg-config|macos|-|-|the workspace build needs it to locate native deps; without it --check cannot start. NOT self-measured: reported by macneo-macos on a factory-fresh Mac 2026-09-03|brew install pkg-config
openssl|linux|-|-|ORDER 1042-svey. The gate's CA-generating test (source_built_init_and_status_check_smoke_uses_fake_podman -> ensure_ca_bundle) shells out to the openssl COMMAND. Without it that test dies with os error 2 ELEVEN MINUTES into the run, long after this step passed. Tagged linux because on Windows the gate re-execs into the tillandsias-build WSL2 distro and this check reports ok:host-tools:linux — a windows tag would never fire during a gate. NOT self-measured by a prover: the only thing that fails is a Rust test, not a check script, so the honest entry is '-' and the fixture counts it unverified rather than pretending otherwise|dnf install -y openssl
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

have() { command -v "$1" >/dev/null 2>&1; }

missing=""
present=0
while IFS='|' read -r tool platforms prover expect why remedy; do
    [ -n "$tool" ] || continue
    case ",$platforms," in *",$PLATFORM,"*) ;; *) continue ;; esac
    if have "$tool"; then
        present=$((present + 1))
    else
        missing="${missing:+$missing,}$tool"
        {
            echo "  MISSING: $tool"
            echo "    needed because: $why"
            echo "    remedy: $remedy"
        } >&2
    fi
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

if [ -n "$missing" ]; then
    echo "missing:host-tools:$PLATFORM:$missing"
    exit 1
fi
echo "ok:host-tools:$PLATFORM:$present required present"

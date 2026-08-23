#!/usr/bin/env bash
# derive-host-identity.sh — ONE deterministic, unique, meaningful host slug.
#
# WHY THIS EXISTS. `select-work-batch.sh` defaulted its seed to
# `${TILLANDSIAS_HOST_KIND:-host}-$(date -u +%Y%m%d)` — host KIND and date, not
# host IDENTITY. Every Silverblue box in the fleet therefore derived the SAME
# default seed on the same day, and the documented workaround was "remember to
# pass --seed". An invariant that depends on nine operators remembering a flag
# is not an invariant.
#
# The operator's requirement (2026-08-22): hosts must be deterministically
# unique BY HOSTNAME, and the name should carry meaning — os group, hardware
# tier, accelerator mix — so a fleet roster is readable rather than a list of
# opaque tokens.
#
# GRAMMAR:  <osgroup>-<cpu>-<accel>-<hostname>
#   e.g.    silverblue-ryzen7-nvidia+amd-thinkpad
#           linux-xeon-nvidia-macuahuitl
#           macos-m5-apple-airbook
#           windows-ryzen7-amd+npu-desktop
#
# UNIQUENESS is carried by the hostname component alone; every other component
# is descriptive. Two hosts that share a hostname are the same host as far as
# this fleet is concerned, which is the operator's stated model.
#
# DEGRADES, NEVER GUESSES. Any component that cannot be established prints
# `unknown` rather than a plausible token. A wrong tier silently mis-routes
# work; an honest `unknown` is visible in the roster and gets fixed.
#
# NO BUILD REQUIRED. A fresh clone on a host that has never compiled anything
# must be able to run this — it is read by the FIRST work-selection call, long
# before `tillandsias --capabilities` exists. So: /proc, /etc/os-release,
# uname, and optional lspci/nvidia-smi. Nothing cargo, nothing podman.
set -uo pipefail

# ---------------------------------------------------------------- os group
os_group() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        Darwin) echo macos; return ;;
        MINGW* | MSYS* | CYGWIN*) echo windows; return ;;
        Linux) : ;;
        *) echo unknown; return ;;
    esac
    # A forge container is its own group: it is ephemeral and must never be
    # confused with the durable host it runs on.
    [ "${TILLANDSIAS_HOST_KIND:-}" = forge ] && { echo forge; return; }
    # Immutable Linux. Two markers disagree in the wild, so accept EITHER —
    # /run/ostree-booted is the skill's test, VARIANT_ID is what
    # with-tillandsias-builder.sh tests, and a host that satisfies one but not
    # the other is still immutable for our purposes.
    if [ -f /run/ostree-booted ] || command -v rpm-ostree >/dev/null 2>&1; then
        echo silverblue
        return
    fi
    if [ -r /etc/os-release ] &&
        grep -qE '^VARIANT_ID=(silverblue|kinoite|sericea|onyx)' /etc/os-release; then
        echo silverblue
        return
    fi
    echo linux
}

# ---------------------------------------------------------------- cpu token
cpu_token() {
    local model=""
    if [ -r /proc/cpuinfo ]; then
        model="$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"
    elif [ "$(uname -s 2>/dev/null)" = Darwin ]; then
        model="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || true)"
    fi
    [ -n "$model" ] || { echo unknown; return; }
    # Ordered most-specific first: Apple silicon, Ryzen, Core i, Xeon, Threadripper.
    case "$model" in
        *"Apple M"*) printf 'm%s\n' "$(printf '%s' "$model" | sed -n 's/.*Apple M\([0-9]*\).*/\1/p')"; return ;;
        *Threadripper*) echo threadripper; return ;;
        *"Ryzen 9"*) echo ryzen9; return ;;
        *"Ryzen 7"*) echo ryzen7; return ;;
        *"Ryzen 5"*) echo ryzen5; return ;;
        *"Ryzen 3"*) echo ryzen3; return ;;
        *Xeon*) echo xeon; return ;;
        *"Core"*"i9"*) echo i9; return ;;
        *"Core"*"i7"*) echo i7; return ;;
        *"Core"*"i5"*) echo i5; return ;;
        *"Core"*"i3"*) echo i3; return ;;
        *"Core"*"Ultra"*) echo core-ultra; return ;;
        *Celeron* | *Pentium* | *"N100"* | *"N95"*) echo lowpower; return ;;
    esac
    echo unknown
}

# ------------------------------------------------------------ accelerators
# A SET, sorted and deduplicated, so the token is stable across probe order.
# Vendor-level only: this names what class of accelerator the host HAS, not
# whether it is usable — usability is the capability matrix's job (808-7yrd)
# and requires a built binary this script deliberately does not depend on.
accel_token() {
    local found=""
    add() { case " $found " in *" $1 "*) ;; *) found="$found $1" ;; esac; }

    if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
        add nvidia
    fi
    # PARSE THE CLASS FIELD, never substring-match the whole lspci line. Both
    # obvious greps are wrong on real hardware, verified on macuahuitl:
    #   "VGA compatible controller"   contains  ati   (comp-ATI-ble) -> false AMD
    #   "Non-VGA unclassified device" contains  vga                  -> false GPU
    # `lspci -mm` quotes each field, so class and vendor can be read as fields
    # instead of guessed at from a sentence.
    if command -v lspci >/dev/null 2>&1; then
        local gpuvendors
        gpuvendors="$(lspci -mm 2>/dev/null | awk -F'"' '
            $2 == "VGA compatible controller" ||
            $2 == "3D controller" ||
            $2 == "Display controller" { print tolower($4) }')"
        case "$gpuvendors" in *nvidia*) add nvidia ;; esac
        case "$gpuvendors" in *advanced\ micro\ devices* | *amd* | *ati\ technologies*) add amd ;; esac
        case "$gpuvendors" in *intel*) add intel ;; esac
    fi
    # NPU. The accel subsystem is vendor-neutral: AMD XDNA (Ryzen AI) and Intel
    # AI Boost (Core Ultra) both expose /dev/accel/accelN, so this token means
    # "an NPU is present", not "an AMD NPU is present". Verified on macuahuitl,
    # whose Core Ultra 7 265KF presents accel0 with no AMD silicon in the box.
    #
    # The root is overridable for the fixture ONLY. A device path cannot be
    # shadowed through PATH the way a command can, so without this seam the
    # test inherits whatever silicon the test machine has and stops being
    # hermetic — which is exactly how the first run of the fixture failed.
    if ls "${TILLANDSIAS_ACCEL_DEV_ROOT:-/dev/accel}"/accel* >/dev/null 2>&1; then
        add npu
    fi
    if [ "$(uname -s 2>/dev/null)" = Darwin ]; then
        add apple
    fi

    [ -n "$found" ] || { echo none; return; }
    # `+`-joined, sorted for stability.
    printf '%s\n' $found | LC_ALL=C sort -u | paste -sd+ -
}

# ---------------------------------------------------------------- hostname
# THE uniqueness component. Short form only: a FQDN embeds a network location
# that changes with the network, and a host that moves desks must not become a
# different worker.
host_token() {
    local h=""
    h="$(hostname -s 2>/dev/null || true)"
    [ -n "$h" ] || h="$(uname -n 2>/dev/null | cut -d. -f1 || true)"
    [ -n "$h" ] || [ ! -r /etc/hostname ] || h="$(cut -d. -f1 </etc/hostname)"
    [ -n "$h" ] || { echo unknown; return; }
    # Slugify: lowercase, non-alphanumerics to `-`, collapse, trim.
    # Plain BRE only (851-gpb5): `\+` is a GNU sed extension that BSD sed
    # reads as a LITERAL plus, so on macOS the substitution never fired and
    # `Yoga_ThinkPad` sailed through as `yoga_thinkpad` — two identities for
    # one host, on exactly the platform this script's own docstring exemplifies.
    printf '%s' "$h" |
        tr '[:upper:]' '[:lower:]' |
        sed -e 's/[^a-z0-9][^a-z0-9]*/-/g' -e 's/^--*//' -e 's/--*$//'
}

main() {
    case "${1:-}" in
        --help | -h)
            echo "usage: derive-host-identity.sh [--explain]"
            echo
            echo "Prints one deterministic slug: <osgroup>-<cpu>-<accel>-<hostname>"
            echo "Unique by hostname; descriptive in every other component."
            echo "Read-only. Requires no build, no podman, no network."
            echo
            echo "  --explain   print each component on its own line"
            return 0
            ;;
        --explain)
            printf 'os_group\t%s\n' "$(os_group)"
            printf 'cpu\t%s\n' "$(cpu_token)"
            printf 'accel\t%s\n' "$(accel_token)"
            printf 'hostname\t%s\n' "$(host_token)"
            return 0
            ;;
        "") : ;;
        *)
            echo "error: unknown argument ${1}" >&2
            return 2
            ;;
    esac
    printf '%s-%s-%s-%s\n' "$(os_group)" "$(cpu_token)" "$(accel_token)" "$(host_token)"
}

main "$@"

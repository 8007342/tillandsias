#!/usr/bin/env bash
# Fixture for scripts/derive-host-identity.sh.
#
# HERMETIC: injects fake `lspci` / `nvidia-smi` / `hostname` onto PATH so the
# vendor-detection logic is exercised against KNOWN hardware strings rather than
# whatever this machine happens to contain. A test that only passes on the box
# that wrote it cannot protect the other eight hosts in the fleet.
#
# THE TWO TRAPS THIS PINS, both found on real macuahuitl output 2026-08-22:
#   "VGA compatible controller"    contains  ati   (comp-ATI-ble)
#   "Non-VGA unclassified device"  contains  vga
# The first made a pure-NVIDIA host report AMD; the second made it report an
# Intel GPU it does not have. Both are substring matches on a sentence that
# should have been a parsed field, which is why the assertions below feed
# EXACTLY those strings.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$ROOT/scripts/derive-host-identity.sh"

pass=0
fail=0
ck() { # ck <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
        pass=$((pass + 1))
    else
        printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"
        fail=$((fail + 1))
    fi
}

BIN="$(mktemp -d "${TMPDIR:-/tmp}/host-identity-bin.XXXXXX")"
trap 'rm -rf "$BIN"' EXIT

# `hostname -s` is the uniqueness component; pin it so slugs are predictable.
mk_hostname() {
    cat >"$BIN/hostname" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$1"
EOF
    chmod +x "$BIN/hostname"
}

# lspci -mm emits quote-delimited fields; the real script reads \$2 (class) and
# \$4 (vendor). The fake reproduces that shape exactly.
mk_lspci() {
    { echo '#!/usr/bin/env bash'
      echo 'cat <<'"'"'PCI'"'"''
      printf '%s\n' "$@"
      echo 'PCI'
    } >"$BIN/lspci"
    chmod +x "$BIN/lspci"
}

# A stub that FAILS shadows the real binary; removing our copy would just let
# the host's own nvidia-smi answer and make the fixture non-hermetic.
no_nvidia_smi() {
    printf '#!/usr/bin/env bash\nexit 1\n' >"$BIN/nvidia-smi"
    chmod +x "$BIN/nvidia-smi"
}
yes_nvidia_smi() {
    printf '#!/usr/bin/env bash\necho "GPU 0: NVIDIA Fake"\n' >"$BIN/nvidia-smi"
    chmod +x "$BIN/nvidia-smi"
}

# /dev/accel cannot be shadowed through PATH, so the SUT exposes a root
# override for exactly this. Default it to an EMPTY dir: without that the
# fixture inherits the test machine's own NPU and every accel assertion picks
# up a token the fake hardware never declared. That is how the first run of
# this fixture failed — non-hermetic, on a machine whose Core Ultra has an NPU.
ACCEL_EMPTY="$BIN/accel-empty"
ACCEL_WITH="$BIN/accel-present"
mkdir -p "$ACCEL_EMPTY" "$ACCEL_WITH"
: >"$ACCEL_WITH/accel0"

run() {
    PATH="$BIN:$PATH" TILLANDSIAS_ACCEL_DEV_ROOT="${ACCEL_ROOT:-$ACCEL_EMPTY}" \
        bash "$SUT" "$@" 2>/dev/null
}
accel_of() { run --explain | awk -F'\t' '$1=="accel"{print $2}'; }

# ---------------------------------------------------------------- THE TRAPS
mk_hostname trapbox
no_nvidia_smi
mk_lspci '02:00.0 "VGA compatible controller" "NVIDIA Corporation" "GA102GL [RTX A5000]" -r a1 "" ""' \
    '80:14.5 "Non-VGA unclassified device" "Intel Corporation" "Device 7f2f" -r 10 "" ""'
ck "a pure-NVIDIA host does NOT report amd (comp-ATI-ble trap)" \
    "nvidia" "$(accel_of)"

mk_lspci '00:02.0 "Non-VGA unclassified device" "Intel Corporation" "Device 7f2f" -r 10 "" ""'
ck "a Non-VGA line alone yields no GPU at all (Non-VGA trap)" \
    "none" "$(accel_of)"

# ------------------------------------------------------------ REAL FLEET MIX
mk_lspci '01:00.0 "VGA compatible controller" "NVIDIA Corporation" "GA106M" -r a1 "" ""' \
    '05:00.0 "VGA compatible controller" "Advanced Micro Devices, Inc. [AMD/ATI]" "Rembrandt" -r c1 "" ""'
ck "the dual-vendor Silverblue laptop reports both, sorted" \
    "amd+nvidia" "$(accel_of)"

mk_lspci '00:02.0 "VGA compatible controller" "Intel Corporation" "Alder Lake-N [UHD Graphics]" -r 01 "" ""'
ck "the low-end Intel laptop reports intel only" \
    "intel" "$(accel_of)"

mk_lspci '05:00.0 "Display controller" "Advanced Micro Devices, Inc. [AMD/ATI]" "Raphael" -r c1 "" ""'
ck "a Display-controller-class AMD part is still found" \
    "amd" "$(accel_of)"

# NPU, both directions. The Ryzen-AI and Core-Ultra laptops differ from their
# siblings ONLY by this token, so a detector that never fires is invisible.
mk_lspci '00:02.0 "VGA compatible controller" "Advanced Micro Devices, Inc. [AMD/ATI]" "Phoenix" -r c1 "" ""'
ck "no accel device -> no npu token" "amd" "$(accel_of)"
ck "an accel device -> npu token, sorted into the set" \
    "amd+npu" "$(ACCEL_ROOT="$ACCEL_WITH" accel_of)"

# ------------------------------------------------------- UNIQUE BY HOSTNAME
mk_lspci '01:00.0 "VGA compatible controller" "NVIDIA Corporation" "GA106M" -r a1 "" ""'
mk_hostname alpha
a="$(run)"
mk_hostname beta
b="$(run)"
ck "identical hardware, different hostname -> DIFFERENT slug" \
    "differ" "$([ "$a" != "$b" ] && echo differ || echo same)"
ck "the hostname is the trailing component" \
    "beta" "${b##*-}"

# Determinism: the same host must derive the same slug on every call, forever.
mk_hostname alpha
d1="$(run)"
d2="$(run)"
ck "deterministic across invocations" "$d1" "$d2"

# Case and punctuation in a hostname must not produce two identities.
mk_hostname 'Yoga_ThinkPad'
ck "hostname is slugified, not passed through" \
    "yoga-thinkpad" "$(run | sed -E 's/.*-(yoga-thinkpad)$/\1/')"

# --------------------------------------------------------------- DEGRADATION
mk_hostname degraded
# An EMPTY stub, not `rm`. Deleting our fake merely unshadows the host's real
# lspci and the assertion silently starts measuring this machine again — the
# same non-hermeticity as the accel root, one line further down.
mk_lspci
no_nvidia_smi
ck "lspci reporting no display device -> accel is 'none', not a crash" \
    "none" "$(accel_of)"
ck "a degraded probe still exits 0" "0" "$(
    run >/dev/null 2>&1
    echo $?
)"

# ------------------------------------------------------------- ARGUMENT SAFETY
ck "--help exits 0" "0" "$(
    run --help >/dev/null 2>&1
    echo $?
)"
ck "--help prints usage" \
    "yes" "$(run --help | grep -q '^usage: derive-host-identity.sh' && echo yes || echo no)"
ck "an unknown argument exits 2" "2" "$(
    run --bogus >/dev/null 2>&1
    echo $?
)"
ck "a bare run prints exactly one line" \
    "1" "$(run | wc -l | tr -d ' ')"

printf 'derive-host-identity: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
echo "ok:derive-host-identity:$pass"

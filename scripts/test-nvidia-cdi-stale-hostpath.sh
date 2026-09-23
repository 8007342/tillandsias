#!/usr/bin/env bash
# @trace order:1248-j6vd
# test-nvidia-cdi-stale-hostpath.sh — the CDI currency check must notice a spec
# that mounts a file which no longer exists, not only a driver that moved.
#
# Measured on macuahuitl (1248-j6vd): the spec pinned libnvidia-egl-gbm.so.1.1.3,
# the host had moved to 1.1.4 under an UNCHANGED 610.57.04 driver, and
# nvidia-cdi-ensure.sh printed ok:nvidia-cdi:current:610.57.04 while every GPU
# container start died on the missing bind-mount source.
#
#   ARM 1  stamp matches, every hostPath exists -> current, no regeneration.
#   ARM 2  stamp matches, one hostPath is gone -> named stale, regenerated.
#          This is the arm that fails on the pre-fix script.
#   ARM 3  CONTROL: the driver moved -> regenerated, as before the change.
#   ARM 4  quoted hostPath values are read the same as bare ones.
#
# Hermetic: no GPU, no toolkit. nvidia-smi and nvidia-ctk are PATH stubs, the
# spec lives in a scratch TILLANDSIAS_CDI_DIR, and every hostPath is a scratch
# file this fixture creates or deletes. TILLANDSIAS_CDI_UNDER_TEST overrides the
# subject (mutation control: the pre-fix script must fail ARM 2).
set -u
REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="${TILLANDSIAS_CDI_UNDER_TEST:-$REAL_ROOT/scripts/nvidia-cdi-ensure.sh}"
fails=0; passes=0
ok()  { passes=$((passes + 1)); echo "ok: $1"; }
bad() { fails=$((fails + 1)); echo "FAIL: $1"; }

# scratch <live-driver>: prints the scratch dir. The ctk stub writes a spec whose
# hostPath is a file that EXISTS, and counts its own calls.
scratch() {
    local d
    d="$(mktemp -d "${TMPDIR:-/tmp}/cdi-stale.XXXXXX")"
    mkdir -p "$d/bin" "$d/cdi" "$d/lib"
    : > "$d/lib/libnvidia-ml.so.1"
    : > "$d/lib/libnvidia-egl-gbm.so.1.1.4"
    printf '#!/usr/bin/env bash\necho %s\n' "$1" > "$d/bin/nvidia-smi"
    cat > "$d/bin/nvidia-ctk" <<CTK
#!/usr/bin/env bash
echo call >> "$d/ctk-calls"
out=""
for a in "\$@"; do case "\$a" in --output=*) out="\${a#--output=}" ;; esac; done
printf 'cdiVersion: 0.7.0\nkind: nvidia.com/gpu\ncontainerEdits:\n  mounts:\n  - hostPath: %s\n    containerPath: /usr/lib64/libnvidia-egl-gbm.so.1.1.4\n' "$d/lib/libnvidia-egl-gbm.so.1.1.4" > "\$out"
CTK
    chmod +x "$d/bin/nvidia-smi" "$d/bin/nvidia-ctk"
    : > "$d/ctk-calls"
    echo "$d"
}
# spec <dir> <stamp> <hostPath>...
spec() {
    local d="$1" stamp="$2"; shift 2
    { printf 'cdiVersion: 0.7.0\nkind: nvidia.com/gpu\ncontainerEdits:\n  mounts:\n'
      for p in "$@"; do printf '  - hostPath: %s\n    containerPath: /x\n' "$p"; done
    } > "$d/cdi/nvidia.yaml"
    printf '%s\n' "$stamp" > "$d/cdi/.nvidia-driver-version"
}
run() { PATH="$1/bin:$PATH" TILLANDSIAS_CDI_DIR="$1/cdi" bash "$SUBJECT" > "$1/out" 2>&1; }
calls() { wc -l < "$1/ctk-calls" | tr -d ' '; }

# ARM 1
d="$(scratch 610.57.04)"
spec "$d" 610.57.04 "$d/lib/libnvidia-ml.so.1" "$d/lib/libnvidia-egl-gbm.so.1.1.4"
run "$d"
grep -qx 'ok:nvidia-cdi:current:610.57.04' "$d/out" && [ "$(calls "$d")" = 0 ] \
    && ok "ARM 1: every hostPath exists -> current, nothing regenerated" \
    || bad "ARM 1: $(tr '\n' ' ' < "$d/out") ctk_calls=$(calls "$d")"
rm -rf "$d"

# ARM 2
d="$(scratch 610.57.04)"
spec "$d" 610.57.04 "$d/lib/libnvidia-ml.so.1" "$d/lib/libnvidia-egl-gbm.so.1.1.3"
[ ! -e "$d/lib/libnvidia-egl-gbm.so.1.1.3" ] || bad "ARM 2 PREMISE: the stale file exists"
run "$d"
if grep -q '^ok:nvidia-cdi:current:' "$d/out"; then
    bad "ARM 2: reported current about a spec mounting a missing file"
else
    ok "ARM 2: a missing hostPath is not reported current"
fi
grep -qx "note:nvidia-cdi:stale-hostpath:$d/lib/libnvidia-egl-gbm.so.1.1.3" "$d/out" \
    && ok "ARM 2: the missing path is named" || bad "ARM 2: stale path not named: $(tr '\n' ' ' < "$d/out")"
grep -qx 'ok:nvidia-cdi:generated:610.57.04' "$d/out" && [ "$(calls "$d")" = 1 ] \
    && ok "ARM 2: regenerated once" || bad "ARM 2: not regenerated (ctk_calls=$(calls "$d"))"
grep -q 'libnvidia-egl-gbm.so.1.1.4' "$d/cdi/nvidia.yaml" \
    && ok "ARM 2: the installed spec is the regenerated one" || bad "ARM 2: old spec still installed"
rm -rf "$d"

# ARM 3 (CONTROL)
d="$(scratch 611.00.01)"
spec "$d" 610.57.04 "$d/lib/libnvidia-ml.so.1"
run "$d"
grep -qx 'ok:nvidia-cdi:generated:611.00.01' "$d/out" && ! grep -q 'stale-hostpath' "$d/out" \
    && ok "ARM 3 CONTROL: a driver move still regenerates, without a stale note" \
    || bad "ARM 3 CONTROL: $(tr '\n' ' ' < "$d/out")"
rm -rf "$d"

# ARM 4
d="$(scratch 610.57.04)"
spec "$d" 610.57.04 "\"$d/lib/libnvidia-ml.so.1\"" "'$d/lib/gone.so'"
run "$d"
grep -qx "note:nvidia-cdi:stale-hostpath:$d/lib/gone.so" "$d/out" \
    && ok "ARM 4: quoted hostPath values are parsed (a quoted missing file is caught)" \
    || bad "ARM 4: $(tr '\n' ' ' < "$d/out")"
rm -rf "$d"

echo "nvidia-cdi-stale-hostpath fixture: ${passes} passed, ${fails} failed"
[ "$fails" -eq 0 ] && { echo "ok:nvidia-cdi-stale-hostpath:${passes}/${passes}"; exit 0; } || exit 1

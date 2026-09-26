#!/usr/bin/env bash
# test-spec-registry-status.sh — the spec/registry status guard refuses what it
# must and names what it cannot decide.
# @trace order:1397-eppt
#
# Hermetic: a fake openspec tree, pointed at through TILLANDSIAS_SPEC_ROOT.
# The arms macbookair ran by hand on darwin (2026-09-26) are here permanently:
# a flipped status word and a deleted ## Status section are both refused by
# name. Plus: agreement passes, an annotated status line is not a mismatch
# (secrets-management's "obsolete (removed in v0.3 …)"), and an UNDECIDED pair
# is printed and counted apart, never hidden.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
CHECK="$PWD/scripts/check-spec-registry-status.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/spec-reg.XXXXXX")"
trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

build() {  # a registry with alpha(active) beta(obsolete) gamma(active)
    rm -rf "$W/t"; mkdir -p "$W/t/openspec/specs/alpha" "$W/t/openspec/specs/beta" "$W/t/openspec/specs/gamma"
    printf -- '- spec_id: alpha\n  status: active\n- spec_id: beta\n  status: obsolete\n- spec_id: gamma\n  status: active\n' > "$W/t/openspec/litmus-bindings.yaml"
    printf '# alpha\n\n## Status\n\nactive\n\n## Purpose\nx\n' > "$W/t/openspec/specs/alpha/spec.md"
    printf '# beta\n\n## Status\n\nobsolete (removed in v0.3 — see x)\n' > "$W/t/openspec/specs/beta/spec.md"
    printf '# gamma\n\n## Status\n\nstatus: active\n' > "$W/t/openspec/specs/gamma/spec.md"
}
run() { TILLANDSIAS_SPEC_ROOT="$W/t" TILLANDSIAS_SPEC_UNDECIDED="${1:-}" bash "$CHECK"; }

build
o="$(run)"; rc=$?
[ "$rc" = 0 ] && [ "$o" = "ok:spec-registry-status:3 undecided=0" ] \
    && ok "agreement passes; an annotated line and a status: prefix are not mismatches" || bad "agreement: rc=$rc $o"

build; sed -i.bak 's/^active$/obsolete/' "$W/t/openspec/specs/alpha/spec.md"
o="$(run)"; rc=$?
case "$o" in *"mismatch:alpha:spec=obsolete:registry=active"*"refused:spec-registry-status:1 (of 3)"*) m=1 ;; *) m=0 ;; esac
[ "$rc" = 1 ] && [ "$m" = 1 ] && ok "a flipped status word is refused by name" || bad "flipped word: rc=$rc $o"

build; printf '# alpha\n\n## Purpose\nx\n' > "$W/t/openspec/specs/alpha/spec.md"
o="$(run)"; rc=$?
case "$o" in *"mismatch:alpha:spec=<none>:registry=active"*) m=1 ;; *) m=0 ;; esac
[ "$rc" = 1 ] && [ "$m" = 1 ] && ok "a deleted ## Status section is refused by name" || bad "missing section: rc=$rc $o"

build; sed -i.bak 's/^active$/draft/' "$W/t/openspec/specs/alpha/spec.md"
o="$(run alpha)"; rc=$?
case "$o" in *"undecided:alpha:spec=draft:registry=active"*"ok:spec-registry-status:3 undecided=1"*) m=1 ;; *) m=0 ;; esac
[ "$rc" = 0 ] && [ "$m" = 1 ] && ok "an UNDECIDED pair is printed and counted apart, not hidden" || bad "undecided: rc=$rc $o"

total=$((pass + fail))
if [ "$fail" = 0 ]; then echo "PASS: spec-registry-status guard $pass/$total (1397-eppt)"; exit 0; fi
echo "FAIL: spec-registry-status guard $pass/$total (1397-eppt)"; exit 1

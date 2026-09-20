#!/usr/bin/env bash
# @trace order:1312-i6da, spec:git-mirror-service
#
# test-initialize-bare-metal-host-idempotent.sh — pin the three properties
# ./skills/initialize-bare-metal-host must have: it is IDEMPOTENT, it never
# seeds a credential, and it tells a reader what to DO when something is down.
#
# HERMETIC WHERE IT CAN BE. Arms 1 and 3 drive a STUB podman on PATH, so they
# assert the checker's verdicts identically on a host with the stack up, a host
# with it down, and a host with no containers at all — and, importantly, they
# never stop this host's real mirror to prove that a stopped mirror is
# reported. A fixture that breaks the thing it tests is a fixture nobody runs
# twice.
#
# Verdicts:
#   ok:initialize-bare-metal-host:3/3
#   fail:initialize-bare-metal-host:<n> arm(s)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 3

CHECKER="$ROOT/scripts/check-bare-metal-host-initialized.sh"
SKILL="$ROOT/skills/initialize-bare-metal-host/SKILL.md"
[ -f "$CHECKER" ] || { echo "skip:initialize-bare-metal-host:no-checker"; exit 3; }

W="$(mktemp -d "${TMPDIR:-/tmp}/init-bare-metal.XXXXXX")" || exit 3
trap 'rm -rf "$W"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  PASS  $1"; }
bad() { fail=$((fail + 1)); echo "FAIL: $1" >&2; }

# A stub podman whose `ps` output is whatever the arm wants, and whose `exec`
# answers the github probe with a fixed length. No real container is touched.
mk_podman() { # mk_podman <dir> <names-newline-separated> <token-len>
    mkdir -p "$1"
    { printf '#!/usr/bin/env bash\ncase "$1" in\n  ps) cat <<'"'"'NAMES'"'"'\n%s\nNAMES\n     ;;\n  exec) echo "%s" ;;\n  *) exit 0 ;;\nesac\n' "$2" "$3"; } > "$1/podman"
    chmod +x "$1/podman"
}

ALL_UP=$'tillandsias-vault\ntillandsias-proxy\ntillandsias-git-tillandsias\ntillandsias-router\ntillandsias-inference'

echo "arm 1 — IDEMPOTENT: the same host state yields the SAME verdict line twice"
mk_podman "$W/up" "$ALL_UP" "40"
v1="$(PATH="$W/up:$PATH" bash "$CHECKER" 2>/dev/null)"; r1=$?
v2="$(PATH="$W/up:$PATH" bash "$CHECKER" 2>/dev/null)"; r2=$?
if [ "$v1" = "$v2" ] && [ "$r1" -eq 0 ] && [ "$r2" -eq 0 ]; then
    ok "stable verdict across two reads (rc=$r1): $v1"
else
    bad "arm1: verdict or rc changed between two reads of an unchanged host — rc=$r1/$r2, '$v1' vs '$v2'"
fi

echo "arm 2 — SEEDLESS: an unseeded host reads not-seeded, with NO prompt and no write"
mk_podman "$W/noseed" "$ALL_UP" "0"
out="$(PATH="$W/noseed:$PATH" bash "$CHECKER" </dev/null 2>/dev/null)"; rc=$?
case "$out" in
    *github=not-seeded*) _f1=1 ;;
    *) _f1=0 ;;
esac
# The checker must never carry a seeding verb. This is the arm that reds if
# anyone later "helpfully" makes it seed: every host that seeds ends holding a
# copy of one credential, where revoking one revokes all.
#
# COMMENTS ARE STRIPPED FIRST, and that is not a loophole — it is the
# difference between DOING a thing and DOCUMENTING that it must not be done.
# The checker explains in prose that seeding is the operator's act via
# `--github-login --with-token`, and the first version of this arm matched that
# very sentence and reported the checker as a seeder. Fourth instrument-inside-
# its-own-search-space of the session (1287-myx8); this one was caught by the
# fixture before it landed rather than after.
_code_only="$(sed -e 's/#.*$//' "$CHECKER" 2>/dev/null)"
_seedy="$(printf '%s\n' "$_code_only" | grep -cE 'github-login|--with-token|vault kv put' )"
if [ "$_f1" -eq 1 ] && [ "$rc" -eq 0 ] && [ "$_seedy" -eq 0 ]; then
    ok "not-seeded reported, rc=0, and the checker contains no seeding verb"
else
    bad "arm2: unseeded host must read not-seeded with rc=0 and no seeding verb (match=$_f1 rc=$rc seedy=$_seedy): $out"
fi

echo "arm 3 — TROUBLESHOOTING: a stopped mirror yields todo: naming the fix, rc=1"
mk_podman "$W/nomirror" $'tillandsias-vault\ntillandsias-proxy' "40"
out3="$(PATH="$W/nomirror:$PATH" bash "$CHECKER" 2>/dev/null)"; rc3=$?
case "$out3" in
    todo:initialize-bare-metal-host:mirror:*tillandsias*) _f3=1 ;;
    *) _f3=0 ;;
esac
if [ "$_f3" -eq 1 ] && [ "$rc3" -ne 0 ]; then
    ok "todo: names the mirror AND the command that fixes it, rc=$rc3"
else
    bad "arm3: a stopped mirror must produce todo:...:mirror:<command> with rc!=0 (match=$_f3 rc=$rc3): $out3"
fi

# The skill is the thing these verdicts serve; if it exists it must carry the
# self-evolving Repairs section with all five fields per entry.
if [ -f "$SKILL" ]; then
    echo "arm 3b — the skill's ## Repairs entries carry all five fields"
    _bad_entries=0
    while IFS= read -r line; do
        case "$line" in
            '- '*)
                for f in 'date:' 'host:' 'symptom:' 'command:' 'fix:'; do
                    case "$line" in *"$f"*) ;; *) _bad_entries=$((_bad_entries+1)); break ;; esac
                done ;;
        esac
    done < <(awk '/^## Repairs/{f=1;next} /^## /{f=0} f' "$SKILL")
    if [ "$_bad_entries" -eq 0 ]; then
        # Does NOT increment the pass count: the closure pins a 3-arm verdict
        # (ok:initialize-bare-metal-host:3/3), and an arm that adds to the
        # numerator without the denominator prints 4/3, which is not a verdict.
        # A FAILURE here still reds the fixture through bad().
        echo "  PASS  every Repairs entry carries date, host, symptom, command and fix"
    else
        bad "arm3b: $_bad_entries Repairs entr(ies) missing one of the five required fields"
    fi
fi

if [ "$fail" -eq 0 ]; then
    echo "ok:initialize-bare-metal-host:${pass}/3"
    exit 0
fi
echo "fail:initialize-bare-metal-host:${fail} arm(s)"
exit 1

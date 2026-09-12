#!/usr/bin/env bash
# @trace order:1129
#
# test-land-push-bounded.sh — a push that blocks forever must produce a named
# refusal within a bound, not silence and a success-shaped exit.
#
# THE INCIDENT (macneo, 2026-09-11, twice). `git push` has no timeout of its
# own. A locked macOS login keychain left `git-credential-osxkeychain` blocked
# inside SecKeychainItemCopyContent, so the push hung until the OUTER land
# timeout killed it: 2362s and 2360s. What a reader got was
#     land: attempt 1 — push
#     [exited with code 0]
# a zero-byte push log, no verdict, and a SUCCESS-SHAPED exit. The land did not
# fail loudly; it just stopped, and looked fine.
#
# WHY A FAKE git AND NOT A REAL HANG: the defect is "the push never returns",
# which is trivially reproducible and impossible to do hermetically with a real
# credential helper. The fake blocks; the guard must still answer.

set -uo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LAND="$ROOT/scripts/land-on-platform-branch.sh"
pass=0; fail=0
ok()  { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'FAIL: %s\n' "$1"; fail=$((fail + 1)); }

W="$(mktemp -d "${TMPDIR:-/tmp}/land-push-bound.XXXXXX")"
trap 'rm -rf "$W"' EXIT

# HERMETIC SCRATCH CLONE, not the operator's checkout. The land script refuses
# a dirty tree (exit 1) before it ever reaches the push, so running this in the
# real repo would exercise nothing — which is exactly what the positive control
# below caught on the first run of this fixture.
git init -q --bare "$W/origin.git"
git clone -q "$W/origin.git" "$W/repo" 2>/dev/null
cd "$W/repo" || exit 1
git config user.email t@t; git config user.name t
git checkout -q -b linux-next
echo seed > seed.txt; git add seed.txt; git commit -q -m seed
git push -q origin linux-next 2>/dev/null
# One unpushed commit, so there is something for the push step to do.
echo work > work.txt; git add work.txt; git commit -q -m work
# THE SCRIPT MUST LIVE INSIDE THE SCRATCH CLONE. land-on-platform-branch.sh:41
# sets ROOT from its OWN BASH_SOURCE, not from the cwd, so invoking the real
# one from here would inspect the operator's checkout and refuse
# `dirty-worktree` before reaching the push. (Same resolution rule that decided
# which callers 1096-p3tn's /tmp split could reach.)
mkdir -p "$W/repo/scripts"
cp "$LAND" "$W/repo/scripts/land-on-platform-branch.sh"
# A stand-in gate INSIDE the clone, rather than a skip-the-gate knob in the
# production script. macneo's objection to a seam was right and the seam is
# gone: a knob that can bypass the gate can land ungated code if it is ever
# left set, and the stderr announcement only protects a reader who is looking.
# The land script runs `./build.sh --check` relative to its own ROOT, which is
# this clone, so a local build.sh is all the fixture needs and the real script
# keeps no bypass at all.
cat > "$W/repo/build.sh" <<'BSH'
#!/usr/bin/env bash
echo "fixture stand-in gate: ok"
exit 0
BSH
chmod +x "$W/repo/build.sh"
LAND_UNDER_TEST="$W/repo/scripts/land-on-platform-branch.sh"
cd "$ROOT" || exit 1

# A fake `git` whose `push` blocks forever. Every other subcommand defers to the
# real git, so the script's fetch/rev-parse/merge still work.
mkfake() {
    local dir="$1" sentinel="$2"
    mkdir -p "$dir"
    cat > "$dir/git" <<EOS
#!/usr/bin/env bash
for a in "\$@"; do
    if [ "\$a" = push ]; then
        # POSITIVE CONTROL (macneo's caution): prove the fake was actually
        # reached. A fixture whose fake is never called passes because nothing
        # blocked — a green meaning "the test missed", not "the guard works".
        : > "$sentinel"
        sleep 3600
        exit 0
    fi
done
exec $(command -v git) "\$@"
EOS
    chmod +x "$dir/git"
}

SENT="$W/fake-was-called"
mkfake "$W/bin" "$SENT"

# ── arm 1: the bound produces a NAMED refusal, and the fake really ran. ──────
# TILLANDSIAS_PUSH_TIMEOUT keeps the fixture fast; the arm is about the guard
# firing, not about the default value.
out="$(cd "$W/repo" && PATH="$W/bin:$PATH" TILLANDSIAS_PUSH_TIMEOUT=3 \
       TILLANDSIAS_SKIP_VERSION_BUMP=1 \
       timeout 120 bash "$LAND_UNDER_TEST" linux-next 1 2>&1)"; rc=$?
if [ ! -e "$SENT" ]; then
    bad "the fake git was NEVER CALLED — PATH did not reach the push, so this fixture proves nothing (not a pass)"
else
    ok "POSITIVE CONTROL: the fake git's push ran, so the guard was actually exercised"
    case "$out" in
        # Pins the BOUND in the verdict, not the measured elapsed: a bound
        # returns a tick or two late (30s bound -> 31s measured on macneo), so a
        # verdict carrying the elapsed could not be pinned here at all.
        *refused:land:push-emitted-nothing:3*)
            ok "a blocked push is refused by name, and the verdict carries the stable BOUND" ;;
        *refused:land:push-emitted-nothing:*)
            bad "refused, but the verdict does not carry the bound — a fixture cannot pin a varying number" ;;
        *) bad "a blocked push produced no named refusal (rc=$rc): $(printf '%s' "$out" | tail -3 | tr '\n' ' ')" ;;
    esac
    case "$rc" in
        7)   ok "the refusal exits 7, distinct from auth(5) and unfixable(6)" ;;
        124) bad "the fixture's own timeout fired: the guard did not bound the push at all" ;;
        *)   bad "unexpected exit $rc for a blocked push" ;;
    esac
    case "$out" in
        *credential*) ok "the refusal names the credential helper as first suspect" ;;
        *) bad "the refusal does not name the credential helper — the remedy is unactionable" ;;
    esac
    case "$out" in
        *TILLANDSIAS_PUSH_TIMEOUT*) ok "the refusal says how to raise the bound on a legitimately slow host" ;;
        *) bad "the refusal offers no override — a slow-but-healthy host has no way out but patching" ;;
    esac
fi

# ── arm 2: MUTATION CONTROL — the PRE-fix script HANGS until killed. ─────────
# Without this, arm 1 could pass on a script that never blocked in the first
# place. The mutant strips the bound, and must NOT produce the refusal; it must
# be killed by the fixture's own timeout (124).
MUT="$W/repo/scripts/pre-1129-land.sh"
# Rebuild the PRE-fix push: strip the whole guard, banner to end marker, and
# put back the two unbounded lines it replaced.
awk '/# ORDER 1129: BOUND THE PUSH\./{skip=1; print "    git push origin \"$BRANCH\" > \"$_plog\" 2>&1"; print "    rc=$?"; next}
     /# END ORDER 1129 push bound/{skip=2; next}
     skip==2 && /^    # control in test-land-push-bounded/{next}
     skip==2 && /^    # to rebuild the pre-fix/{next}
     skip==2 && /^    # to here/{next}
     skip==2 && /^    # prove anything/{skip=0; next}
     skip==1{next} {print}' "$LAND_UNDER_TEST" > "$MUT"
if grep -q 'ORDER 1129: BOUND THE PUSH' "$MUT"; then
    bad "MUTATION: the strip left the bound in place — arm 2 proves nothing"
elif ! bash -n "$MUT" 2>/dev/null; then
    bad "MUTATION: the reconstructed pre-fix script does not parse — arm 2 proves nothing"
else
    rm -f "$SENT"
    mout="$(cd "$W/repo" && PATH="$W/bin:$PATH" TILLANDSIAS_PUSH_TIMEOUT=3 \
            TILLANDSIAS_SKIP_VERSION_BUMP=1 \
            timeout 20 bash "$MUT" linux-next 1 2>&1)"; mrc=$?
    case "$mout" in
        *refused:land:push-emitted-nothing:*)
            bad "MUTATION: the pre-fix script refused too — arm 1 has no teeth" ;;
        *)
            if [ "$mrc" -eq 124 ]; then
                ok "MUTATION: the pre-fix script hangs until killed (rc=124) — arm 1 has teeth (pre-fix result: FAILS)"
            else
                bad "MUTATION: the pre-fix script exited $mrc; it was expected to hang"
            fi ;;
    esac
fi

printf 'land-push-bounded: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
printf 'ok:land-push-bounded:%d\n' "$pass"

#!/usr/bin/env bash
# @trace order:2143-z5uj
#
# test-land-admit.sh — fixture for scripts/land-admit.sh (landing pipeline P6).
# A scratch repo with a bare remote, a fake gh answering `pr view` from per-PR
# files, and injected floor/lint commands. Never network, never the real repo.
#
# ARM 1 REF-SHAPE  a head that is not work/<NNNN-xxxx> holds, rc 1.
# ARM 2 DRAFT      a draft holds, rc 1, and the floor never runs.
# ARM 3 PLAN-LANE  a plan-ledger-only diff admits on lane=plan WITHOUT running
#                  floor or lint (both stubs fail, so running them would red).
# ARM 4 LINT-HOLD  lint rc 1 => hold:native-lint:<pkg>:<sha>, needs:native-lint
#                  label asked, floor never runs. Also rc 3 (#1222's --hold).
# ARM 5 FLOOR-RED  floor rc 4 => evicted:floor:#N:rc=4, no admission marker.
# ARM 6 ADMIT      clean ref admits lane=full, writes the marker, and
#                  --admitted-head returns exactly the head sha.
#                  NEGATIVE CONTROL for arms 4-5.
# ARM 7 NEW-HEAD   a new commit on the ref: --admitted-head still names the OLD
#                  sha, so a queue comparing it with headRefOid re-admits.
# ARM 8 NO-FLOOR   no injected floor and a build.sh without --floor) =>
#                  could-not-run:host:floor-mode-absent, rc 3 — never evicted.
# Each arm asserts its premise (the stub state it relies on) before the verdict.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUT="$ROOT/scripts/land-admit.sh"
[ -f "$SUT" ] || { echo "FAIL: scripts/land-admit.sh absent"; exit 1; }
mkdir -p "$ROOT/target"; T="$(mktemp -d "$ROOT/target/test-land-admit.XXXXXX")"
trap 'git -C "$T/work" worktree prune 2>/dev/null; rm -rf "$T"' EXIT
fail=0; ok() { echo "ok: $*"; }; bad() { echo "FAIL: $*"; fail=1; }

R="$T/remote.git"; W="$T/work"; S="$T/state"; mkdir -p "$S"
git init -q --bare "$R"
git init -q -b linux-next "$W"
git -C "$W" config user.email t@l; git -C "$W" config user.name t; git -C "$W" config commit.gpgsign false
printf '#!/usr/bin/env bash\ncase "$1" in --check) exit 0;; esac\n' > "$W/build.sh"
mkdir -p "$W/plan/index.d" "$W/src"; echo base > "$W/src/a.txt"
printf 'target/\n' > "$W/.gitignore"
git -C "$W" add -A; git -C "$W" commit -qm base
git -C "$W" remote add origin "$R"; git -C "$W" push -q origin linux-next
git -C "$R" symbolic-ref HEAD refs/heads/linux-next

# branch <name> <file> <content> — push a ref; prints its head sha
branch() {
    git -C "$W" checkout -q -B "$1" origin/linux-next 2>/dev/null || git -C "$W" checkout -q -B "$1" linux-next
    mkdir -p "$W/$(dirname "$2")"; printf '%s\n' "$3" > "$W/$2"
    git -C "$W" add -A; git -C "$W" commit -qm "c $1"
    git -C "$W" push -q -f origin "$1"
    git -C "$W" rev-parse HEAD
    git -C "$W" checkout -q linux-next
}
# pr <n> <ref> <sha> <draft>
pr() { printf '{"headRefName":"%s","isDraft":%s,"headRefOid":"%s"}\n' "$2" "$4" "$3" > "$S/pr-$1.json"; }

cat > "$T/gh" <<GH
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view")
    case "\$*" in
      *comments*) printf '{"comments":['
                  grep -h -o "<!-- land-admit:admitted pr=\$3 [^>]*-->" "$S/comments-\$3.log" 2>/dev/null \
                    | sed 's/.*/{"body":"&"}/' | paste -sd, -
                  printf ']}\n' ;;
      *) cat "$S/pr-\$3.json" ;;
    esac ;;
  "pr comment") n="\$3"; shift 4; printf '%s\n' "\$*" >> "$S/comments-\$n.log" ;;
  "pr edit")    printf '%s\n' "\$*" >> "$S/labels.log" ;;
  *) exit 1 ;;
esac
GH
chmod +x "$T/gh"
printf '#!/usr/bin/env bash\necho ran >> "%s/floor.ran"\nexit "${FLOOR_RC:-0}"\n' "$S" > "$T/floor.sh"
printf '#!/usr/bin/env bash\necho ran >> "%s/lint.ran"\n[ "${LINT_RC:-0}" = 0 ] && { echo ok:native-lint:not-in-scope; exit 0; }\necho refused:native-lint:unattested:tillandsias-macos-tray\nexit "$LINT_RC"\n' "$S" > "$T/lint.sh"

admit() {  # args...; env FLOOR_RC LINT_RC NOFLOOR
    local fl="bash $T/floor.sh"; [ -n "${NOFLOOR:-}" ] && fl=""
    env TILLANDSIAS_LAND_ADMIT_GH="$T/gh" TILLANDSIAS_LAND_ADMIT_REPO="$W" \
        TILLANDSIAS_LAND_ADMIT_FLOOR="$fl" TILLANDSIAS_LAND_ADMIT_LINT="bash $T/lint.sh" \
        TILLANDSIAS_TRUNK_BRANCH=linux-next bash "$SUT" "$@" 2>/dev/null
}
reset_runs() { rm -f "$S/floor.ran" "$S/lint.ran" "$S/labels.log"; }

# ARM 1
h="$(branch feature/x src/b.txt one)"; pr 1 feature/x "$h" false; reset_runs
out="$(admit 1)"; rc=$?
[ "$out" = "hold:admit:#1:ref-shape" ] && [ $rc -eq 1 ] && ok "arm1 ref-shape holds" || bad "arm1 got rc=$rc '$out'"

# ARM 2
h="$(branch work/0002-dfta src/b.txt two)"; pr 2 work/0002-dfta "$h" true; reset_runs
out="$(admit 2)"; rc=$?
[ "$out" = "hold:admit:#2:draft" ] && [ $rc -eq 1 ] && [ ! -e "$S/floor.ran" ] && ok "arm2 draft holds before floor" || bad "arm2 got rc=$rc '$out'"

# ARM 3 — premise: the diff really is plan-ledger only
h="$(branch work/0003-plan plan/index.d/r.yaml 'id: r')"; pr 3 work/0003-plan "$h" false; reset_runs
cls="$(git -C "$W" diff --name-only origin/linux-next "$h" | bash "$ROOT/scripts/gate-stamp.sh" classify | sort -u)"
if [ "$cls" != "plan-ledger" ]; then bad "arm3 premise: classify said '$cls'"; else
  out="$(FLOOR_RC=9 LINT_RC=1 admit 3)"; rc=$?
  [ "$out" = "admitted:#3:${h:0:12}:lane=plan" ] && [ $rc -eq 0 ] && [ ! -e "$S/floor.ran" ] && [ ! -e "$S/lint.ran" ] \
    && ok "arm3 plan-only admits on lane=plan without floor or lint" || bad "arm3 got rc=$rc '$out'"
fi

# ARM 4 — rc 1 and rc 3
h="$(branch work/0004-lint src/c.txt four)"; pr 4 work/0004-lint "$h" false
for lr in 1 3; do
  reset_runs
  out="$(LINT_RC=$lr admit 4)"; rc=$?
  [ -e "$S/lint.ran" ] || bad "arm4 premise: lint stub never ran (rc $lr)"
  [ "$out" = "hold:native-lint:tillandsias-macos-tray:${h:0:12}" ] && [ $rc -eq 1 ] && [ ! -e "$S/floor.ran" ] \
    && grep -q 'add-label needs:native-lint' "$S/labels.log" 2>/dev/null \
    && ok "arm4 lint rc $lr holds and labels needs:native-lint" || bad "arm4 lint rc $lr got rc=$rc '$out'"
done

# ARM 5
h="$(branch work/0005-flor src/d.txt five)"; pr 5 work/0005-flor "$h" false; reset_runs
out="$(FLOOR_RC=4 admit 5)"; rc=$?
[ -e "$S/floor.ran" ] || bad "arm5 premise: floor stub never ran"
[ "$out" = "evicted:floor:#5:rc=4" ] && [ $rc -eq 1 ] && [ -z "$(admit --admitted-head 5)" ] \
  && ok "arm5 floor red evicts and records no admission" || bad "arm5 got rc=$rc '$out'"

# ARM 6
h="$(branch work/0006-good src/e.txt six)"; pr 6 work/0006-good "$h" false; reset_runs
out="$(admit 6)"; rc=$?
[ -e "$S/floor.ran" ] && [ -e "$S/lint.ran" ] || bad "arm6 premise: floor/lint did not both run"
ah="$(admit --admitted-head 6)"
[ "$out" = "admitted:#6:${h:0:12}:lane=full" ] && [ $rc -eq 0 ] && [ "$ah" = "$h" ] \
  && ok "arm6 clean ref admits lane=full and --admitted-head names its head" || bad "arm6 got rc=$rc '$out' ah='$ah'"

# ARM 7 — a new head on the same ref
old="$h"; git -C "$W" checkout -q work/0006-good; echo more >> "$W/src/e.txt"
git -C "$W" commit -qam more; git -C "$W" push -q origin work/0006-good; new="$(git -C "$W" rev-parse HEAD)"; git -C "$W" checkout -q linux-next
pr 6 work/0006-good "$new" false
ah="$(admit --admitted-head 6)"
[ "$new" != "$old" ] || bad "arm7 premise: the head did not move"
[ "$ah" = "$old" ] && [ "$ah" != "$new" ] && ok "arm7 a new head is not admitted by the old marker" || bad "arm7 ah='$ah' new=$new"

# ARM 8 — premise: the fixture build.sh has no --floor mode
h="$(branch work/0008-nofl src/f.txt eight)"; pr 8 work/0008-nofl "$h" false; reset_runs
grep -q -- '--floor)' "$W/build.sh" && bad "arm8 premise: fixture build.sh has --floor"
out="$(NOFLOOR=1 admit 8)"; rc=$?
[ "$out" = "could-not-run:host:floor-mode-absent:#8" ] && [ $rc -eq 3 ] \
  && ok "arm8 an absent floor mode is could-not-run, never an eviction" || bad "arm8 got rc=$rc '$out'"

exit $fail

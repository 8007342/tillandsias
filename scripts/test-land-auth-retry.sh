#!/usr/bin/env bash
# @trace order:1164-cftu
# test-land-auth-retry.sh — pins the land tool's ONE retry on the auth
# signature: a push that fails with "Authentication failed" once and succeeds
# on the retry lands; two failures refuse exactly as before (exit 5, the
# 1025-a896 text); and no gh auth command is ever run. Hermetic: a scratch
# bare origin, a scratch checkout carrying a copy of the land tool, a green
# stub gate, a `git` wrapper on PATH that fails the first N pushes with the
# auth signature and delegates everything else to the real git, and a `gh`
# stub that records every call. bash 3.2 clean (761-g36m).
# TILLANDSIAS_LAND_UNDER_TEST overrides the tool under test (mutation control).
set -u
REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANDSH="${TILLANDSIAS_LAND_UNDER_TEST:-$REAL_ROOT/scripts/land-on-platform-branch.sh}"
REAL_GIT="$(command -v git)"
fails=0; passes=0
ok()  { passes=$((passes + 1)); echo "ok: $1"; }
bad() { fails=$((fails + 1)); echo "FAIL: $1"; }

scratch() { # <n-auth-failures>
    local d bare
    d="$(mktemp -d "${TMPDIR:-/tmp}/land-auth-retry.XXXXXX")"
    bare="$d/origin.git"
    git init -q --bare "$bare"
    git init -q -b linux-next "$d/w"
    git -C "$d/w" remote add origin "$bare"
    mkdir -p "$d/w/scripts" "$d/bin"
    cp "$LANDSH" "$d/w/scripts/land-on-platform-branch.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$d/w/build.sh"; chmod +x "$d/w/build.sh"
    git -C "$d/w" -c user.email=t@t -c user.name=t add -A
    git -C "$d/w" -c user.email=t@t -c user.name=t commit -q -m base
    git -C "$d/w" push -q origin linux-next
    git -C "$d/w" -c user.email=t@t -c user.name=t commit -q --allow-empty -m unpushed
    echo "$1" > "$d/auth-failures-left"
    # git wrapper: fail the first N pushes with the auth signature, then delegate.
    cat > "$d/bin/git" <<WRAP
#!/usr/bin/env bash
if [ "\${1:-}" = "push" ]; then
    left=\$(cat "$d/auth-failures-left")
    if [ "\$left" -gt 0 ]; then
        echo \$((left - 1)) > "$d/auth-failures-left"
        echo "fatal: Authentication failed for 'https://github.com/example/repo.git/'" >&2
        exit 128
    fi
fi
exec "$REAL_GIT" "\$@"
WRAP
    chmod +x "$d/bin/git"
    printf '#!/usr/bin/env bash\necho "gh \$*" >> "%s/gh-calls"; exit 1\n' "$d" > "$d/bin/gh"; chmod +x "$d/bin/gh"
    : > "$d/gh-calls"
    echo "$d"
}

run_land() { # <scratch-dir>
    ( cd "$1/w" && PATH="$1/bin:$PATH" GIT_TERMINAL_PROMPT=0 TILLANDSIAS_LAND_AUTH_RETRY_DELAY=0 \
        bash scripts/land-on-platform-branch.sh linux-next 1 > "$1/out.txt" 2> "$1/err.txt" < /dev/null; echo $? > "$1/rc" )
}

# ARM 1: one auth failure, then success -> lands, and the retry is visible.
d="$(scratch 1)"; run_land "$d"
rc="$(cat "$d/rc")"
grep -q '^ok:land:' "$d/out.txt" && ok "one auth failure then success lands (rc=$rc)" || bad "did not land after one auth failure: rc=$rc $(tail -2 "$d/err.txt" | tr '\n' ' ')"
grep -q 'auth-failed once, retrying after 0s (1164-cftu)' "$d/out.txt" && ok "the retry is named in the land output" || bad "no retry line"
[ ! -s "$d/gh-calls" ] && ok "no gh command was run on the retry path" || bad "gh was invoked: $(cat "$d/gh-calls")"
rm -rf "$d"

# ARM 2 (NEGATIVE CONTROL): two auth failures -> refuses exactly as before.
d="$(scratch 2)"; run_land "$d"
rc="$(cat "$d/rc")"
[ "$rc" -eq 5 ] && ok "two auth failures refuse with exit 5" || bad "rc=$rc, wanted 5"
grep -q 'refused:land:auth-failed' "$d/err.txt" && ok "the refusal verdict is unchanged" || bad "no refused:land:auth-failed"
grep -q "do NOT run 'gh auth login' or 'gh auth refresh'" "$d/err.txt" && ok "the 1025-a896 text is unchanged" || bad "1025-a896 text missing"
grep -c 'auth-failed once, retrying' "$d/out.txt" | grep -qx 1 && ok "exactly one retry before refusing" || bad "retry count wrong"
[ ! -s "$d/gh-calls" ] && ok "NEGATIVE CONTROL: no gh command even when refusing" || bad "gh was invoked while refusing"
rm -rf "$d"

echo "land-auth-retry fixture: ${passes} passed, ${fails} failed"
[ "$fails" -eq 0 ] && { echo "ok:land-auth-retry-fixture:all"; exit 0; } || exit 1

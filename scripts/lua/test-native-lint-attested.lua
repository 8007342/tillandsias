-- @trace order:1235-rfub, order:1563-ms7e, order:2208-vxb6, spec:ci-release
-- @env PATH
--
-- test-native-lint-attested.lua — PORTED from test-native-lint-attested.sh
-- (2208-vxb6), same ten arms, same lines. Fixture for
-- scripts/check-native-lint-attested.sh and scripts/attest-native-lint.sh
-- (order 1235-rfub), over scratch repos whose origin/linux-next is the base.
-- The change under test is the incident's own: a `format!("{e}")` (clippy
-- useless_format) added to a macOS-tray source.
--
--   1. the change with NO attestation is REFUSED, naming the accountable host;
--   2. attest with a clippy that FAILS: no commit is written, still refused;
--   3. attest with a clippy that PASSES: it ran `clippy -p <pkg> --all-targets
--      -- -D warnings`, and the relay check admits it while saying it was
--      attested, NOT re-run here;
--   4. edit the crate AFTER attesting: REFUSED as stale (bound to content);
--   5. a hand-written trailer for the wrong platform does not count;
--   6. NEGATIVE CONTROL: a change outside the gated crates is not in scope;
--   7. land-on-platform-branch.sh runs the check after its integrate (wired);
--   8. NO HOST AVAILABLE: a named TILLANDSIAS_NATIVE_LINT_UNATTESTED reason
--      admits as override:… carrying the reason; an EMPTY one does not.
--   9. hostname -s FAILS (Git Bash, the WSL builder): uname -n names the host;
--  10. NO host name at all: REFUSED (rc 2), no trailer written.
--
-- HEAD: every subject runs in a scratch repo under target/plan-scratch whose
-- origin/linux-next is its own base, never the real checkout's HEAD
-- (2196-rdec: clean by construction). TILLANDSIAS_GATE_DIFF_BASE (the gated
-- checkout's frozen base, 1592-idmu) passes through the runner, so every
-- subject is started under `env -u TILLANDSIAS_GATE_DIFF_BASE`, as the .sh
-- unset it.
--
-- Verdict: ok:native-lint-attested-fixture:<p>/10 | fail:native-lint-attested-fixture:<p>/10

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local PATH = env.get("PATH") or "/usr/bin:/bin"
local pass, total = 0, 10
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m) end

for _, s in ipairs({ "check-native-lint-attested.sh", "attest-native-lint.sh" }) do
    if not fs.exists("scripts/" .. s) then
        verdict.emit("fail:native-lint-attested-fixture:0/" .. total .. " (" .. s .. " missing)", 1)
    end
end
if not proc.run{ argv = { "git", "--version" } }.ok then verdict.skip("native-lint-attested-fixture:no-git") end

local relW = "target/plan-scratch/native-lint-" .. tostring(time.now_ms())
local W = root .. "/" .. relW
proc.run{ argv = { "mkdir", "-p", W .. "/bin" } }
local function cleanup() proc.run{ argv = { "find", W, "-delete" }, timeout_ms = 60000 } end

-- A stub cargo: records its argv, exits $STUB_RC.
fs.write(relW .. "/bin/cargo", '#!/bin/bash\nprintf "%s\\n" "$*" >> "' .. W .. '/cargo.argv"\nexit "${STUB_RC:-0}"\n')
proc.run{ argv = { "chmod", "+x", W .. "/bin/cargo" } }

local GC = { "-c", "user.email=f@x", "-c", "user.name=f" }
local function git(r, args)
    local a = { "git", "-C", r }
    for _, x in ipairs(GC) do a[#a + 1] = x end
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, timeout_ms = 60000 }
end
local function commits(r) return text.trim(git(r, { "rev-list", "--count", "HEAD" }).stdout or "") end

local function repo(name)
    local r, rr = W .. "/" .. name, relW .. "/" .. name
    proc.run{ argv = { "mkdir", "-p", r .. "/scripts", r .. "/crates/tillandsias-macos-tray/src", r .. "/crates/linux-only/src" } }
    proc.run{ argv = { "cp", "scripts/check-native-lint-attested.sh", "scripts/attest-native-lint.sh", r .. "/scripts/" } }
    fs.write(rr .. "/crates/tillandsias-macos-tray/src/action_host.rs", "pub fn f() -> Result<(), String> { Ok(()) }\n")
    fs.write(rr .. "/crates/linux-only/src/lib.rs", "pub fn g() {}\n")
    proc.run{ argv = { "git", "-C", r, "init", "-q" } }
    git(r, { "add", "-A" }); git(r, { "commit", "-qm", "base" })
    git(r, { "update-ref", "refs/remotes/origin/linux-next", "HEAD" })
    return r, rr
end
local function incident(r, rr) -- the 690-w94k line, committed
    fs.write(rr .. "/crates/tillandsias-macos-tray/src/action_host.rs",
        'pub fn f() -> Result<(), String> { std::fs::read("x").map_err(|e| format!("{e}"))?; Ok(()) }\n')
    git(r, { "commit", "-qam", "tray: map_err" })
end

-- Every subject: the darwin platform (the fixture runs on every gate host) and
-- no gate diff base.
local function subject(r, script, e)
    local a = { "env", "-u", "TILLANDSIAS_GATE_DIFF_BASE", "bash", "scripts/" .. script }
    local en = { TILLANDSIAS_NATIVE_LINT_PLATFORM = "darwin" }
    for k, v in pairs(e or {}) do en[k] = v end
    local p = proc.run{ argv = a, cwd = r, env = en, timeout_ms = 120000 }
    return text.trim(((p.stdout or "") .. (p.stderr or ""))), p.code
end
local function check(r, e) return subject(r, "check-native-lint-attested.sh", e) end
-- The attest script commits with the AMBIENT git identity; hand the scratch
-- repo the same identity GC gives every other commit here.
local function attest(r, rc, pathprefix)
    return subject(r, "attest-native-lint.sh", { PATH = W .. "/bin:" .. (pathprefix or "") .. PATH, STUB_RC = tostring(rc),
        GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@x", GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@x" })
end
local function has_line(s, l) for _, x in ipairs(text.lines(s)) do if x == l then return true end end return false end
local function has_prefix(s, p) for _, x in ipairs(text.lines(s)) do if x:sub(1, #p) == p then return true end end return false end
local function has(s, p) return s:find(p, 1, true) ~= nil end

-- 1 — unattested.
local R, RR = repo("a"); incident(R, RR)
local OUT, RC = check(R)
if RC == 1 and has_line(OUT, "refused:native-lint:unattested:tillandsias-macos-tray")
    and has(OUT, "accountable: the AUTHORING darwin host") then
    ok("arm 1: the incident's change with no attestation is refused, naming the accountable host")
else bad("arm 1: rc=" .. RC .. " [" .. OUT .. "]") end

-- 2 — a failing clippy writes nothing.
local n0 = commits(R)
local AOUT, ARC = attest(R, 1); OUT, RC = check(R)
if ARC == 1 and has_line(AOUT, "failed:attest-native-lint:tillandsias-macos-tray:rc=1")
    and commits(R) == n0 and RC == 1 then
    ok("arm 2: a failing native clippy writes no attestation; the relay still refuses")
else bad("arm 2: arc=" .. ARC .. " commits " .. n0 .. "->" .. commits(R) .. " rc=" .. RC .. " [" .. AOUT .. "]") end

-- 3 — a passing clippy attests; the check admits and names the limitation.
proc.run{ argv = { "find", W, "-maxdepth", "1", "-name", "cargo.argv", "-delete" } }
AOUT, ARC = attest(R, 0); OUT, RC = check(R)
local argv = text.trim(fs.read(relW .. "/cargo.argv") or "")
if ARC == 0 and argv == "clippy -p tillandsias-macos-tray --all-targets -- -D warnings"
    and RC == 0 and has_prefix(OUT, "ok:native-lint:attested:tillandsias-macos-tray@")
    and has(OUT, "NOT re-run here") then
    ok("arm 3: clippy --all-targets -D warnings ran, attested; admitted as attested-not-re-run")
else bad("arm 3: arc=" .. ARC .. " argv=[" .. argv .. "] rc=" .. RC .. " [" .. OUT .. "]") end

-- 4 — edited after the attestation: stale.
local body = fs.read(RR .. "/crates/tillandsias-macos-tray/src/action_host.rs") or ""
fs.write(RR .. "/crates/tillandsias-macos-tray/src/action_host.rs", body .. "// later\n")
git(R, { "commit", "-qam", "tray: later edit" }); OUT, RC = check(R)
if RC == 1 and has_line(OUT, "refused:native-lint:stale:tillandsias-macos-tray") then
    ok("arm 4: an edit after attesting makes the attestation stale — refused")
else bad("arm 4: rc=" .. RC .. " [" .. OUT .. "]") end

-- 5 — a hand-written trailer naming the wrong platform does not count.
R, RR = repo("b"); incident(R, RR)
local tree = text.trim(git(R, { "rev-parse", "HEAD:crates/tillandsias-macos-tray" }).stdout or "")
git(R, { "commit", "-q", "--allow-empty", "-m", "x", "--trailer",
    "Native-Lint: h linux crates/tillandsias-macos-tray=" .. tree .. " clippy" })
OUT, RC = check(R)
if RC == 1 and has_prefix(OUT, "refused:native-lint:unattested:") then
    ok("arm 5: a linux attestation of a darwin crate does not count")
else bad("arm 5: rc=" .. RC .. " [" .. OUT .. "]") end

-- 6 — NEGATIVE CONTROL: outside the gated crates.
R, RR = repo("c")
fs.write(RR .. "/crates/linux-only/src/lib.rs", 'pub fn g() { let _ = format!("{}", 1); }\n')
git(R, { "commit", "-qam", "linux" }); OUT, RC = check(R)
if RC == 0 and has_line(OUT, "ok:native-lint:not-in-scope") then
    ok("arm 6: a change outside the gated crates needs no attestation")
else bad("arm 6: rc=" .. RC .. " [" .. OUT .. "]") end

-- 7 — wired into the relay, after the integrate and before the gate.
local L = "scripts/land-on-platform-branch.sh"
local Ls = fs.read(L) or ""
local ln_alloc, ln_nl, ln_gate
for i, l in ipairs(text.lines(Ls)) do
    if not ln_alloc and l:find("allocate-gate-step-prefix.sh --base", 1, true) then ln_alloc = i end
    if not ln_nl and l:find("bash scripts/check-native-lint-attested.sh --base", 1, true) then ln_nl = i end
    if not ln_gate and l:find("build.sh --check", 1, true) and not l:find("#", 1, true) then ln_gate = i end
end
if ln_nl and ln_alloc and ln_gate and ln_alloc < ln_nl and ln_nl < ln_gate and has(Ls, "refused:land:native-lint") then
    ok("arm 7: land-on-platform-branch.sh runs the check after the integrate, before the gate (line " .. ln_nl .. ")")
else
    bad("arm 7: alloc=" .. tostring(ln_alloc or "") .. " native-lint=" .. tostring(ln_nl or "") .. " gate=" .. tostring(ln_gate or ""))
end

-- 8 — the named override, and an empty one.
R, RR = repo("d"); incident(R, RR)
OUT, RC = check(R, { TILLANDSIAS_NATIVE_LINT_UNATTESTED = "no mac awake; tray refactor" })
local OUT2, RC2 = check(R, { TILLANDSIAS_NATIVE_LINT_UNATTESTED = "" })
if RC == 0 and has_line(OUT, "override:native-lint:unattested:tillandsias-macos-tray:no mac awake; tray refactor")
    and RC2 == 1 and has(OUT2, "the land WAITS") and has(Ls, "Native-Lint-Unattested:") then
    ok("arm 8: a named override lands as recorded debt; an empty one waits")
else bad("arm 8: rc=" .. RC .. " [" .. OUT .. "] / empty rc=" .. RC2) end

-- 9, 10 — the host name. Stubs fail the way Git Bash and the WSL builder do.
proc.run{ argv = { "mkdir", "-p", W .. "/nohost", W .. "/noname" } }
fs.write(relW .. "/nohost/hostname", '#!/bin/bash\necho "hostname: unknown option -- s" >&2\nexit 1\n')
fs.write(relW .. "/noname/uname", "#!/bin/bash\nexit 1\n")
proc.run{ argv = { "chmod", "+x", W .. "/nohost/hostname", W .. "/noname/uname" } }
R, RR = repo("e"); incident(R, RR)
AOUT, ARC = attest(R, 0, W .. "/nohost:"); OUT, RC = check(R)
local want = (text.trim(proc.run{ argv = { "uname", "-n" } }.stdout or ""):match("^[^.]*") or ""):lower()
if ARC == 0 and RC == 0 and want ~= "" and has_line(OUT, "ok:native-lint:attested:tillandsias-macos-tray@" .. want) then
    ok("arm 9: hostname -s fails, uname -n names the host, and the check admits it")
else bad("arm 9: arc=" .. ARC .. " rc=" .. RC .. " want=[" .. want .. "] [" .. AOUT .. "] [" .. OUT .. "]") end
R, RR = repo("f"); incident(R, RR); n0 = commits(R)
AOUT, ARC = attest(R, 0, W .. "/nohost:" .. W .. "/noname:")
if ARC == 2 and has_line(AOUT, "refused:attest-native-lint:no-host") and has(AOUT, "  remedy: ")
    and commits(R) == n0 then
    ok("arm 10: no host name at all is refused (rc 2) and writes no trailer")
else bad("arm 10: arc=" .. ARC .. " commits " .. n0 .. "->" .. commits(R) .. " [" .. AOUT .. "]") end

cleanup()
if pass == total then verdict.emit("ok:native-lint-attested-fixture:" .. pass .. "/" .. total, 0) end
verdict.emit("fail:native-lint-attested-fixture:" .. pass .. "/" .. total, 1)

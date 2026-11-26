-- @trace order:1255-s4im, order:2200-hkup, order:1442-wyf9, order:2360-ud6i
--
-- test-ensure-hooks.lua — scripts/ensure-hooks.sh arms a checkout's push guards with no
-- Rust toolchain. Scratch repositories built from a COPY of this tree's scripts/ (the
-- working bytes, not the last commit's), a scratch HOME and global config: the live
-- checkout's hooks are never read or written. Ported from the .sh (2360-ud6i).
--
--   1 RED->GREEN: a fresh clone has no hook and a code push is accepted; after
--     ensure-hooks with no cargo on PATH the same push is refused, and the refusal names
--     the container route
--   2 idempotent: a second run is ok:hooks and the hook is byte-identical
--   3 an older marker of ours is upgraded, and so is the one just below the current
--     (a hand-kept list once left every v8 host unrecognized)
--   4 a FOREIGN pre-push is refused (exit 3) and untouched
--   5 NEGATIVE: a local core.hooksPath is honoured, then reads ok; no false gap
--   6 a global core.hooksPath is refused and nothing is written there
--   7 --prelude: inert for a non-GitHub origin; with TILLANDSIAS_ENSURE_HOOKS=1 it installs
--     with stdout EMPTY, is silent when current, and a refusal still exits 0; =0 disables it
--
-- Verdict: ok:ensure-hooks:<n> arms | violation:ensure-hooks:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("ensure-hooks")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
fs.mkdir(W.rel .. "/home"); fs.write(W.rel .. "/home/.gitconfig", "")
local NOTC = "/usr/bin:/bin:/usr/sbin:/sbin" -- only the system dirs: no Rust toolchain
local WANT = fs.read("scripts/install-hooks.sh"):match('\nPREPUSH_MARKER="# (tillandsias%-pre%-push%-v%d+)"\n')
if not WANT then T:refuse("no-subject", "no PREPUSH_MARKER in install-hooks.sh") end

local function run(argv, cwd, extra)
    local e = { HOME = W.abs .. "/home", GIT_CONFIG_GLOBAL = W.abs .. "/home/.gitconfig", GIT_CONFIG_NOSYSTEM = "1",
        GIT_AUTHOR_NAME = "fixture", GIT_AUTHOR_EMAIL = "fixture@example.invalid", GIT_COMMITTER_NAME = "fixture", GIT_COMMITTER_EMAIL = "fixture@example.invalid" }
    for k, v in pairs(extra or {}) do e[k] = v end
    argv.cwd, argv.env, argv.env_unset = cwd, e, { "TILLANDSIAS_*", "GIT_*", "CARGO_TARGET_DIR" }
    local r = T:run(argv)
    return r.code, text.trim(r.stdout or ""), r.stderr or ""
end
local function git(dir, ...)
    local argv = { "git" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    local rc, o, e = run(argv, dir)
    if rc ~= 0 then T:refuse("setup-failed", "git " .. table.concat({ ... }, " ") .. ": " .. e) end
    return o
end

-- One source commit; each arm clones its own bare remote and checkout. --no-local: a
-- local clone hardlinks objects, which macOS git intermittently aborts.
fs.mkdir(W.rel .. "/src/crates/x/src")
fs.write(W.rel .. "/src/crates/x/src/lib.rs", "// code\n")
T:must{ "cp", "-R", ROOT .. "/scripts", W.abs .. "/src/scripts" }
git(W.abs .. "/src", "init", "-q", "-b", "linux-next")
git(W.abs .. "/src", "add", "-A"); git(W.abs .. "/src", "commit", "-q", "-m", "seed")
local function seed(name)
    local c = { rel = W.rel .. "/" .. name .. "/wc", abs = W.abs .. "/" .. name .. "/wc" }
    fs.mkdir(W.rel .. "/" .. name)
    git(W.abs .. "/" .. name, "clone", "-q", "--no-local", "--bare", "../src", "bare.git")
    git(W.abs .. "/" .. name, "clone", "-q", "--no-local", "bare.git", "wc")
    c.hook = c.rel .. "/.git/hooks/pre-push"
    return c
end
local function plant(c, body)
    fs.write(W.rel .. "/hook", body)
    T:must{ "cp", W.abs .. "/hook", c.abs .. "/.git/hooks/pre-push" }
    T:must{ "chmod", "+x", c.abs .. "/.git/hooks/pre-push" }
end
local function ensure(c, arg, e)
    local envs = { PATH = NOTC }
    for k, v in pairs(e or {}) do envs[k] = v end
    local argv = { SH, "scripts/ensure-hooks.sh", arg }
    local rc, o, err = run(argv, c.abs, envs)
    return { rc = rc, out = o, err = err, raw = "rc=" .. tostring(rc) .. " out=[" .. o .. "] err=[" .. err:gsub("\n", " | ") .. "]" }
end
local function hook(c) return fs.exists(c.hook) and fs.read(c.hook) or "" end
local function code(c, s) fs.write(c.rel .. "/crates/x/src/lib.rs", "// " .. s .. "\n"); git(c.abs, "commit", "-q", "--no-verify", "-am", s) end
local function has(o, s) return o:find(s, 1, true) ~= nil end

-- 1, 2
local c = seed("red")
code(c, "change 1")
local rc, _, e = run({ "git", "push", "-q", "origin", "linux-next" }, c.abs)
T:arm("1 RED a fresh clone has no hook and a code push is accepted", not fs.exists(c.hook) and rc == 0, "rc=" .. tostring(rc) .. " " .. e)
local x = ensure(c)
code(c, "change 2")
local prc, po, pe = run({ "git", "push", "origin", "linux-next" }, c.abs, { PATH = NOTC })
T:arm("1 GREEN installed with no cargo on PATH; the same push is refused", x.rc == 0 and x.out == "installed:hooks:" .. WANT and has(hook(c), "# " .. WANT) and prc ~= 0, x.raw .. " push rc=" .. tostring(prc))
if fixture.which("cargo", NOTC) then out.line("note: the remedy arm is not asserted — cargo is on this host's system PATH")
else T:arm("1 the refusal names the container route", has(po .. pe, "toolbox run --container tillandsias-builder cargo build --release -p tillandsias-plan"), po .. pe) end
local before = hook(c)
x = ensure(c)
T:arm("2 a second run is ok:hooks and the hook is byte-identical", x.rc == 0 and x.out == "ok:hooks:" .. WANT and hook(c) == before, x.raw)

-- 3
local PREV = "tillandsias-pre-push-v" .. (tonumber(WANT:match("(%d+)$")) - 1)
for _, old in ipairs{ "tillandsias-pre-push-v7", PREV } do
    c = seed("upgrade-" .. old)
    plant(c, "#!/usr/bin/env bash\n# " .. old .. "\nexit 0\n")
    x = ensure(c)
    T:arm("3 " .. old .. " is upgraded", x.rc == 0 and x.out == "upgraded:hooks:" .. old .. "->" .. WANT and has(hook(c), "# " .. WANT), x.raw)
end

-- 4
c = seed("foreign")
plant(c, "#!/bin/sh\n# the operator's own hook\nexit 0\n")
before = hook(c)
x = ensure(c)
T:arm("4 a foreign pre-push is refused (exit 3, why, remedy) and left byte-identical", x.rc == 3 and x.out == "refused:hooks:foreign-pre-push:" .. c.abs .. "/.git/hooks/pre-push"
    and hook(c) == before and has(x.err, "  why: ") and has(x.err, "  remedy: "), x.raw)

-- 5
c = seed("shared")
fs.mkdir(W.rel .. "/shared/hooks")
git(c.abs, "config", "core.hooksPath", W.abs .. "/shared/hooks")
x = ensure(c)
local again = ensure(c)
T:arm("5 NEGATIVE a local hooksPath is honoured, then reads ok", x.rc == 0 and x.out == "installed:hooks:" .. WANT and fs.exists(W.rel .. "/shared/hooks/pre-push")
    and not fs.exists(c.hook) and again.rc == 0 and again.out == "ok:hooks:" .. WANT, x.raw .. " then " .. again.raw)

-- 6: git canonicalises the dir (/var vs /private/var on macOS), so match the tail.
c = seed("global")
fs.mkdir(W.rel .. "/global-hooks")
git(W.abs, "config", "--global", "core.hooksPath", W.abs .. "/global-hooks")
x = ensure(c)
git(W.abs, "config", "--global", "--unset", "core.hooksPath")
T:arm("6 a global hooksPath is refused and nothing is written there", x.rc == 3 and x.out:find("^refused:hooks:global%-hooks%-path:.*/global%-hooks$") and #fs.list(W.rel .. "/global-hooks") == 0, x.raw)

-- 7
c = seed("prelude")
local ON = { TILLANDSIAS_ENSURE_HOOKS = "1" }
x = ensure(c, "--prelude")
T:arm("7 --prelude is silent and inert for a non-GitHub origin", x.rc == 0 and x.out == "" and x.err == "" and not fs.exists(c.hook), x.raw)
x = ensure(c, "--prelude", ON)
T:arm("7 with TILLANDSIAS_ENSURE_HOOKS=1 it installs, stdout EMPTY, verdict on stderr", x.rc == 0 and x.out == "" and has(x.err, "installed:hooks:" .. WANT) and fs.exists(c.hook), x.raw)
x = ensure(c, "--prelude", ON)
T:arm("7 it is silent when the hook is current", x.rc == 0 and x.out == "" and x.err == "", x.raw)
plant(c, "#!/bin/sh\nexit 0\n")
x = ensure(c, "--prelude", ON)
T:arm("7 a prelude refusal goes to stderr and still exits 0", x.rc == 0 and x.out == "" and has(x.err, "refused:hooks:foreign-pre-push:"), x.raw)
T:must{ "rm", "-f", c.abs .. "/.git/hooks/pre-push" }
x = ensure(c, "--prelude", { TILLANDSIAS_ENSURE_HOOKS = "0" })
T:arm("7 TILLANDSIAS_ENSURE_HOOKS=0 disables the prelude", x.rc == 0 and x.out == "" and x.err == "" and not fs.exists(c.hook), x.raw)
T:finish()

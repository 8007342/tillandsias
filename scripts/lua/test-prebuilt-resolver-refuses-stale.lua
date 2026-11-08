-- @env PATH
-- @trace order:1270-5mz8, spec:ci-release
--
-- test-prebuilt-resolver-refuses-stale.lua — scripts/tillandsias-podman picks a
-- prebuilt tillandsias-podman-cli only when it is NEWER than its sources; a
-- stale one is refused by name with the rebuild command and never executed.
--
-- 2026-09-19, macuahuitl: the litmus runtime shim routes every podman call
-- through scripts/tillandsias-podman, whose profile loop chose a four-day-old
-- debug build by `-x` alone, and two release gates ran the forge lane on code
-- the tree no longer held. The stale "binary" here is a script that writes a
-- marker: the marker proves whether it ran.
--   1 STALE  binary older than a source file: refused:podman-cli-stale:<path>
--            on stderr, non-zero, marker ABSENT (pre-fix: it runs)
--   2 FRESH  binary newer than every source: it runs (negative control: the
--            fix is not "always cargo run")
--
-- Usage: tillandsias-plan script run scripts/lua/test-prebuilt-resolver-refuses-stale.lua
-- Verdict: ok:prebuilt-resolver:stale-refused:2/2 | violation:prebuilt-resolver:<n>-failed

local NAME = "prebuilt-resolver"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end

local REL = "target/plan-scratch/prebuilt-resolver-" .. tostring(time.now_ms())
local ABS = ROOT .. "/" .. REL
local passed, failed = 0, {}
local function arm(name, cond, got)
    if cond then
        passed = passed + 1
        out.line("ok:   " .. name)
    else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

-- A scratch tree shaped like the checkout: the real shim, one source file per
-- crate it watches, a stub podman on PATH (the shim refuses without one), and
-- the prebuilt "binary" that writes a marker when executed.
local function tree(name)
    local r = REL .. "/" .. name
    fs.mkdir(r .. "/scripts")
    fs.mkdir(r .. "/bin")
    fs.mkdir(r .. "/crates/tillandsias-podman-cli/src")
    fs.mkdir(r .. "/crates/tillandsias-podman/src")
    fs.mkdir(r .. "/target/debug")
    fs.write(r .. "/scripts/tillandsias-podman", fs.read("scripts/tillandsias-podman") or "")
    fs.write(r .. "/bin/podman", "#!/usr/bin/env bash\nexit 0\n")
    fs.write(r .. "/crates/tillandsias-podman-cli/src/lib.rs", "// src\n")
    fs.write(r .. "/crates/tillandsias-podman/src/lib.rs", "// src\n")
    fs.write(r .. "/target/debug/tillandsias-podman-cli",
        "#!/usr/bin/env bash\ntouch \"$(dirname \"$0\")/ran.marker\"\necho ran:prebuilt\n")
    local a = ROOT .. "/" .. r
    proc.run({ argv = { "chmod", "+x", a .. "/scripts/tillandsias-podman", a .. "/bin/podman",
        a .. "/target/debug/tillandsias-podman-cli" } })
    return a
end

local function run(a)
    return proc.run({ argv = { "bash", a .. "/scripts/tillandsias-podman", "raw", "ps" },
        env = { PATH = a .. "/bin:" .. (os.getenv and os.getenv("PATH") or "/usr/bin:/bin") },
        timeout_ms = 60000 })
end

-- 1 STALE: the binary predates its sources.
local s = tree("stale")
proc.run({ argv = { "touch", "-d", "2020-01-01", s .. "/target/debug/tillandsias-podman-cli" } })
local r = run(s)
local err = r.stderr or ""
arm("1 STALE a prebuilt older than its sources is refused by name and never runs",
    r.code ~= 0 and err:find("refused:podman-cli-stale:", 1, true) ~= nil
        and err:find("rebuild=cargo build -p tillandsias-podman-cli", 1, true) ~= nil
        and not fs.exists(REL .. "/stale/target/debug/ran.marker"),
    "rc=" .. tostring(r.code) .. " marker=" .. tostring(fs.exists(REL .. "/stale/target/debug/ran.marker"))
        .. "\n" .. (r.stdout or "") .. err)

-- 2 FRESH: the sources predate the binary.
local f = tree("fresh")
proc.run({ argv = { "touch", "-d", "2020-01-01",
    f .. "/crates/tillandsias-podman-cli/src/lib.rs", f .. "/crates/tillandsias-podman/src/lib.rs" } })
r = run(f)
arm("2 FRESH a prebuilt newer than its sources runs",
    r.code == 0 and (r.stdout or ""):find("ran:prebuilt", 1, true) ~= nil
        and fs.exists(REL .. "/fresh/target/debug/ran.marker"),
    "rc=" .. tostring(r.code) .. "\n" .. (r.stdout or "") .. (r.stderr or ""))

proc.run({ argv = { "rm", "-rf", ABS } })
if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.emit("ok:" .. NAME .. ":stale-refused:" .. passed .. "/2", 0)

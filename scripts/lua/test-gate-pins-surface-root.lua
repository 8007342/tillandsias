-- @trace order:1925-ided, order:2301-2r4s, spec:methodology-accountability
--
-- test-gate-pins-surface-root.lua — the gate names its own checkout as the plan
-- binary's validator surface. Ported from the .sh (2301-2r4s).
--
-- The v56.10.30.1 cut's gate refused litmus:claims-fleet-visible 9/22 on a tree
-- whose standalone run was 27/27. With a shared CARGO_TARGET_DIR (1807-shtg) the
-- fixture's scratch repos live under ANOTHER checkout's target/plan-scratch; the
-- plan binary's cwd walk took that checkout as its surface, it sat behind the
-- gated tree, and the pre-push hook refused every fixture push as STALE. So
-- build.sh and local-ci.sh export TILLANDSIAS_SURFACE_ROOT=<the gating checkout>.
--
--   1 REPRODUCER  a shared target inside a different, OLDER checkout, no pin:
--                 claims-fleet-visible refuses STALE. If this does not refuse,
--                 arms 2 and 3 prove nothing.
--   2, 3 THE FIX  the pin, taken by evaluating build.sh's and local-ci.sh's OWN
--                 export line (not re-typed here): claims-fleet-visible passes.
--   4 a caller's value is respected (the :- default, not an overwrite)
--
-- Verdict: ok:gate-pins-surface-root:<n> arms |
--          violation:gate-pins-surface-root:<n>-failed | skip:gate-pins-surface-root:no-validator

local fixture = require "common.fixture"
local T = fixture.new("gate-pins-surface-root")
local ROOT = fixture.repo_root()
local BIN = fixture.plan_binary()
if BIN == "" or T:run{ BIN, "validator-surface-hash", cwd = ROOT }.code ~= 0 then T:skip("no-validator") end
local chk = T:run{ BIN, "validator-surface-hash", "--check", cwd = ROOT }
if chk.code ~= 0 or text.trim(chk.stdout or "") == "" then
    T:refuse("stale-plan-binary", "the resolved plan binary is stale against THIS checkout; rebuild first")
end

-- The OLDER checkout: .git plus the surface files, one of them changed.
local W = T:scratch()
local OLD = W.abs
local MANIFEST = "crates/tillandsias-plan/validator-surface.manifest"
local files = { MANIFEST, "Cargo.lock" }
for _, l in ipairs(text.lines(fs.read(MANIFEST))) do
    local f = l:match("^file%s+(%S+)")
    if f then files[#files + 1] = f end
end
T:must{ "mkdir", "-p", OLD .. "/.git", OLD .. "/target/release" }
for _, f in ipairs(files) do
    T:must{ "mkdir", "-p", OLD .. "/" .. (f:match("^(.*)/[^/]*$") or "") }
    T:must{ "cp", f, OLD .. "/" .. f, cwd = ROOT }
end
local toml = W.rel .. "/crates/tillandsias-plan/Cargo.toml"
fs.write(toml, fs.read(toml) .. "\n# 1925-ided: an older checkout\n")
T:must{ "cp", BIN, OLD .. "/target/release/tillandsias-plan" }

-- proc.run passes TILLANDSIAS_* through and a gate exports this pin, so an absent
-- pin is dropped from the call.
local function claims(pin)
    local e = { CARGO_TARGET_DIR = OLD .. "/target", TILLANDSIAS_SURFACE_ROOT = pin }
    local r = T:run{ fixture.posix_shell(), "scripts/test-claims-fleet-visible.sh", cwd = ROOT, env = e, stdin = "",
        env_unset = { "TILLANDSIAS_SURFACE_ROOT" }, timeout_ms = 180000 }
    local o = "\n" .. (r.stdout or "") .. "\n" .. (r.stderr or "")
    local last = ""
    for _, l in ipairs(text.lines(o)) do
        if l:match("^PASS: claims") or l:match("^FAIL: claims") then last = l end
    end
    return o, last
end
local function export_line(file)
    for _, l in ipairs(text.lines(fs.read(file))) do
        if l:match("^export TILLANDSIAS_SURFACE_ROOT=") then return l end
    end
end
-- What <file>'s own export line yields when its root variable holds `root`.
local function evaluated(file, var, root, caller)
    local line = export_line(file)
    if not line then return "" end
    local sh = (caller and ("TILLANDSIAS_SURFACE_ROOT='" .. caller .. "'\n") or "unset TILLANDSIAS_SURFACE_ROOT\n")
        .. var .. "='" .. root .. "'\n" .. line .. '\nprintf "%s" "$TILLANDSIAS_SURFACE_ROOT"\n'
    return T:run{ fixture.posix_shell(), "-s", stdin = sh, timeout_ms = 10000 }.stdout or ""
end

local o, last = claims(nil)
T:arm("1 REPRODUCER unpinned, a shared target inside an older checkout refuses STALE",
    last:sub(1, 5) == "FAIL:" and o:find("resolved plan binary is STALE", 1, true) ~= nil, "did not refuse STALE: " .. last)
for i, p in ipairs({ { "build.sh", "SCRIPT_DIR" }, { "scripts/local-ci.sh", "REPO_ROOT" } }) do
    local name = (i + 1) .. " " .. p[1] .. "'s own pin makes claims-fleet-visible pass under the same shared target"
    local pin = evaluated(p[1], p[2], ROOT)
    if pin ~= ROOT then
        T:arm(name, false, "it does not export TILLANDSIAS_SURFACE_ROOT=<the gating checkout> (got '" .. pin .. "')")
    else
        _, last = claims(pin)
        T:arm(name, last:sub(1, 5) == "PASS:", last)
    end
end
local got = evaluated("build.sh", "SCRIPT_DIR", "/gate", "/caller/value")
T:arm("4 an existing TILLANDSIAS_SURFACE_ROOT is respected", got == "/caller/value", got)
T:finish()

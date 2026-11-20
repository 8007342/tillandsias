-- @trace order:2146-4svj, spec:ci-release
-- @env PATH
--
-- test-shared-target-forgets-build-scripts.lua —
-- litmus:shared-target-owner-change-reruns-build-scripts.
-- Measured 2026-11-20 on lenovinha: on a shared CARGO_TARGET_DIR, a gate in
-- one worktree ran with tillandsias-embed's assets embedded from ANOTHER
-- worktree's images/ (651 against 653), because the build script's
-- rerun-if-changed paths are absolute paths into the previous owner's
-- checkout and touching this checkout's files does not make cargo rerun it.
-- shared_target_forget_build_scripts removes the run fingerprint and output
-- of every build script whose output names the previous root.
--
-- Usage: tillandsias-plan script run scripts/lua/test-shared-target-forgets-build-scripts.lua
-- Verdict: ok:shared-target-forgets-build-scripts:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("shared-target-forgets-build-scripts")
local ROOT = fixture.repo_root()

local C = T:scratch("canon")
local PREV, CUR, LOOKALIKE = "/fx/wt-1", "/fx/wt-2", "/fx/wt-10"
local function unit(profile, name, rerun_root)
    fs.mkdir(C.rel .. "/" .. profile .. "/build/" .. name)
    fs.mkdir(C.rel .. "/" .. profile .. "/.fingerprint/" .. name)
    fs.write(C.rel .. "/" .. profile .. "/.fingerprint/" .. name .. "/run-build-script", "fp\n")
    fs.write(C.rel .. "/" .. profile .. "/build/" .. name .. "/output",
        "cargo:rerun-if-changed=" .. rerun_root .. "/images\ncargo:rustc-cfg=x\n")
end
unit("debug", "tillandsias-embed-aaa", PREV)
unit("release", "tillandsias-embed-ccc", PREV)
unit("debug", "tillandsias-core-bbb", CUR)
unit("debug", "lookalike-ddd", LOOKALIKE)
local function exists(p) return fs.exists(C.rel .. "/" .. p) end

local r = T:run{ ROOT .. "/scripts/shared-target.sh", "forget-build-scripts", C.abs, PREV, cwd = ROOT,
    env = { PATH = env.get("PATH") } }
T:arm("it reports two build scripts forgotten", text.trim(r.stdout or "") == "2", tostring(r.stdout) .. tostring(r.stderr))
T:arm("a debug build script that read the previous checkout is forgotten (output and fingerprint)",
    not exists("debug/build/tillandsias-embed-aaa") and not exists("debug/.fingerprint/tillandsias-embed-aaa"), "still there")
T:arm("so is a release one",
    not exists("release/build/tillandsias-embed-ccc") and not exists("release/.fingerprint/tillandsias-embed-ccc"), "still there")
T:arm("a build script that read THIS checkout is kept",
    exists("debug/build/tillandsias-core-bbb/output") and exists("debug/.fingerprint/tillandsias-core-bbb/run-build-script"), "removed")
T:arm("a root that only shares a prefix (wt-10 vs wt-1) is kept",
    exists("debug/build/lookalike-ddd/output"), "removed — the match is not anchored on a path boundary")

local none = T:run{ ROOT .. "/scripts/shared-target.sh", "forget-build-scripts", C.abs, "", cwd = ROOT,
    env = { PATH = env.get("PATH") } }
T:arm("no previous root forgets nothing", text.trim(none.stdout or "") == "0" and exists("debug/build/tillandsias-core-bbb/output"),
    tostring(none.stdout))

-- The gate's entry wires it: an owner change from another root forgets.
local src = fs.read("scripts/shared-target.sh") or ""
T:arm("shared_target_enter calls it on an owner change from another root",
    src:find('[ "${prev%% *}" = "$root" ] || _st_forgot="$(shared_target_forget_build_scripts "$canon" "${prev%% *}")"', 1, true) ~= nil,
    "the call in shared_target_enter changed")

T:finish()

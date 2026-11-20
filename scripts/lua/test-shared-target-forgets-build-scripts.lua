-- @trace order:2146-4svj, spec:ci-release
-- @env PATH HOME
--
-- test-shared-target-forgets-build-scripts.lua —
-- litmus:shared-target-owner-change-reruns-build-scripts.
-- Measured 2026-11-20 on lenovinha: on a shared CARGO_TARGET_DIR, gates linked
-- tillandsias-embed build-script units built from OTHER worktrees (651 assets
-- against the tree's 653), because cargo reruns a build script that emits
-- rerun-if-changed only when THOSE absolute paths change. A first fix forgot
-- only the previous owner's outputs and a unit from a third worktree stayed.
-- shared_target_forget_build_scripts forgets every build script whose
-- recorded paths belong to a checkout other than ROOT (longest root wins).
--
-- A real scratch clone with three linked worktrees (wt-1, wt-2, wt-10) under
-- its own target/work, so the root list comes from `git worktree list` exactly
-- as in production.
--
-- Usage: tillandsias-plan script run scripts/lua/test-shared-target-forgets-build-scripts.lua
-- Verdict: ok:shared-target-forgets-build-scripts:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("shared-target-forgets-build-scripts")
local ROOT = fixture.repo_root()

local M = T:git_repo("clone")
local W = {}
for _, n in ipairs{ "wt-1", "wt-2", "wt-10" } do
    W[n] = M.abs .. "/target/work/" .. n
    T:must{ "git", "-C", M.abs, "worktree", "add", "-q", "--detach", W[n] }
end
-- The shared target dir is the clone's target/, which CONTAINS the
-- worktrees (target/work/*), exactly as on the fleet's hosts.
local CANON_REL = M.rel .. "/target"
local CANON = M.abs .. "/target"
fs.mkdir(CANON_REL)

local units = {
    { "debug", "embed-from-wt1", W["wt-1"] .. "/images" },
    { "release", "embed-from-wt1-rel", W["wt-1"] .. "/images" },
    { "debug", "embed-from-wt2", W["wt-2"] .. "/images" },
    { "debug", "embed-from-wt10", W["wt-10"] .. "/images" },
    { "debug", "embed-from-main", M.abs .. "/images" },
    { "debug", "embed-from-deleted", M.abs .. "/target/work/wt-gone/images" },
    { "debug", "registry-crate", "/fx-cargo-registry/src/somecrate/build.rs" },
    { "debug", "out-dir-only", CANON .. "/debug/build/out-dir-only/out/generated.rs" },
}
local function make()
    for _, u in ipairs(units) do
        fs.mkdir(CANON_REL .. "/" .. u[1] .. "/build/" .. u[2])
        fs.mkdir(CANON_REL .. "/" .. u[1] .. "/.fingerprint/" .. u[2])
        fs.write(CANON_REL .. "/" .. u[1] .. "/.fingerprint/" .. u[2] .. "/run-build-script", "fp\n")
        fs.write(CANON_REL .. "/" .. u[1] .. "/build/" .. u[2] .. "/output",
            "cargo:rerun-if-changed=" .. u[3] .. "\ncargo:rustc-cfg=x\n")
    end
end
local function kept(profile, name)
    return fs.exists(CANON_REL .. "/" .. profile .. "/build/" .. name .. "/output")
        and fs.exists(CANON_REL .. "/" .. profile .. "/.fingerprint/" .. name .. "/run-build-script")
end
local function gone(profile, name)
    return not fs.exists(CANON_REL .. "/" .. profile .. "/build/" .. name)
        and not fs.exists(CANON_REL .. "/" .. profile .. "/.fingerprint/" .. name)
end
local function forget(root)
    return T:run{ ROOT .. "/scripts/shared-target.sh", "forget-build-scripts", CANON, root, cwd = ROOT,
        env = { PATH = env.get("PATH"), HOME = env.get("HOME") } }
end

-- Owner becomes wt-2.
make()
local r = forget(W["wt-2"])
T:arm("owner wt-2: five units from other checkouts are forgotten", text.trim(r.stdout or "") == "5",
    tostring(r.stdout) .. tostring(r.stderr))
T:arm("a unit built from wt-1 is forgotten (debug and release)",
    gone("debug", "embed-from-wt1") and gone("release", "embed-from-wt1-rel"), "still there")
T:arm("a unit built from a THIRD worktree (not the previous owner) is forgotten", gone("debug", "embed-from-wt10"), "kept")
T:arm("a unit built from the main checkout is forgotten", gone("debug", "embed-from-main"), "kept")
T:arm("a unit built from a deleted worktree (now under the main checkout) is forgotten",
    gone("debug", "embed-from-deleted"), "kept")
T:arm("this checkout's own unit is kept", kept("debug", "embed-from-wt2"), "removed")
T:arm("a unit naming only the cargo registry is kept", kept("debug", "registry-crate"), "removed")
T:arm("a unit naming only the target dir (OUT_DIR) is kept", kept("debug", "out-dir-only"), "removed")

-- Owner becomes wt-1: wt-10 is ANOTHER checkout, not a prefix of wt-1.
make()
forget(W["wt-1"])
T:arm("owner wt-1 keeps its own unit", kept("debug", "embed-from-wt1"), "removed")
T:arm("owner wt-1 forgets wt-10's unit (a path boundary, not a prefix)", gone("debug", "embed-from-wt10"), "kept")

-- Owner becomes the main checkout: its worktrees' units are other checkouts.
make()
forget(M.abs)
T:arm("owner main keeps its own unit and forgets its worktrees'",
    kept("debug", "embed-from-main") and gone("debug", "embed-from-wt2") and gone("debug", "embed-from-wt1"), "wrong set")

local src = fs.read("scripts/shared-target.sh") or ""
T:arm("shared_target_enter calls it on every owner change",
    src:find('_st_forgot="$(shared_target_forget_build_scripts "$canon" "$root")"', 1, true) ~= nil,
    "the call in shared_target_enter changed")

for _, n in ipairs{ "wt-1", "wt-2", "wt-10" } do T:run{ "git", "-C", M.abs, "worktree", "remove", "--force", W[n] } end
T:finish()

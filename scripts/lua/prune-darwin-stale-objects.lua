-- @trace order:1924-dobj, order:2106-scrt
--
-- prune-darwin-stale-objects.lua — prune loose object files that no linked
-- binary can use. Ported from scripts/prune-darwin-stale-objects.sh (2106-scrt)
-- onto the scratch.* door, which reaches a CARGO_TARGET_DIR outside the repo.
--
-- darwin builds with split-debuginfo=unpacked. A linked binary's debug map
-- (its OSO stabs) points at two things: the loose <crate>-<hash>.*.rcgu.o of
-- its OWN crate-hash, and rlib members for every dependency (measured with
-- nm -ap on a test binary, 2026-10-29). So a loose .o group is only ever
-- read when an executable named exactly <crate>-<hash> sits beside it. Every
-- other group is a library's objects whose code already lives in its rlib,
-- and cargo never collects them: they reached 1.2M files and stalled every
-- CoreFoundation test process 3-16 s.
--
-- USAGE   tillandsias-plan script run scripts/lua/prune-darwin-stale-objects.lua <target>/debug/deps
-- OUTPUT  one line: pruned:darwin-stale-objects:files=N groups=M kept=K
--         or skipped:darwin-stale-objects:<why>, then the verdict line
--         (ok:darwin-stale-objects / skip:darwin-stale-objects:build-holds-lock).
-- Run it before cargo. Fleet hosts share one target dir across worktrees, so
-- another build.sh may be compiling into it: every build.sh holds a SHARED
-- flock on <target>/.tillandsias-prune.lock while it runs cargo, and this
-- takes it EXCLUSIVE and non-blocking, skipping if any build holds it.

local NAME = "darwin-stale-objects"
local deps = arg and arg[1]
if not deps or deps == "" then
    verdict.refused(NAME, "usage: prune-darwin-stale-objects.lua <deps-dir>")
end
deps = deps:gsub("/+$", "")

-- The root is the target dir, two levels above deps (<target>/debug/deps).
local target = deps:match("^(.*)/[^/]+/[^/]+$")
if not target then verdict.refused(NAME, "deps dir is not <target>/<profile>/deps: " .. deps) end
local profile = deps:sub(#target + 2)
scratch.declare(target)

if not scratch.exists(profile) then
    out.line("pruned:darwin-stale-objects:files=0 groups=0 kept=0 (no " .. deps .. ")")
    verdict.ok(NAME, "absent")
end

local lock = scratch.lock(".tillandsias-prune.lock", { timeout_ms = 0 })
if not lock then
    out.line("skipped:darwin-stale-objects:a build holds " .. target
        .. "/.tillandsias-prune.lock (shared); pruning next time")
    verdict.skip(NAME, "build-holds-lock")
end

local files = scratch.list(profile)
local exe = {}
for _, n in ipairs(files) do
    local h = n:match("^[%w_]+%-([0-9a-f]+)$")
    if h and #h == 16 then
        exe[n] = true
    end
end
local gone, kept, pruned = {}, {}, 0
for _, n in ipairs(files) do
    if n:sub(-7) == ".rcgu.o" then
        local grp = n:match("^([^.]*)")
        if exe[grp] then
            kept[grp] = true
        else
            scratch.rm(profile .. "/" .. n)
            pruned = pruned + 1
            gone[grp] = true
        end
    end
end
local ng, nk = 0, 0
for _ in pairs(gone) do ng = ng + 1 end
for _ in pairs(kept) do nk = nk + 1 end
lock:release()
out.line(string.format("pruned:darwin-stale-objects:files=%d groups=%d kept=%d", pruned, ng, nk))
verdict.ok(NAME, tostring(pruned))

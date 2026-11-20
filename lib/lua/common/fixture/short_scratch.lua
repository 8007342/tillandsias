-- @trace order:2118-asur
-- common.fixture.short_scratch — one helper of the common.fixture kit. The kit
-- installs every module in lib/lua/common/fixture/ onto its test object, so
-- adding a helper is adding a file: sibling branches that each add one never
-- touch the same lines (operator 2026-11-20, landing-pipeline P4 row 3).
-- A module returns function(T, ctx); ctx = { scratch_root = fn, SCRATCH = path }.
return function(T, ctx)
-- A scratch dir with the shortest name the kit can give, for a fixture whose
-- subject is path length (unix-socket SUN_LEN). Same {rel=, abs=} and cleanup.
function T:short_scratch()
    self.seq = self.seq + 1
    local leaf = "s" .. tostring(time.now_ms() % 10000000) .. self.seq
    ctx.scratch_root()
    local d = { rel = ctx.SCRATCH .. "/" .. leaf, abs = scratch.mkdir(leaf), leaf = leaf }
    self.dirs[#self.dirs + 1] = d
    return d
end
end

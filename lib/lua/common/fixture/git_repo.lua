-- @trace order:2118-asur
-- common.fixture.git_repo — one helper of the common.fixture kit. The kit
-- installs every module in lib/lua/common/fixture/ onto its test object, so
-- adding a helper is adding a file: sibling branches that each add one never
-- touch the same lines (operator 2026-11-20, landing-pipeline P4 row 3).
-- A module returns function(T, ctx); ctx = { scratch_root = fn, SCRATCH = path }.
return function(T, ctx)
-- A scratch git repo with a fixed identity and one commit on `main`.
-- The identity is local to the repo, so no ambient identity leaks in.
function T:git_repo(tag)
    local d = self:scratch(tag or "repo")
    self:must{ "git", "init", "-q", "-b", "main", d.abs }
    self:must{ "git", "-C", d.abs, "config", "user.email", "fixture@example.invalid" }
    self:must{ "git", "-C", d.abs, "config", "user.name", "fixture" }
    self:must{ "git", "-C", d.abs, "config", "commit.gpgsign", "false" }
    fs.write(d.rel .. "/README", "fixture\n")
    self:must{ "git", "-C", d.abs, "add", "README" }
    self:must{ "git", "-C", d.abs, "commit", "-q", "-m", "init" }
    return d
end
end

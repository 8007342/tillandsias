-- @trace spec:meta-orchestration, order:531, order:1637-5765
-- @env PWD
--
-- check-forge-expert-base.lua — executable Forge Expert Base Guard (plan order
-- 531). Ported from scripts/check-forge-expert-base.sh, the shell-to-lua item
-- 1637-5765 carried; same rule, grammar, exit codes and stderr remedy.
--
-- Makes "a forge must not be launched from a base that cannot build the plan
-- expert" a verifiable check with a pass/fail exit code, instead of something an
-- agent notices after the fact. Breach record: on 2026-07-30 an in-forge Claude
-- session found BOTH experts returning confidence=unsupported to the milestone's
-- own exemplar question, while the launch state truthfully read `experts: ready`.
-- Two earlier cycles had absorbed the same condition by noticing and
-- hand-rebasing (plan/loop_status.md:203, :243) — the guard-by-attentive-agent
-- pattern this project forbids.
--
-- ROOT CAUSE this guard closes. The launcher seeds a forge's branch from the HOST
-- CHECKOUT's current branch (read_host_project_current_branch ->
-- TILLANDSIAS_FORGE_SEED_BRANCH), and the guest converges to it
-- (images/default/lib-common.sh checkout_forge_seed_branch). So whatever branch
-- this checkout is parked on becomes the next forge's base. `main` carries no
-- crates/tillandsias-plan/src/answer.rs, so a forge seeded from it builds a
-- PRE-EXPERT binary and then reports itself ready — truthful state, wrong
-- artifact, which is the hardest kind to catch.
--
-- WHY THE TEST IS SOURCE PRESENCE, NOT A BRANCH NAME. The names linux-next /
-- windows-next / osx-next / main are Tillandsias's OWN conventions and are
-- explicitly "NOT a runtime convention of the product"
-- (methodology/multi-host-development.yaml): a forge launched on an end user's
-- project must not assume them. Source presence is a fact about the checkout
-- and is therefore safe to assert anywhere. It also catches the case a
-- branch-name test cannot — when the seed and the actual branch AGREE because
-- the host checkout was itself parked on a pre-expert base, nothing looks wrong.
--
-- Emits exactly one line on stdout matching the falsifiable grammar
--   ^(ok:(expert-base-ready|no-plan-crate)|blocked:(expert-sources-absent|not-a-git-repo))$
-- and exits 0 (safe to launch a forge) or 1 (blocked).
--
--   ok:expert-base-ready        the plan crate is present AND carries the expert
--                               engine sources; a forge seeded here can answer
--   ok:no-plan-crate            this project has no plan-expert crate at all —
--                               normal off-Tillandsias, nothing to expect
--   blocked:expert-sources-absent  a plan crate exists but the expert engine
--                               sources do not; a forge seeded here will report
--                               `experts: ready` and answer `unsupported`
--   blocked:not-a-git-repo      cwd is not inside a git worktree (fail closed)
--
-- Run it from the checkout a forge will be launched FROM, which is the host
-- checkout — not from inside the forge. The checkout may be any project, so
-- every read goes through proc.run (git, test) in the caller's cwd: the
-- runtime's fs reads are confined to the repository the runner lives in.

-- The modules that make the difference between an expert binary and a
-- pre-expert one. answer.rs carries the cited-envelope engine; methodology.rs
-- the YAML path query. Either being absent means the built binary cannot serve
-- an expert query.
local EXPERT_SOURCES = {
    "crates/tillandsias-plan/src/answer.rs",
    "crates/tillandsias-plan/src/methodology.rs",
}

-- The CALLER's directory, named explicitly: a proc.run without `cwd` runs in
-- the runner's repository root, which would judge the wrong checkout and
-- never see "not a git repo" (measured in the port's parity check).
local here = env.get("PWD")
if here == nil or here == "" then verdict.emit("blocked:not-a-git-repo", 1) end

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, cwd = here, timeout_ms = 30000 })
local root = (top.stdout or ""):gsub("%s+$", "")
if top.status ~= "exited" or top.code ~= 0 or root == "" then
    verdict.emit("blocked:not-a-git-repo", 1)
end

local function test(flag, rel)
    local r = proc.run({ argv = { "test", flag, root .. "/" .. rel }, cwd = here })
    return r.status == "exited" and r.code == 0
end

if not test("-d", "crates/tillandsias-plan") then
    verdict.emit("ok:no-plan-crate", 0)
end

local missing = {}
for _, rel in ipairs(EXPERT_SOURCES) do
    if not test("-f", rel) then missing[#missing + 1] = rel end
end

if #missing > 0 then
    log.raw("[forge-expert-base] This checkout has crates/tillandsias-plan but is MISSING: " .. table.concat(missing, " "))
    log.raw("[forge-expert-base] A forge launched from here is seeded with this branch")
    log.raw("[forge-expert-base] (read_host_project_current_branch -> TILLANDSIAS_FORGE_SEED_BRANCH),")
    log.raw("[forge-expert-base] so it will build a PRE-EXPERT binary, report 'experts: ready',")
    log.raw("[forge-expert-base] and answer every plan_answer / methodology_path with")
    log.raw("[forge-expert-base] confidence=unsupported. Order 531.")
    log.raw("[forge-expert-base] REMEDY: switch this checkout to a branch carrying the expert")
    log.raw("[forge-expert-base] sources before launching a forge:")
    log.raw("[forge-expert-base]     git branch -a --contains $(git rev-list -1 HEAD -- crates/tillandsias-plan/src/answer.rs)")
    log.raw("[forge-expert-base] On the Tillandsias repo itself that is the host's platform branch")
    log.raw("[forge-expert-base] (see methodology/multi-host-development.yaml branch_canon).")
    verdict.emit("blocked:expert-sources-absent", 1)
end

verdict.emit("ok:expert-base-ready", 0)

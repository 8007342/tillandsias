-- @trace order:1525-c6jm, order:795-imz3
--
-- check-no-spawn-in-if-not.lua — PORTED from check-no-spawn-in-if-not.sh,
-- byte for byte. Enforces that `if ! <pipeline containing a spawn>` is banned
-- in scripts/. This prevents inverted guards caused by pipefail and
-- early-exiting consumers like `grep -q`.
--
-- Population: explicit file arguments if given (`-- file1 file2 ...`),
-- otherwise every `git ls-files 'scripts/*.sh' 'build.sh'` — exactly the .sh's
-- population, and a git failure (no repo, no match) is the SAME silent empty
-- population the .sh's `|| true` produced.
--
-- WHAT THE PORT MAKES UNREPRESENTABLE RATHER THAN AVOIDS: the .sh printed
-- NOTHING on stdout on a refusal (every diagnostic line was `>&2`). The one
-- runner that hosts every Lua decider always emits exactly one stdout verdict
-- line, so this port prints one more stdout line on refusal than the .sh did.
-- Every stderr line is unchanged, in the same order. Checked against every
-- live caller (build.sh's `_run_lua_decider` merges nothing special — it just
-- branches on exit code; the fixture devnulls both streams; the litmus only
-- asserts the clean-tree exit path): none parses refusal stdout content.
--
-- Verdicts (unchanged grammar):
--   ok:no-spawn-in-if-not                  exit 0
--   refused:no-spawn-in-if-not:<n>         exit 1 (NEW stdout line; see above)
local IF_NOT = [=[^[[:space:]]*(if|elif)[[:space:]]+![[:space:]]]=]
local SINGLE_PIPE = [=[(^|[^|])\|([^|]|$)]=]

local files = {}
if #arg > 0 then
    for i = 1, #arg do files[#files + 1] = arg[i] end
else
    local res = proc.run({ argv = { "git", "ls-files", "scripts/*.sh", "build.sh" } })
    if res.status == "exited" and res.code == 0 then
        for _, l in ipairs(text.lines(res.stdout)) do
            if l ~= "" then files[#files + 1] = l end
        end
    end
end

local violations = {}
for _, f in ipairs(files) do
    if f ~= "scripts/check-no-spawn-in-if-not.sh" and f ~= "scripts/lua/check-no-spawn-in-if-not.lua" then
        local ok, content = pcall(fs.read, f)
        if ok then
            local n = 0
            for _, line in ipairs(text.lines(content)) do
                n = n + 1
                if not text.contains(line, "# sigpipe-ok:") and text.is_match(line, IF_NOT) and text.is_match(line, SINGLE_PIPE) then
                    violations[#violations + 1] = f .. ":" .. n .. ":" .. line
                end
            end
        end
    end
end

if #violations > 0 then
    log.raw("violation:spawn-in-if-not: found " .. #violations .. " violations")
    for _, v in ipairs(violations) do log.raw("  " .. v) end
    log.raw("Do not use 'if ! <pipeline>' because pipefail + SIGPIPE can invert the guard.")
    log.raw("Instead, capture output and use the case idiom, or append '# sigpipe-ok: <reason>'.")
    verdict.refused("no-spawn-in-if-not:" .. #violations)
end

verdict.ok("no-spawn-in-if-not")

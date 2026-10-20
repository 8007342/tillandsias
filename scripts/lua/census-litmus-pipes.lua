-- @trace order:1800-nvsc, order:1624-bv73
--
-- census-litmus-pipes.lua — the counter for the `litmus-piped-commands`
-- carried-obligation backlog (methodology/convergence.yaml): how many litmus
-- `command:` lines still pipe, by the FAMILY of decision they make, so each
-- family slice of 1800-nvsc has a number that must fall and the backlog has a
-- counter that can be read at two refs.
--
-- COUNTING. A `command:` value with its outer YAML quote removed; pipes are
-- counted QUOTE-AWARE (single- and double-quoted spans dropped, `||` dropped)
-- so `grep 'a|b'` is not a pipe, matching check-shell-ratchet.lua's litmus
-- arm. A command is classified by the FIRST rule it matches, in this order
-- (the keyword census of 2026-10-19, scratchpad classify.pl):
--   cargo-test, cargo-other, script-output, structured-field, plan-query,
--   git-query, podman-probe, process, file-grep, text-transform, other
-- Minority families are UPPER BOUNDS: a command that merely mentions podman
-- in an argument is counted as podman-probe.
--
-- Verdicts (advisory counter; never refuses):
--   ok:litmus-pipe-census:piped=<n>:three-plus=<m>:<family>=<k>...   exit 0
--   could-not-run:litmus-pipe-census:empty-population               exit 3
-- `-- --list <family>` prints each command of one family as file:line on
-- stderr, for a slice picking its batch.

local function lines(s) local t = {}; for l in ((s or "") .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end; return t end

local ORDER = { "cargo-test", "cargo-other", "script-output", "structured-field", "plan-query",
    "git-query", "podman-probe", "process", "file-grep", "text-transform", "other" }
local RULES = {
    { "cargo-test", [[\bcargo\s+(\+\S+\s+)?(test|nextest)\b]] },
    { "cargo-other", [[\bcargo\s+(\+\S+\s+)?(build|check|clippy|metadata|tree|fmt|doc|run)\b]] },
    { "script-output", [[(\bscript run\b|(bash|sh|\./)\s*\S*scripts/[\w\-/]+\.(sh|lua)|\bmf_stage\b)]] },
    { "structured-field", [[\b(jq|yq)\b|tillandsias-plan\s+(yaml-get|yaml-json|json|yaml)\b]] },
    { "plan-query", [[tillandsias-plan\b]] },
    { "git-query", [[\bgit\s+(-C\s+\S+\s+)?(log|rev-parse|merge-base|ls-remote|show|diff|branch|ls-files|ls-tree|cat-file|rev-list|status|grep|config|tag|for-each-ref|blame|describe)\b]] },
    { "podman-probe", [[\b(podman|buildah|skopeo|docker)\b]] },
    { "process", [[\b(systemctl|journalctl|pgrep|ss|netstat|curl|wget|stat|df|du|lsof|uname|loginctl|busctl|gdbus|readelf|ldd)\b]] },
    { "file-grep", [[\b(grep|rg|egrep|fgrep)\b]] },
    { "text-transform", [[\b(sed|awk|sort|uniq|cut|tr|wc|head|tail|xargs|find|ls|cat|printf|echo|nl|paste|comm|diff|tee)\b]] },
}

-- quote-aware pipe count: drop escapes, quoted spans and `||`
local function pipes(c)
    local s = c:gsub("\\.", "")
    s = s:gsub("'[^']*'", "")
    s = s:gsub('"[^"]*"', "")
    s = s:gsub("||", "")
    local _, n = s:gsub("|", "")
    return n
end

local list_family
for i = 1, #arg do if arg[i] == "--list" then list_family = arg[i + 1] end end

local files = fs.walk("openspec/litmus-tests", { suffix = ".yaml" })
local counts, piped, three_plus, total = {}, 0, 0, 0
for _, f in ipairs(ORDER) do counts[f] = 0 end
for _, f in ipairs(files) do
    local okr, body = pcall(fs.read, f)
    if okr then
        for ln, l in ipairs(lines(body)) do
            local c = l:match('^%s*%-?%s*command:%s*"(.*)"%s*$') or l:match("^%s*%-?%s*command:%s*'(.*)'%s*$")
            if c then
                total = total + 1
                c = c:gsub('\\"', '"')
                local n = pipes(c)
                if n > 0 then
                    piped = piped + 1
                    if n >= 3 then three_plus = three_plus + 1 end
                    local fam = "other"
                    for _, r in ipairs(RULES) do
                        if text.is_match(c, r[2]) then fam = r[1]; break end
                    end
                    counts[fam] = counts[fam] + 1
                    if list_family == fam then log.raw(f .. ":" .. ln .. ": " .. c:sub(1, 160)) end
                end
            end
        end
    end
end
if total == 0 then
    verdict.could_not_run("litmus-pipe-census:empty-population", "no command: lines under openspec/litmus-tests")
end
local parts = { "piped=" .. piped, "three-plus=" .. three_plus }
for _, f in ipairs(ORDER) do parts[#parts + 1] = f .. "=" .. counts[f] end
verdict.ok("litmus-pipe-census", table.unpack(parts))

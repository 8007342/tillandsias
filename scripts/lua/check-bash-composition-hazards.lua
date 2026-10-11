-- @trace order:1252-r72q, order:1268-fx87, spec:ci-release
--
-- check-bash-composition-hazards.lua — PORTED from
-- check-bash-composition-hazards.sh (carried obligation shell->lua, paid by
-- 1268-fx87). ADVISORY report of the four measured bash composition hazards,
-- over the tree-sitter-bash parse in tillandsias-litmus-rust.
--
-- ADVISORY TIER, DELIBERATELY. This is NOT a gate step and must not become one
-- until the reported population is owned by a row (1252-r72q exit criterion 4):
-- 545 candidate pipelines would red trunk for every host on a backlog nobody
-- owns, and a guard that reds trunk gets disabled rather than obeyed. It
-- ALWAYS EXITS 0.
--
-- WHAT THE PORT FIXES RATHER THAN COPIES. The .sh handed every scripts/*.sh
-- path to ONE command line. On Windows that is "Argument list too long"
-- (measured on yolanda 2026-10-10, 900+ paths): the binary never ran, the
-- `|| true` swallowed it, and the check printed NOTHING with exit 0 — an
-- advisory that silently reported nothing on one platform. The paths now go
-- in batches and the counts are summed (each file is in exactly one batch, so
-- the sums are the same numbers one call would print).
--
-- Verdicts (the binary's own lines, in its order; the LAST is the verdict):
--   advisory:bash-hazards:scanned=<n>
--   advisory:bash-hazards:<shape>:pipelines=<n>:files=<n>   (last + " (advisory)")
--   skip:bash-hazards:no-binary      the litmus binary is not built
--
-- Root: arg[1] (default "scripts").

local ROOT_DIR = arg[1] or "scripts"

-- Prefer the freshly built binary, and verify it by RUNNING it: `bash-hazards`
-- with no paths is a usage error naming the subcommand, which proves THIS
-- binary has it (the plan-binary-probe rule, 1172-dyvd).
local BIN
for _, cand in ipairs({
    "target/release/tillandsias-litmus-rust", "target/release/tillandsias-litmus-rust.exe",
    "target/debug/tillandsias-litmus-rust", "target/debug/tillandsias-litmus-rust.exe",
}) do
    if fs.exists(cand) then
        local p = proc.run({ argv = { cand, "bash-hazards" } })
        if p.status == "exited" and text.contains((p.stdout or "") .. (p.stderr or ""), "bash-hazards") then
            BIN = cand
            break
        end
    end
end
if BIN == nil then
    verdict.emit("skip:bash-hazards:no-binary", 0)
end

local files = {}
local ok_walk, walked = pcall(fs.walk, ROOT_DIR)
if ok_walk and walked then
    for _, f in ipairs(walked) do
        if f:sub(-3) == ".sh" then files[#files + 1] = f end
    end
end
table.sort(files)
if #files == 0 then
    verdict.advisory("advisory:bash-hazards:scanned=0 (advisory)")
end

local BATCH = 100
local scanned, order, pipes, nfiles = 0, {}, {}, {}
for i = 1, #files, BATCH do
    local argv = { BIN, "bash-hazards" }
    for j = i, math.min(i + BATCH - 1, #files) do argv[#argv + 1] = files[j] end
    local r = proc.run({ argv = argv, timeout_ms = 600000 })
    for _, l in ipairs(text.lines(r.stdout or "")) do
        local n = l:match("^advisory:bash%-hazards:scanned=(%d+)$")
        if n then
            scanned = scanned + tonumber(n)
        else
            local shape, p, f = l:match("^advisory:bash%-hazards:([%w%-]+):pipelines=(%d+):files=(%d+)$")
            if shape then
                if pipes[shape] == nil then
                    order[#order + 1] = shape
                    pipes[shape], nfiles[shape] = 0, 0
                end
                pipes[shape] = pipes[shape] + tonumber(p)
                nfiles[shape] = nfiles[shape] + tonumber(f)
            elseif l ~= "" then
                out.line(l)
            end
        end
    end
end

out.line("advisory:bash-hazards:scanned=" .. scanned)
if #order == 0 then
    verdict.advisory("advisory:bash-hazards:scanned=" .. scanned .. " (advisory)")
end
for k = 1, #order - 1 do
    local s = order[k]
    out.line("advisory:bash-hazards:" .. s .. ":pipelines=" .. pipes[s] .. ":files=" .. nfiles[s])
end
local last = order[#order]
verdict.advisory("advisory:bash-hazards:" .. last .. ":pipelines=" .. pipes[last] .. ":files=" .. nfiles[last] .. " (advisory)")

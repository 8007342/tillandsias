-- @trace order:968-uhzg, spec:methodology-accountability, order:2066-obsv
-- @env TILLANDSIAS_EXACT_VERSION_BASE TILLANDSIAS_GATE_DIFF_BASE
--
-- check-exact-version-literal-added.lua — refuse a NEW exact-version comparison
-- against a bare numeric literal unless it states why. (Ported from
-- scripts/check-exact-version-literal-added.sh: the shell-to-lua item order
-- 2066-obsv carried. Its history is in
-- `git log -- scripts/check-exact-version-literal-added.sh`.)
--
-- THE DEFECT (968-uhzg, found by lenovinha 2026-09-02). host-capability-probe.sh
-- validated `schema_version == 2` EXACTLY, so the bump to 3 — the change that
-- made the row worth republishing — made the row unpublishable. An exact pin
-- makes the FIRST bump fail, and stays latent until someone bumps.
--
-- WHAT IS REFUSED: an ADDED line that compares a version-named field to a BARE
-- NUMBER with an exact operator (== != -eq -ne), in shell, jq or Rust:
--     .schema_version == 2      [ "$v" -eq 3 ]      self.version != 1
-- WHAT IS ADMITTED:
--   * a floor or range (>= <= > <);
--   * a comparison against a NAMED constant (== SCHEMA_VERSION);
--   * an exact literal that states its reason with an `exact-version: <why>`
--     marker on the line or in the four lines above.
--
-- DIFF-SCOPED: only lines this change ADDS (tracked and untracked), so standing
-- code is not re-litigated. Test fixtures (scripts/test-*.sh), comment lines
-- and assert lines are skipped: a test states the expected value exactly.
--
-- The port keeps the .sh's scope, pattern, skips and verdicts. Every call is
-- argv through proc.run; the repository is the one the caller stands in.
--
-- Grammar (one line on stdout; each refused site on stderr):
--   ok:exact-version-literal-added:<n> checked                      exit 0
--   violation:exact-version-literal-added:<n>                       exit 1
--   ok:exact-version-literal-added:base-unavailable                 exit 0  (no base ref; nothing judged)
--   could-not-run:exact-version-literal-added                       exit 3  (not inside a git work tree)
--
-- Pinned by scripts/test-exact-version-literal-added.sh (gate step 968-uhzg).

local function nonempty(v) return v ~= nil and v ~= "" end

local function git(argv, cwd)
    local r = proc.run({ argv = argv, cwd = cwd, timeout_ms = 60000 })
    if r.status ~= "exited" or r.code ~= 0 then return nil end
    return r.stdout or ""
end

local top = git({ "git", "rev-parse", "--show-toplevel" })
if not top then
    verdict.could_not_run("exact-version-literal-added", "not inside a git work tree")
end
local ROOT = text.trim(top)

local base_ref = env.get("TILLANDSIAS_EXACT_VERSION_BASE")
if not nonempty(base_ref) then base_ref = env.get("TILLANDSIAS_GATE_DIFF_BASE") end
if not nonempty(base_ref) then base_ref = "origin/linux-next" end

if not git({ "git", "rev-parse", "--verify", "--quiet", base_ref }, ROOT) then
    log.raw("  note: base ref '" .. base_ref .. "' unavailable — added-line enforcement skipped")
    verdict.ok("exact-version-literal-added", "base-unavailable")
end

-- A version-named field compared EXACTLY to a bare number (shell/jq and Rust).
-- Between the name and the operator: up to 8 characters that are not part of
-- another comparison, so `>=`/`<=` never match.
local PAT = [=[([A-Za-z_]*[Vv][Ee][Rr][Ss][Ii][Oo][Nn][A-Za-z_]*)[^=!<>]{0,8}(==|!=|-eq|-ne)[[:space:]]*["']?[0-9]+([^0-9A-Za-z_.]|$)]=]

local SPECS = { "scripts/*.sh", "build.sh", "images/*.sh", "images/**/*.sh", "crates/**/*.rs" }
local function with_specs(argv)
    argv[#argv + 1] = "--"
    for _, s in ipairs(SPECS) do argv[#argv + 1] = s end
    return argv
end

local seen, files = {}, {}
for _, argv in ipairs({
    with_specs({ "git", "diff", "--name-only", "--diff-filter=AM", base_ref }),
    with_specs({ "git", "ls-files", "--others", "--exclude-standard" }),
}) do
    for _, f in ipairs(text.lines(git(argv, ROOT) or "")) do
        f = text.trim(f)
        if f ~= "" and not seen[f] then
            seen[f] = true
            files[#files + 1] = f
        end
    end
end
table.sort(files)

-- New-file line numbers of the lines a unified -U0 diff adds.
local function added_lines(diff)
    local out, n = {}, 0
    for _, l in ipairs(text.lines(diff)) do
        if text.starts_with(l, "@@") then
            local start = l:match("^@@ %-[%d,]+ %+(%d+)")
            n = tonumber(start) or 0
        elseif text.starts_with(l, "+++") then
            -- file header
        elseif text.starts_with(l, "+") then
            out[#out + 1] = n
            n = n + 1
        end
    end
    return out
end

local checked, violations = 0, 0
for _, f in ipairs(files) do
    local path = ROOT .. "/" .. f
    local skip = text.starts_with(f, "scripts/test-") and f:sub(-3) == ".sh"
    if fs.exists(path) and not skip then
        checked = checked + 1
        local body = fs.read(path) or ""
        local lines = text.lines(body)
        local added
        if git({ "git", "ls-files", "--error-unmatch", "--", f }, ROOT) then
            added = added_lines(git({ "git", "diff", "-U0", base_ref, "--", f }, ROOT) or "")
        else
            added = {}
            for i = 1, #lines do added[#added + 1] = i end
        end
        for _, ln in ipairs(added) do
            local line = lines[ln] or ""
            local trimmed = line:gsub("^%s+", "")
            local is_comment = text.starts_with(trimmed, "#") or text.starts_with(trimmed, "//")
            if not text.contains(line, "assert") and not is_comment and text.is_match(line, PAT) then
                local reasoned = false
                for i = math.max(1, ln - 4), ln do
                    if text.contains(lines[i] or "", "exact-version:") then reasoned = true; break end
                end
                if not reasoned then
                    violations = violations + 1
                    log.raw("REFUSED: " .. f .. ":" .. ln .. " compares a version to a BARE NUMBER exactly:")
                    log.raw("    " .. trimmed)
                    log.raw("  An exact pin makes the FIRST bump fail and stays latent until someone")
                    log.raw("  bumps (968-uhzg). Use a floor (>=) if newer versions are acceptable,")
                    log.raw("  compare against a NAMED constant so a bump changes one place, or keep")
                    log.raw("  it exact and say why: an `exact-version: <reason>` comment on the line")
                    log.raw("  or just above it.")
                end
            end
        end
    end
end

if violations > 0 then
    log.raw("  why: each site above pins a version to a bare number exactly, so the first bump fails (968-uhzg)")
    log.raw("  remedy: use a floor (>=), a named constant, or an exact-version: <reason> marker, as each REFUSED block says")
    verdict.emit("violation:exact-version-literal-added:" .. violations, 1)
end
verdict.ok("exact-version-literal-added", checked .. " checked")

-- @trace order:1473-scdq, order:1472-3d29, order:2242-rspn, spec:methodology-accountability
-- @env TILLANDSIAS_RUST_PIN_BASE TILLANDSIAS_GATE_DIFF_BASE
--
-- check-rust-source-pin-added.lua — PORTED from check-rust-source-pin-added.sh
-- (2242-rspn), same rule, same verdicts, same exit codes.
--
-- A test that pins a literal in SOURCE TEXT read by include_str! can be green
-- while the product is broken: the literal can be present and never reach
-- runtime, and it breaks on correct refactors (1472-3d29, 827-d3dc survey).
-- DIFF-SCOPED: only `.contains(` lines this change ADDS to crates/**/*.rs.
-- A site is refused when the receiver of the line's (last) non-negated
-- `.contains(` is SOURCE TEXT in its enclosing fn — bound by include_str! of a
-- source file, or by a `let` whose right-hand side uses such a variable (two
-- hops) — unless `// source-pin-ok: <why>` sits within 3 lines above, or the
-- test carries a negative control (negative control | NEG- | must FAIL |
-- negative_control) from 12 lines before its fn to its end.
--
--   ok:rust-source-pin-added:<n> checked
--   ok:rust-source-pin-added:base-unavailable    (no base ref; nothing judged)
--   violation:rust-source-pin-added:<n>          (rc 1; each site on stderr)
--   --check-file <file> <ln,ln,...>              judge those lines only:
--     ok:rust-source-pin-added:checked | violation:rust-source-pin-added:<n>

local INC = [[let\s+(mut\s+)?([A-Za-z_][A-Za-z0-9_]*)[^=]*=\s*include_str!\(.*\.(rs|sh|ps1|toml|yaml|yml|json|plist|template)"]]
local NEG = [[(?i)negative control|NEG-|must FAIL|negative_control]]
local FN = [[^\s*(pub(\([a-z]+\))?\s+)?fn\s]]
local FN_END = [[^\s*(#\[test\]|(pub(\([a-z]+\))?\s+)?fn\s)]]

local function lines_of(s)
    local t = {}
    for l in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do t[#t + 1] = l end
    if t[#t] == "" then t[#t] = nil end
    return t
end

-- The name after the LAST `let [mut] ` on a line (sed's greedy `.*let`).
local function last_let_name(l)
    local name
    for m in l:gmatch("let%s+([%a_][%w_]*)") do name = m end
    if name == "mut" then
        for m in l:gmatch("let%s+mut%s+([%a_][%w_]*)") do name = m end
    end
    return name
end
-- The name after a leading `let [mut] `.
local function lead_let_name(l)
    local n = l:match("^%s*let%s+mut%s+([%a_][%w_]*)")
    if n then return n end
    n = l:match("^%s*let%s+([%a_][%w_]*)")
    return n
end

local function judge(L, ln)
    local line = L[ln] or ""
    local trimmed = line:match("^%s*(.*)$")
    if trimmed:sub(1, 2) == "//" then return true end
    -- the receiver of the LAST `X.contains(` whose preceding char is not `!`
    -- or a word char (sed's greedy `.*[^!A-Za-z0-9_]X\.contains\(`)
    local var
    local s = " " .. line
    for i = 2, #s do
        local name = s:match("^([%a_][%w_]*)%.contains%(", i)
        if name and not s:sub(i - 1, i - 1):match("[!%w_]") then var = name end
    end
    if not var then return true end
    local fnstart = 0
    for i = 1, ln do if text.is_match(L[i], FN) then fnstart = i end end
    if fnstart == 0 then return true end
    local src = {}
    for i = fnstart, ln do
        if text.is_match(L[i], INC) then
            local n = last_let_name(L[i]); if n then src[n] = true end
        end
    end
    for _ = 1, 2 do
        for i = fnstart, ln do
            local l = L[i]
            if l:match("^%s*let%s") then
                local lhs = lead_let_name(l)
                if lhs and not src[lhs] then
                    local rhs = l:match("^[^=]*=(.*)$") or l
                    for v in pairs(src) do
                        if rhs:find("%f[%w_]" .. v .. "%f[^%w_]") then src[lhs] = true; break end
                    end
                end
            end
        end
    end
    if not src[var] then return true end
    for i = (ln > 3 and ln - 3 or 1), ln do
        if text.is_match(L[i], [[source-pin-ok:\s*\S]]) then return true end
    end
    local fnend = #L
    for i = ln + 1, #L do
        if text.is_match(L[i], FN_END) then fnend = i - 1; break end
    end
    for i = (fnstart > 12 and fnstart - 12 or 1), fnend do
        if text.is_match(L[i], NEG) then return true end
    end
    return false
end

local function report(f, L, ln)
    local t = (L[ln] or ""):match("^%s*(.*)$")
    log.raw("REFUSED: " .. f .. ":" .. ln .. " adds a test pinning a literal in SOURCE text read by include_str!:\n"
        .. "    " .. t .. "\n"
        .. "  why: a literal in source can be present and never reach runtime, and it breaks\n"
        .. "       on correct refactors; this shape kept a product defect green (1472-3d29,\n"
        .. "       827-d3dc survey).\n"
        .. "  remedy: assert on the value a function BUILDS (e.g. provision_user_data_for_test(),\n"
        .. "       readiness::ready_unit()) instead of its source text; or add a negative\n"
        .. "       control to this test; or, if the source text IS the subject, mark the line\n"
        .. "       // source-pin-ok: <why the text itself is the contract>")
end

local function git(...)
    local p = proc.run{ argv = { "git", ... }, timeout_ms = 120000 }
    return p.ok, p.stdout or ""
end

if arg[1] == "--check-file" then
    local f, list = arg[2], arg[3] or ""
    if not f then verdict.emit("usage:rust-source-pin-added:--check-file <file> <lines>", 2) end
    local L = lines_of(fs.read(f))
    local bad = 0
    for n in list:gmatch("[^,%s]+") do
        local ln = tonumber(n)
        if ln and not judge(L, ln) then report(f, L, ln); bad = bad + 1 end
    end
    if bad > 0 then
        verdict.emit("violation:rust-source-pin-added:" .. bad, 1,
            "  why: the lines above pin source text with no negative control or reason\n"
            .. "  remedy: apply the remedy each REFUSED block names, then re-run")
    end
    verdict.emit("ok:rust-source-pin-added:checked", 0)
end

local base = env.get("TILLANDSIAS_RUST_PIN_BASE") or env.get("TILLANDSIAS_GATE_DIFF_BASE") or "origin/linux-next"
-- `^{commit}` (2241-f8jg): a bare 40-hex "verifies" with no such object here,
-- and every diff after it would fail quietly and judge nothing.
if not select(1, git("rev-parse", "--verify", "--quiet", base .. "^{commit}")) then
    verdict.emit("ok:rust-source-pin-added:base-unavailable", 0,
        "  note: base ref '" .. base .. "' unavailable — added-line enforcement skipped")
end

local set, files = {}, {}
local _, d = git("diff", "--name-only", "--diff-filter=AM", base, "--", "crates/**/*.rs")
local _, u = git("ls-files", "--others", "--exclude-standard", "--", "crates/**/*.rs")
for _, f in ipairs(lines_of(d .. "\n" .. u)) do
    if f ~= "" and not set[f] then set[f] = true; files[#files + 1] = f end
end
table.sort(files)

local checked, violations = 0, 0
for _, f in ipairs(files) do
    if fs.exists(f) then
        checked = checked + 1
        local L = lines_of(fs.read(f))
        local added = {}
        if select(1, git("ls-files", "--error-unmatch", "--", f)) then
            local _, diff = git("diff", "-U0", base, "--", f)
            local n = 0
            for _, l in ipairs(lines_of(diff)) do
                local h = l:match("^@@ %S+ %+(%d+)")
                if h then n = tonumber(h)
                elseif l:sub(1, 3) == "+++" then -- header
                elseif l:sub(1, 1) == "+" then added[#added + 1] = n; n = n + 1 end
            end
        else
            for i = 1, #L do added[#added + 1] = i end
        end
        for _, ln in ipairs(added) do
            if (L[ln] or ""):find(".contains(", 1, true) and not judge(L, ln) then
                report(f, L, ln); violations = violations + 1
            end
        end
    end
end

if violations > 0 then
    verdict.emit("violation:rust-source-pin-added:" .. violations, 1,
        "  why: each site above pins source text read by include_str! with no negative control or reason (1473-scdq)\n"
        .. "  remedy: apply the remedy each REFUSED block names, then re-run this check")
end
verdict.emit("ok:rust-source-pin-added:" .. checked .. " checked", 0)

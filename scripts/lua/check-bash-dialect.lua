-- @env TILLANDSIAS_DIALECT_SCAN_DIR TILLANDSIAS_DIALECT_SCAN_FILES TILLANDSIAS_BOOTSTRAP_ALLOWLIST
-- @read-env TILLANDSIAS_DIALECT_SCAN_DIR TILLANDSIAS_DIALECT_SCAN_FILES TILLANDSIAS_BOOTSTRAP_ALLOWLIST
-- @trace order:761-g36m, order:1055-6yp8, order:1374-4u6i, order:1384-ddua
--
-- check-bash-dialect.lua — a script that bash 3.2 (the only bash macOS ships)
-- cannot run, or that silently misbehaves under BSD date/du/sed/awk, is
-- refused unless it carries a BASH_VERSINFO refusal guard or a named exemption.
--
-- PORTED from check-bash-dialect.sh (1384-ddua), every idiom, exemption,
-- diagnostic and verdict kept byte for byte. What the port makes
-- UNREPRESENTABLE rather than avoided:
--   * 1374-4u6i, the mapfile double count: the .sh summed a grep per pattern
--     over one file, and one mapfile line matched two patterns. Here a FILE is
--     a set element (`bad[f] = true`) counted once, whatever matches it.
--   * 1132-r4mt, `\b` meaning nothing on BSD grep/awk: every pattern runs on the
--     binary's regex engine, the same on every host.
--   * the empty population read as clean: `population` is a typed branch.
--
-- Verdicts (legacy grammar, legacy exit codes):
--   ok:bash-dialect-clean                      exit 0
--   blocked:bash4-unguarded:<n>                exit 1
--   blocked:bash-dialect:scan-empty            exit 1
--   blocked:bash-dialect:scan-files-multiple   exit 1
local M = {
  unguarded_hits = [===[[check-bash-dialect] UNGUARDED bash-4-ism in '$f' (first hits):]===],
  allow_note = [===[[check-bash-dialect] note: '$base' is allowlisted but carries no bash-4-ism any more — shrink the allowlist (761-g36m burndown)]===],
  gnudate = [===[[check-bash-dialect] UNEXEMPTED GNU-date-ism in '$f' (BSD date succeeds with garbage output — exit-code guards cannot catch it):]===],
  gnudu = [===[[check-bash-dialect] UNEXEMPTED GNU-du-ism in '$f' (BSD du REFUSES -b, so the substitution is empty and a '|| n=0' fallback silently becomes the answer):]===],
  gnused = [===[[check-bash-dialect] UNEXEMPTED GNU-sed class in '$f' (BSD sed does not implement \S \s \w \b \d and does NOT error — the substitution silently leaves the input unchanged, so the consumer gets the whole line; see 803-bqte):]===],
  bash4 = [===[[check-bash-dialect] UNEXEMPTED bash-4 builtin in '$f' (mapfile/readarray/read -N do not exist in bash 3.2; darwin errors and then reports a violation against a healthy tree; see 1055-6yp8):]===],
  procsub = [===[[check-bash-dialect] SOURCED process substitution in '$f' (bash 3.2 — the only bash macOS ships — sources NOTHING from '. <(cmd)' and returns 0, so the consumer reads an empty variable; redded every macOS gate via 1349-53h6 arm5, see 1373-sr9g). Use eval "$(cmd)":]===],
  emptyarr = [===[[check-bash-dialect] EMPTY-ARRAY expansion under set -u in '$f' (bash 3.2 — the only bash macOS ships — dies with 'unbound variable' on an EMPTY array here, while bash 4.4+ expands to nothing, so this is invisible on linux/windows and fatal on darwin; broke 747-knbp 2026-08-30). Use ${arr[@]+"${arr[@]}"}:]===],
  awkv = [===[[check-bash-dialect] MULTI-LINE awk -v value in '$f' (BSD awk — the awk macOS ships — rejects a newline in a -v assignment with 'newline in string' and prints nothing; the program splits this variable on "\n", so it IS multi-line. Silent on darwin, and fully silent under 2>/dev/null or || true; 1399-wtpq). Pass it via the environment: NAME="$var" awk '... ENVIRON["NAME"] ...':]===],
  caseincs = [===[[check-bash-dialect] UNPARENTHESISED case pattern inside $( ) in '$f' (bash 3.2 — the only bash macOS ships — ends the substitution at the pattern's ')' and the script does not parse; quoted "$( )" passes bash -n, then yields EMPTY or the rest of the line as the value; redded every Mac gate via 84f37ff24, 1413-8bee). Write EVERY arm as (pat), or call a function through $(f):]===],
  summary = [===[[check-bash-dialect] $unguarded file(s) carry bash-4-only constructs with no BASH_VERSINFO refusal guard and no allowlist entry. Either write the script bash-3.2-clean (see agent-identity.sh's case-table lowercase) or add an early exit-nonzero version refusal. Do NOT extend the allowlist — it is a burndown list (761-g36m).]===],
  allow_left = [===[[check-bash-dialect] $allowlisted_hits allowlisted legacy carrier(s) remain (761-g36m burndown)]===],
  scan_multi = [===[[check-bash-dialect] TILLANDSIAS_DIALECT_SCAN_FILES names ONE path (file or directory); got: '$TILLANDSIAS_DIALECT_SCAN_FILES']===],
  scan_empty = [===[[check-bash-dialect] TILLANDSIAS_DIALECT_SCAN_DIR='${SCAN_DIR}' matched no .sh file.]===],
}
local function sub(s, t) return (s:gsub("%$([%a_]+)", function(k) return t[k] or ("$" .. k) end):gsub("%${([%a_]+)}", function(k) return t[k] or ("${" .. k .. "}") end)) end
local function err(s) log.raw(s) end

local PAT_EXPANSION = [=[\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)]=]
local PAT_BUILTIN = [=[(^|[^A-Za-z0-9_])(mapfile|readarray)([^A-Za-z0-9_]|$)]=]
local PAT_ASSOC = [=[(declare|local|typeset|readonly) +-[a-zA-Z]*[Agn]]=]
local PAT_PRINTF_T = [=[%\([^)]*\)T]=]
local PAT_GNUDATE = [=[(^|[^A-Za-z0-9_])date[^|;&()]*\+[^ "]*%-?[0-9]*N|(^|[^A-Za-z0-9_])date( +-[A-Za-z-]+)* +(-d|--date)[ =]]=]
local PAT_GNUDU = [=[(^|[^A-Za-z0-9_])du( +-[A-Za-z-]+)* +-[A-Za-z]*b|(^|[^A-Za-z0-9_])du[^|;&()]* --bytes]=]
local PAT_GNUSED = [=[(^|[^A-Za-z0-9_])sed[^|;&()]*\\[SsWwBbDd]]=]
local PAT_BASH4 = [=[(^|[^A-Za-z0-9_])(mapfile|readarray)([^A-Za-z0-9_]|$)|(^|[^A-Za-z0-9_])read([[:space:]]+-[A-Za-z]*)*[[:space:]]+-[A-Za-z]*N]=]
local PAT_PROCSUB_SOURCE = [=[(^|[[:space:];&|(])(\.|source)[[:space:]]+<\(]=]
local PAT_EMPTYARR = [=[for +[A-Za-z_][A-Za-z0-9_]* +in +"\$\{[A-Za-z_][A-Za-z0-9_]*\[@\]\}"]=]
local MAIN = PAT_EXPANSION .. "|" .. PAT_BUILTIN .. "|" .. PAT_ASSOC .. "|" .. PAT_PRINTF_T
-- The .sh's candidate prefilter, ported: one multi-line match per file decides
-- whether any rule could fire, and a file that matches nothing is skipped
-- whole. Over-matching is harmless here (a candidate is only examined), and it
-- is what keeps the port inside the door's deadline.
local TRIGGER = "(?m)" .. table.concat({ PAT_EXPANSION, PAT_BUILTIN, PAT_ASSOC, PAT_PRINTF_T, PAT_GNUDATE,
    PAT_GNUDU, PAT_GNUSED, PAT_BASH4, PAT_PROCSUB_SOURCE, PAT_EMPTYARR,
    [=[-v[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="?\$]=], [=[\$\(.*case[[:space:]]]=], [=[\$\([[:space:]]*$]=] }, "|")
local ALLOWLIST = {}   -- empty since 761-g36m's burndown; the branch is kept

local function read(p) local ok, s = pcall(fs.read, p); if ok then return s end; return nil end
local function lines_of(s) local t = {}; for l in (s .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end; if s:sub(-1) == "\n" then t[#t] = nil end; return t end
local function code_lines(raw) local out = {}; for i, l in ipairs(raw) do out[i] = (l:gsub("#.*$", "")) end; return out end
local function grep_n(code, pat) local hits = {}; for i, l in ipairs(code) do if text.is_match(l, pat) then hits[#hits + 1] = { n = i, s = i .. ":" .. l } end end; return hits end
local function has(l, lit) return l ~= nil and l:find(lit, 1, true) ~= nil end
local function head3(list, fmt) for i = 1, math.min(3, #list) do err(fmt and fmt(list[i]) or list[i].s) end end

-- ── scan population ────────────────────────────────────────────────────────
local scan_dir_env = env.get("TILLANDSIAS_DIALECT_SCAN_DIR")
local scan_files_env = env.get("TILLANDSIAS_DIALECT_SCAN_FILES")
if (scan_dir_env == nil or scan_dir_env == "") and scan_files_env and scan_files_env ~= "" then
    if scan_files_env:find("%s") then
        err(sub(M.scan_multi, { TILLANDSIAS_DIALECT_SCAN_FILES = scan_files_env }))
        verdict.emit("blocked:bash-dialect:scan-files-multiple", 1)
    end
    scan_dir_env = scan_files_env
end
local SCAN_DIR = (scan_dir_env and scan_dir_env ~= "") and scan_dir_env or "scripts"
local files = {}
if read(SCAN_DIR) then
    files[1] = SCAN_DIR
else
    local base = SCAN_DIR:gsub("/+$", "")
    local d1, d2 = {}, {}
    local ok, all = pcall(fs.walk, base, { suffix = ".sh" })
    for _, f in ipairs(ok and all or {}) do
        local rel = f:sub(#base + 2)
        local depth = select(2, rel:gsub("/", "")) + 1
        if depth == 1 then d1[#d1 + 1] = f elseif depth == 2 then d2[#d2 + 1] = f end
    end
    for _, f in ipairs(d1) do files[#files + 1] = f end
    for _, f in ipairs(d2) do files[#files + 1] = f end
end
if (scan_dir_env == nil or scan_dir_env == "") and read("build.sh") then files[#files + 1] = "build.sh" end

local allow_path = env.get("TILLANDSIAS_BOOTSTRAP_ALLOWLIST") or "scripts/portability/bootstrap-shell-allowlist.txt"
local boot = {}
for _, l in ipairs(lines_of(read(allow_path) or "")) do
    local first = l:match("^%s*(%S+)")
    if first and not first:find("^#") then boot[first] = true end
end
local nb = 0
for _, f in ipairs(files) do if boot[(f:gsub("^%./", ""))] then nb = nb + 1 end end
err(("population=%d bootstrap=%d"):format(#files, nb))

if #files == 0 then
    err(sub(M.scan_empty, { SCAN_DIR = SCAN_DIR }))
    err("  CAUSE: the path is neither a readable file nor a directory containing *.sh or */*.sh. Nothing was judged.")
    err("  REMEDY: point it at an existing directory or a single .sh file. Do not read this as a passing dialect check — no file was read at all.")
    verdict.emit("blocked:bash-dialect:scan-empty", 1)
end

-- ── the two awk state machines, ported line for line ───────────────────────
local function awkv_sites(raw)
    local out = {}
    for i, s in ipairs(raw) do
        if not text.is_match(s, [=[^[[:space:]]*#]=]) and not has(s, "# awk-v-multiline: ok") then
            for _, m in ipairs(text.captures_all(s, [=[-v[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)="?\$]=])) do
                for j = i, math.min(i + 20, #raw) do
                    if has(raw[j], "split(" .. m .. ",") and has(raw[j], '"\\n"') then out[#out + 1] = i .. ":" .. m; break end
                end
            end
        end
    end
    return out
end

local CASE_LINE = [=[^[[:space:]]*case[[:space:]].*[[:space:]]in[[:space:]]*$]=]
local function arms_bad(t)
    local parts, start = {}, 1
    while true do
        local a, b = t:find(";;", start, true)
        if not a then parts[#parts + 1] = t:sub(start); break end
        parts[#parts + 1] = t:sub(start, a - 1); start = b + 1
    end
    for _, seg in ipairs(parts) do
        seg = seg:gsub("^%s+", "")
        if not (seg == "" or seg:find("^esac") or seg:find("^%)")) then
            if seg:sub(1, 1) ~= "(" then return true end
        end
    end
    return false
end
local function case_in_cs_sites(raw)
    local out, in_case, cs_open = {}, 0, false
    for nr, s in ipairs(raw) do
        if text.is_match(s, [=[^[[:space:]]*#]=]) or has(s, "# case-in-cs: ok") then goto continue end
        if in_case > 0 then
            if text.is_match(s, [=[^[[:space:]]*esac([[:space:];)]|$)]=]) then
                in_case = in_case - 1; if in_case == 0 then cs_open = false end
            elseif text.is_match(s, CASE_LINE) then
                in_case = in_case + 1
            else
                local a, b = text.find(s, [=[^[[:space:]]*[^([:space:]#][^[:space:]]*\)]=])
                if a then
                    local tok = s:sub(a, b)
                    if not has(tok, "$(") and not has(tok, "=") then out[#out + 1] = tostring(nr) end
                end
            end
            goto continue
        end
        if cs_open and text.is_match(s, [=[^[[:space:]]*\)]=]) then cs_open = false end
        if cs_open and text.is_match(s, CASE_LINE) then in_case = 1; goto continue end
        if text.is_match(s, [=[\$\([[:space:]]*$]=]) then cs_open = true; goto continue end
        do
            local rest = s
            while true do
                local p = rest:find("$(", 1, true)
                if not p then break end
                rest = rest:sub(p + 2)
                local cpos, depth, L = 0, 1, #rest
                local k = 1
                while k <= L and depth > 0 do
                    local c = rest:sub(k, k)
                    if c == "(" then depth = depth + 1
                    elseif c == ")" then depth = depth - 1
                    elseif c == "c" and text.is_match(rest:sub(k, k + 4), [=[^case[[:space:]]]=])
                        and (k == 1 or text.is_match(rest:sub(k - 1, k - 1), [=[[[:space:];&|(]]=])) then
                        cpos = k + 5; break
                    end
                    k = k + 1
                end
                if cpos > 0 then
                    local after = rest:sub(cpos)
                    local a, b = text.find(after, [=[[[:space:]]in([[:space:]]|$)]=])
                    if a then
                        local tail = after:sub(b + 1)
                        if text.is_match(tail, [=[^[[:space:]]*$]=]) then in_case = 1; break end
                        if arms_bad(tail) then out[#out + 1] = tostring(nr); break end
                    end
                end
            end
        end
        ::continue::
    end
    return out
end

-- ── per file ───────────────────────────────────────────────────────────────
local unguarded, allowlisted_hits = 0, 0
for _, f in ipairs(files) do
    local src = read(f)
    local base = f:match("([^/]+)$")
    if src and not ALLOWLIST[base] and not text.is_match(src, TRIGGER) then src = nil end
    if src and base ~= "check-bash-dialect.sh" and not base:find("^test%-check%-bash%-dialect") then
        local raw = lines_of(src)
        local code = code_lines(raw)
        local file_bad = false
        local guard = text.first_match(src, [=[BASH_VERSINFO|# bash-dialect: dual]=], { lines = 40 }) ~= nil
        local hits = grep_n(code, MAIN)
        if #hits > 0 then
            if guard then
            elseif ALLOWLIST[base] then allowlisted_hits = allowlisted_hits + 1
            else err(sub(M.unguarded_hits, { f = f })); head3(hits); file_bad = true end
        elseif ALLOWLIST[base] then
            err(sub(M.allow_note, { base = base }))
        end
        local function exempt_filter(pat, lit, near)
            local bad = {}
            for _, h in ipairs(grep_n(code, pat)) do
                local skip = false
                if near then
                    for j = h.n, math.min(h.n + 2, #raw) do if text.is_match(raw[j], near) then skip = true end end
                end
                if not skip and not has(raw[h.n], lit) then bad[#bad + 1] = h end
            end
            return bad
        end
        local b
        b = exempt_filter(PAT_GNUDATE, "# gnu-date: ok", [=[date( +-[A-Za-z-]+)* +-(v|j|jf|r|f)]=])
        if #b > 0 then err(sub(M.gnudate, { f = f })); head3(b); file_bad = true end
        b = exempt_filter(PAT_GNUDU, "# gnu-du: ok", [=[du( +-[A-Za-z-]+)* +-[A-Za-z]*(k|m|h)]=])
        if #b > 0 then err(sub(M.gnudu, { f = f })); head3(b); file_bad = true end
        b = exempt_filter(PAT_GNUSED, "# gnu-sed: ok")
        if #b > 0 then err(sub(M.gnused, { f = f })); head3(b); file_bad = true end
        b = exempt_filter(PAT_BASH4, "# bash4: ok")
        if #b > 0 then err(sub(M.bash4, { f = f })); head3(b); file_bad = true end
        b = exempt_filter(PAT_PROCSUB_SOURCE, "# procsub-source: ok")
        if #b > 0 then err(sub(M.procsub, { f = f })); head3(b); file_bad = true end
        local ea = {}
        if text.count_lines(src, [=[^set -[a-z]*u]=]) > 0 then
            for _, h in ipairs(exempt_filter(PAT_EMPTYARR, "# maybe-empty: ok")) do
                local names = text.captures_all(h.s, [=[in *"\$\{([A-Za-z_][A-Za-z0-9_]*)\[@\]\}"]=])
                local arr = names[#names]
                if arr and arr ~= "" and text.count_lines(src, "^[[:space:]]*" .. arr .. [=[=\(\)]=]) > 0 then ea[#ea + 1] = h end
            end
        end
        if #ea > 0 then err(sub(M.emptyarr, { f = f })); head3(ea); file_bad = true end
        local av = awkv_sites(raw)
        if #av > 0 then err(sub(M.awkv, { f = f })); for i = 1, math.min(3, #av) do err("  " .. f .. ":" .. av[i]) end; file_bad = true end
        local cc = case_in_cs_sites(raw)
        if #cc > 0 then err(sub(M.caseincs, { f = f })); for i = 1, math.min(3, #cc) do err("  " .. f .. ":" .. cc[i]) end; file_bad = true end
        if file_bad then unguarded = unguarded + 1 end
    end
end

if unguarded > 0 then
    err(sub(M.summary, { unguarded = tostring(unguarded) }))
    verdict.emit("blocked:bash4-unguarded:" .. unguarded, 1)
end
if allowlisted_hits > 0 then err(sub(M.allow_left, { allowlisted_hits = tostring(allowlisted_hits) })) end
verdict.ok("bash-dialect-clean")

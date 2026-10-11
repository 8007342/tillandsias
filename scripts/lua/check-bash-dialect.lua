-- @env TILLANDSIAS_DIALECT_SCAN_DIR TILLANDSIAS_DIALECT_SCAN_FILES TILLANDSIAS_BOOTSTRAP_ALLOWLIST
-- @read-env TILLANDSIAS_DIALECT_SCAN_DIR TILLANDSIAS_DIALECT_SCAN_FILES TILLANDSIAS_BOOTSTRAP_ALLOWLIST
-- @trace order:761-g36m, order:1055-6yp8, order:1374-4u6i, order:1384-ddua, order:1553-x8js
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
  sedbrace = [===[[check-bash-dialect] UNTERMINATED sed brace group in '$f' (BSD sed — the sed macOS ships — requires ';' or a newline before EVERY '}', including one closing a nested group; '{p}', '{n;s#a#b#}', '{s/x/y/}' and '{{p;}}' are fatal there: sed prints 'extra characters at the end of ... command', writes NOTHING, and a '> file' redirection leaves an EMPTY file that a cmp-only mutation check reads as a real mutation; 1545-qdb5, 1553-x8js). Write '{p;}', '{n;s#a#b#;}', '{{p;};}':]===],
  sedi = [===[[check-bash-dialect] SUFFIXLESS sed -i in '$f' (BSD sed takes the NEXT argument as the backup suffix, so 'sed -i EXPR file' reads the file name as the script and fails, or edits nothing; 'sed -i "" ...' is the BSD spelling and GNU reads the empty string as the script; 1127-waxf, 1553-x8js). Write 'sed EXPR f > f.tmp && mv f.tmp f', or 'sed -i.bak EXPR f && rm -f f.bak':]===],
  statc = [===[[check-bash-dialect] GNU-only stat -c in '$f' with no BSD 'stat -f' fallback in the same expression or function (BSD stat has no -c: it errors, the substitution is EMPTY, and a '|| echo ""' or a regex guard turns that into a quiet wrong answer — e.g. an orphaned lease never aged; 1553-x8js). Add '|| stat -f <bsd-format>' or use an mf_* helper from scripts/litmus-stdlib.sh:]===],
  site_note = [===[[check-bash-dialect] note: site allowlist entry '$key' matched nothing any more — shrink SITE_ALLOWLIST (1553-x8js burndown)]===],
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
-- 1553-x8js: the sed/stat rules have their OWN prefilter (a plain-Lua find for
-- the command word, in the per-file loop), so a file the TRIGGER skips is
-- still read by them, and the TRIGGER's population is unchanged.
local ALLOWLIST = {}   -- empty since 761-g36m's burndown; the branch is kept

-- 1553-x8js: SITE allowlist for the sed-brace / sed-i / stat-c rules, for a
-- site that is justified Linux-only or owned elsewhere and must not be edited
-- here. A line-level marker ('# stat-c: ok (reason)', '# sed-i: ok (reason)',
-- '# sed-brace: ok (reason)') is the house pattern when the file may be edited;
-- this table is for when it may not. Every entry carries a reason, and an
-- entry that matches nothing is reported, so the list can only shrink.
-- key = "<path>|<rule>|<literal substring of the offending line>"
local SITE_ALLOWLIST = {
  -- a '\'-continued condition line: a trailing marker comment would end the continuation
  ["scripts/check-archive-answerability.sh|stat-c|stat -f -c '%T' \"$REPO_ROOT\""] =
    "GNU file-system-mode v9fs probe; BSD fails it to empty, which correctly reads as not-9P",
  -- YAML fixture DATA inside a heredoc: the mutation-arm guard reads it as text, nothing runs it
  ["scripts/test-litmus-mutation-arm-guard.sh|sed-i|sed -i 's/foo/bar/' \\\"$t/f\\\""] =
    "litmus YAML fixture data in a heredoc, read as text by the guard under test and never executed",
}
local SITE_ALLOWLIST_HIT = {}
for k, why in pairs(SITE_ALLOWLIST) do
  assert(type(why) == "string" and why:find("%S"), "SITE_ALLOWLIST entry without a reason: " .. k)
end

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

-- ── 1553-x8js: sed / stat invocations, read as shell words ────────────────
-- Line-based, like the rules above: a command word is found at a COMMAND
-- POSITION (line start, after | ; & ( { ` ! or a keyword) outside quotes, so a
-- string that MENTIONS "sed -i" is not an invocation. Its words are then read
-- with shell quoting; a quoted script left open joins the following lines.
-- Expansions ($x, ${x}, $(..)) read as '1': the rules judge the literal
-- structure, never a value only known at run time.
local CMD_KEYWORDS = { ["then"] = true, ["do"] = true, ["else"] = true, ["if"] = true, ["elif"] = true,
  ["while"] = true, ["until"] = true, ["xargs"] = true, ["command"] = true, ["exec"] = true,
  ["time"] = true, ["env"] = true, ["!"] = true }

-- Positions (1-based) where `word` starts a command on line s.
local function command_sites(s, word)
  local out, ctx, i, L = {}, { "n" }, 1, #s   -- ctx stack: n(one) / s(ingle) / d(ouble)
  local wl = #word
  local tokstart, prevtok = true, ""
  while i <= L do
    local c, q = s:sub(i, i), ctx[#ctx]
    if q == "s" then
      if c == "'" then ctx[#ctx] = "n" end
      i = i + 1
    elseif c == "\\" then
      i = i + 2
    elseif q == "d" then
      if c == '"' then ctx[#ctx] = "n"; i = i + 1
      elseif s:sub(i, i + 1) == "$(" then ctx[#ctx + 1] = "n"; ctx[#ctx + 1] = "("; tokstart = true; prevtok = "("; i = i + 2
      else i = i + 1 end
    else
      if c == "'" then ctx[#ctx] = "s"; tokstart = false; i = i + 1
      elseif c == '"' then ctx[#ctx] = "d"; tokstart = false; i = i + 1
      elseif c == "#" and tokstart then break
      elseif c == ")" and ctx[#ctx - 1] == "(" then ctx[#ctx] = nil; ctx[#ctx] = nil; tokstart = false; prevtok = ")"; i = i + 1
      elseif s:sub(i, i + 1) == "$(" then ctx[#ctx + 1] = "("; ctx[#ctx + 1] = "n"; tokstart = true; prevtok = "("; i = i + 2
      elseif c:find("[|;&({`]") then tokstart = true; prevtok = c; i = i + 1
      elseif c:find("[ \t]") then tokstart = true; i = i + 1
      elseif tokstart then
        local j = i
        while j <= L and not s:sub(j, j):find("[ \t|;&(){}`'\"<>]") do j = j + 1 end
        local tok = s:sub(i, j - 1)
        local bare = tok:match("([^/]+)$") or tok
        local atcmd = prevtok == "" or prevtok:find("^[|;&({`]") or CMD_KEYWORDS[prevtok]
            or (prevtok:find("^[A-Za-z_][A-Za-z0-9_]*=") ~= nil)
        if bare == word and atcmd and (bare == tok or tok:find("^[%w_./-]*/" .. word .. "$")) then
          out[#out + 1] = j
        end
        prevtok = tok; tokstart = false
        if j == i then j = i + 1 end
        i = j
      else
        i = i + 1
      end
    end
  end
  return out
end

-- Read shell words from position p of the joined text t. Returns a list of
-- { v = unquoted value, q = was-quoted, raw = source text }.
local function shell_words(t, p)
  local words, i, L = {}, p, #t
  while i <= L do
    while i <= L and (t:sub(i, i):find("[ \t]") or t:sub(i, i + 1) == "\\\n") do
      i = i + (t:sub(i, i) == "\\" and 2 or 1)
    end
    if i > L then break end
    local c = t:sub(i, i)
    if c:find("[|;&)\n<>`]") or c == "#" then break end
    if c:find("%d") and t:sub(i):find("^%d+[<>]") then break end
    local v, quoted, start = {}, false, i
    while i <= L do
      c = t:sub(i, i)
      if c == "'" then
        local e = t:find("'", i + 1, true); if not e then return words, true end
        v[#v + 1] = t:sub(i + 1, e - 1); quoted = true; i = e + 1
      elseif c == '"' then
        quoted = true; i = i + 1
        while true do
          if i > L then return words, true end
          local d = t:sub(i, i)
          if d == '"' then i = i + 1; break
          elseif d == "\\" and t:sub(i + 1, i + 1):find('[\\"$`\n]') then
            if t:sub(i + 1, i + 1) ~= "\n" then v[#v + 1] = t:sub(i + 1, i + 1) end; i = i + 2
          elseif d == "$" and t:sub(i + 1, i + 1) == "{" then
            local e = t:find("}", i, true) or L; v[#v + 1] = "1"; i = e + 1
          elseif d == "$" and t:sub(i + 1, i + 1) == "(" then
            local depth, k = 0, i + 1
            repeat local e = t:sub(k, k); if e == "(" then depth = depth + 1 elseif e == ")" then depth = depth - 1 end; k = k + 1 until depth == 0 or k > L
            v[#v + 1] = "1"; i = k
          elseif d == "$" and t:sub(i + 1, i + 1):find("[%w_@#?*!-]") then
            local e = t:sub(i + 1):match("^[%a_][%w_]*") or t:sub(i + 1, i + 1)
            v[#v + 1] = "1"; i = i + 1 + #e
          else v[#v + 1] = d; i = i + 1 end
        end
      elseif c == "\\" then v[#v + 1] = t:sub(i + 1, i + 1); i = i + 2
      elseif c == "$" and t:sub(i + 1, i + 1) == "{" then
        local e = t:find("}", i, true) or L; v[#v + 1] = "1"; i = e + 1
      elseif c == "$" and t:sub(i + 1, i + 1) == "(" then
        local depth, k = 0, i + 1
        repeat local e = t:sub(k, k); if e == "(" then depth = depth + 1 elseif e == ")" then depth = depth - 1 end; k = k + 1 until depth == 0 or k > L
        v[#v + 1] = "1"; i = k
      elseif c:find("[ \t|;&()\n<>`]") then break
      else v[#v + 1] = c; i = i + 1 end
    end
    words[#words + 1] = { v = table.concat(v), q = quoted, raw = t:sub(start, i - 1) }
  end
  return words, false
end

-- The words of each invocation of `word` on raw line n (joining up to 30
-- following lines while a quote is left open).
local function invocations(raw, n, word)
  local out = {}
  for _, p in ipairs(command_sites(raw[n], word)) do
    local t, last = raw[n], n
    local words, open = shell_words(t, p)
    while open and last < math.min(n + 30, #raw) do
      last = last + 1; t = t .. "\n" .. raw[last]
      words, open = shell_words(t, p)
    end
    if not open then out[#out + 1] = words end
  end
  return out
end

-- Split sed's argv into { scripts = {...}, inplace = nil | suffix }.
local function sed_argv(words)
  local scripts, inplace, inplace_empty_next, k, explicit = {}, nil, false, 1, false
  local operands = {}
  while k <= #words do
    local w = words[k].v
    if w == "--" then
      for j = k + 1, #words do operands[#operands + 1] = words[j].v end; break
    elseif w:find("^%-%-in%-place") then inplace = w:match("^%-%-in%-place=(.*)$") or ""
    elseif w:find("^%-%-expression=") then scripts[#scripts + 1] = w:match("=(.*)$"); explicit = true
    elseif w == "--expression" then scripts[#scripts + 1] = words[k + 1] and words[k + 1].v or ""; explicit = true; k = k + 1
    elseif w:find("^%-%-") then
    elseif w:find("^%-.") and not words[k].q then
      local j = 2
      while j <= #w do
        local ch = w:sub(j, j)
        if ch == "i" then
          inplace = w:sub(j + 1)
          if inplace == "" and words[k + 1] and words[k + 1].v == "" and words[k + 1].q then inplace_empty_next = true end
          break
        elseif ch == "e" then
          local rest = w:sub(j + 1)
          if rest ~= "" then scripts[#scripts + 1] = rest else scripts[#scripts + 1] = words[k + 1] and words[k + 1].v or ""; k = k + 1 end
          explicit = true; break
        elseif ch == "f" then
          if w:sub(j + 1) == "" then k = k + 1 end
          explicit = true; break
        end
        j = j + 1
      end
    else
      operands[#operands + 1] = w
    end
    k = k + 1
  end
  if not explicit and operands[1] then scripts[#scripts + 1] = operands[1] end
  return scripts, inplace, inplace_empty_next
end

-- Does a sed script hold a '}' (or nested '}') that is not preceded by ';' or
-- a newline? BSD-fatal. Returns the offending fragment or nil.
local function sed_brace_defect(s)
  local i, L, depth, term = 1, #s, 0, true
  local function ch(k) return s:sub(k, k) end
  local function read_delimited(delim)   -- i points just past the opening delimiter
    while i <= L do
      local c = ch(i)
      if c == "\\" then i = i + 2
      elseif c == delim then i = i + 1; return true
      elseif c == "\n" and delim ~= "\n" then i = i + 1
      else i = i + 1 end
    end
    return false
  end
  local function address()
    local c = ch(i)
    if c:find("%d") then
      while ch(i):find("[%d~]") do i = i + 1 end
    elseif c == "$" then i = i + 1
    elseif c == "+" or c == "~" then i = i + 1; while ch(i):find("%d") do i = i + 1 end
    elseif c == "/" then i = i + 1; read_delimited("/"); while ch(i):find("[IM]") do i = i + 1 end
    elseif c == "\\" and i < L then local d = ch(i + 1); i = i + 2; read_delimited(d); while ch(i):find("[IM]") do i = i + 1 end
    else return false end
    return true
  end
  while i <= L do
    local c = ch(i)
    if c == " " or c == "\t" then i = i + 1
    elseif c == ";" or c == "\n" then term = true; i = i + 1
    elseif c == "}" then
      if not term then return s:sub(math.max(1, i - 12), i) end
      depth = depth - 1; term = false; i = i + 1
    else
      if address() then
        while ch(i) == " " do i = i + 1 end
        if ch(i) == "," then i = i + 1; while ch(i) == " " do i = i + 1 end; address() end
      end
      while ch(i) == " " or ch(i) == "!" do i = i + 1 end
      c = ch(i)
      if c == "" then break end
      if c == "{" then depth = depth + 1; term = true; i = i + 1
      elseif c == "}" then -- an address before '}' is malformed anyway; judge it as above
      elseif c == "#" then local e = s:find("\n", i, true); i = e or (L + 1)
      elseif c == "s" or c == "y" then
        local d = ch(i + 1); i = i + 2
        read_delimited(d); read_delimited(d)
        if c == "s" then
          while ch(i):find("[gpiIeEmM%d]") and ch(i) ~= "" do i = i + 1 end
          if ch(i) == "w" then local e = s:find("\n", i, true); i = e or (L + 1) end
        end
        term = false
      elseif c == "a" or c == "i" or c == "c" then
        -- text runs to the end of the line (and on, while lines end in '\')
        local e = i
        repeat e = s:find("\n", e + 1, true) until not e or s:sub(e - 1, e - 1) ~= "\\"
        i = e or (L + 1); term = false
      elseif c == "b" or c == "t" or c == "T" or c == ":" then
        local e = i + 1
        while e <= L and not ch(e):find("[;\n]") do e = e + 1 end
        local label = s:sub(i + 1, e - 1)
        if label:find("}", 1, true) then return s:sub(i, e - 1) end
        i = e; term = false
      elseif c == "r" or c == "R" or c == "w" or c == "W" then
        local e = s:find("\n", i, true); i = e or (L + 1); term = false
      else
        i = i + 1; term = false
        if c == "q" or c == "Q" or c == "l" or c == "L" then while ch(i):find("[%d ]") and ch(i) ~= "" do i = i + 1 end end
      end
    end
  end
  return nil
end

local function marker_ok(line, name) return text.is_match(line, "#[[:space:]]*" .. name .. [=[: ok \(.*[^[:space:]].*\)]=]) end

-- stat invocations on a raw line: which carry GNU -c (or --format/--printf),
-- and which a BSD -f format (a '-f' NOT followed by '-c', which is GNU's
-- file-system mode).
local function stat_kinds(raw, n)
  local gnu, bsd = false, false
  for _, words in ipairs(invocations(raw, n, "stat")) do
    for k, w in ipairs(words) do
      local v = w.v
      if v:find("^%-%-format") or v:find("^%-%-printf") then gnu = true
      elseif v:find("^%-[A-Za-z]") and not w.q then
        local f = v:find("f", 2, true)
        local cpos = v:find("c", 2, true)
        if cpos and (not f or f > cpos) then gnu = true end
        if f then
          local nxt = (v:sub(f + 1) ~= "" and v:sub(f + 1)) or (words[k + 1] and words[k + 1].v) or ""
          if nxt:find("^%-c") or nxt:find("^%-%-format") then gnu = true else bsd = true end
        end
      end
    end
  end
  return gnu, bsd
end

-- Lines of the function enclosing line n (nil when at top level).
local function enclosing_function(raw, n)
  for h = n, 1, -1 do
    local ind = raw[h]:match("^(%s*)[%a_][%w_:%-]*%s*%(%)%s*{?%s*$") or raw[h]:match("^(%s*)function%s+[%a_][%w_:%-]*")
    if ind then
      for e = h + 1, #raw do
        if raw[e]:match("^" .. ind .. "}") then
          if e >= n then return h, e end
          break
        end
      end
      return nil
    end
  end
  return nil
end

local function x8js_sites(f, raw)
  local fkey = f:gsub("^%./", "")
  local brace, sedi, statc = {}, {}, {}
  local function allowed(rule, line)
    for k in pairs(SITE_ALLOWLIST) do
      local kf, kr, lit = k:match("^([^|]*)|([^|]*)|(.*)$")
      if kf == fkey and kr == rule and has(line, lit) then SITE_ALLOWLIST_HIT[k] = true; return true end
    end
    return false
  end
  local stat_cache = {}
  local function kinds(n) if not stat_cache[n] then stat_cache[n] = { stat_kinds(raw, n) } end; return stat_cache[n][1], stat_cache[n][2] end
  for n, line in ipairs(raw) do
    if line:find("^%s*#") then goto next_line end
    if line:find("%f[%w_]sed%f[^%w_]") then
      for _, words in ipairs(invocations(raw, n, "sed")) do
        local scripts, inplace, empty_next = sed_argv(words)
        if inplace ~= nil and (inplace == "" or empty_next) and not marker_ok(line, "sed-i") and not allowed("sed-i", line) then
          sedi[#sedi + 1] = { n = n, s = n .. ":" .. line }
        end
        -- several -e scripts are ONE script joined by newlines, as sed reads them
        local sc = table.concat(scripts, "\n")
        local bad = sc:find("}", 1, true) and sed_brace_defect(sc)
        if bad and not marker_ok(line, "sed-brace") and not allowed("sed-brace", line) then
          brace[#brace + 1] = { n = n, s = n .. ":" .. line .. "   <-- '" .. bad .. "'" }
        end
      end
    end
    if line:find("%f[%w_]stat%f[^%w_]") and (line:find("stat%s.*%-%a*c") or line:find("stat%s.*%-%-format") or line:find("stat%s.*%-%-printf")) then
      local gnu = kinds(n)
      if gnu and not marker_ok(line, "stat-c") and not allowed("stat-c", line) then
        local lo, hi = math.max(1, n - 3), math.min(#raw, n + 3)
        local fh, fe = enclosing_function(raw, n)
        local found = false
        for j = lo, hi do if has(raw[j], "stat") then local _, b = kinds(j); if b then found = true; break end end end
        if not found and fh then
          for j = fh, fe do if has(raw[j], "stat") then local _, b = kinds(j); if b then found = true; break end end end
        end
        if not found then statc[#statc + 1] = { n = n, s = n .. ":" .. line } end
      end
    end
    ::next_line::
  end
  return brace, sedi, statc
end

-- ── per file ───────────────────────────────────────────────────────────────
local unguarded, allowlisted_hits = 0, 0
for _, f in ipairs(files) do
    local full = read(f)
    local src = full
    local base = f:match("([^/]+)$")
    local file_bad = false
    if src and not ALLOWLIST[base] and not text.is_match(src, TRIGGER) then src = nil end
    if src and base ~= "check-bash-dialect.sh" and not base:find("^test%-check%-bash%-dialect") then
        local raw = lines_of(src)
        local code = code_lines(raw)
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
    end
    -- 1553-x8js: the sed/stat rules read EVERY file, whatever the TRIGGER said.
    if full and base ~= "check-bash-dialect.sh" and not base:find("^test%-check%-bash%-dialect")
        and (full:find("%f[%w_]sed%f[^%w_]") or full:find("%f[%w_]stat%f[^%w_]")) then
        local xb, xi, xs = x8js_sites(f, lines_of(full))
        if #xb > 0 then err(sub(M.sedbrace, { f = f })); head3(xb); file_bad = true end
        if #xi > 0 then err(sub(M.sedi, { f = f })); head3(xi); file_bad = true end
        if #xs > 0 then err(sub(M.statc, { f = f })); head3(xs); file_bad = true end
    end
    if file_bad then unguarded = unguarded + 1 end
end

if scan_dir_env == nil or scan_dir_env == "" then
    for k in pairs(SITE_ALLOWLIST) do
        if not SITE_ALLOWLIST_HIT[k] then err(sub(M.site_note, { key = k })) end
    end
end
if unguarded > 0 then
    err(sub(M.summary, { unguarded = tostring(unguarded) }))
    verdict.emit("blocked:bash4-unguarded:" .. unguarded, 1)
end
if allowlisted_hits > 0 then err(sub(M.allow_left, { allowlisted_hits = tostring(allowlisted_hits) })) end
verdict.ok("bash-dialect-clean")

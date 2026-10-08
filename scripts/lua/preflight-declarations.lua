-- @trace order:1553-6b3a, order:1545-qdb5, order:1496-w25b, order:1518-8p5k, order:1499-m9fj
--
-- @class cacheable
--
-- preflight-declarations.lua — the preflight door's header reader, ONE process
-- per door run instead of six host-sed calls per guard.
--
-- A guard may declare, in its first 40 lines:
--   # preflight: gate-only — <reason>            (1496-w25b)
--   # preflight: gate-only-decider — <reason>    (1518-8p5k)
--   # preflight: serial — <reason>               (1499-m9fj)
-- The door read them with the HOST's sed, and BSD sed rejected the old
-- `1,40{...p}` groups, printed nothing, and so every darwin preflight read no
-- declaration at all (1545-qdb5). This reader runs on the binary's Lua on every
-- host, so there is no sed dialect left to disagree.
--
-- CONTRACT. Arguments are repo-relative guard paths (the door's roster, paths
-- only). For each path, in argument order, one line per declaration found:
--
--   <path>\t<kind>\t<reason>
--
-- kind is gate-only, gate-only-decider or serial; a path with none prints one
-- `<path>\tnone\t` line, and an unreadable one `<path>\tabsent\t` (the door
-- checks existence itself first). Then the verdict `ok:preflight-declarations:<n>`.
--
-- SEMANTICS, exactly the sed's (build.sh _pf_predecide, the fallback path):
--   * only the first 40 lines are examined; lines are split on "\n" only;
--   * each kind is the FIRST line in those 40 that starts with its token;
--   * a `# preflight: gate-only-decider` line is NOT a gate-only declaration,
--     although `gate-only` is its prefix;
--   * the reason is the rest of the line after the token and any whitespace,
--     with ONE leading `—` or `-` and the whitespace after it removed;
--   * an empty reason is still reported (the door prints *-without-a-reason).

local HEAD_LINES = 40
local DASH = "\226\128\148" -- U+2014 EM DASH, UTF-8

local function first_lines(s, n)
  local out, pos, len = {}, 1, #s
  while #out < n and pos <= len do
    local nl = s:find("\n", pos, true)
    if nl then
      out[#out + 1] = s:sub(pos, nl - 1)
      pos = nl + 1
    else
      out[#out + 1] = s:sub(pos)
      pos = len + 1
    end
  end
  return out
end

local function starts(line, token)
  return line:sub(1, #token) == token
end

-- `s/^[—-][[:space:]]*//`
local function strip_dash(r)
  if r:sub(1, #DASH) == DASH then
    r = r:sub(#DASH + 1)
  elseif r:sub(1, 1) == "-" then
    r = r:sub(2)
  else
    return r
  end
  return (r:gsub("^%s*", ""))
end

-- `s/^<token>[[:space:]]*//` then strip_dash
local function reason_of(line, token)
  return strip_dash((line:sub(#token + 1):gsub("^%s*", "")))
end

local KINDS = {
  { kind = "gate-only", token = "# preflight: gate-only", exclude = "# preflight: gate-only-decider" },
  { kind = "gate-only-decider", token = "# preflight: gate-only-decider" },
  { kind = "serial", token = "# preflight: serial" },
}

local function declarations(src)
  local lines = first_lines(src, HEAD_LINES)
  local found = {}
  for _, k in ipairs(KINDS) do
    for _, l in ipairs(lines) do
      if starts(l, k.token) and not (k.exclude and starts(l, k.exclude)) then
        found[#found + 1] = { k.kind, reason_of(l, k.token) }
        break
      end
    end
  end
  return found
end

local n = 0
for i = 1, #arg do
  local p = arg[i]
  if p ~= "" then
    n = n + 1
    local ok, src = pcall(fs.read, p)
    if not ok then
      out.line(p .. "\tabsent\t")
    else
      local found = declarations(src)
      if #found == 0 then
        out.line(p .. "\tnone\t")
      end
      for _, d in ipairs(found) do
        out.line(p .. "\t" .. d[1] .. "\t" .. d[2])
      end
    end
  end
end
verdict.ok("preflight-declarations", n)

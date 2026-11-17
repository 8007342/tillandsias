-- @trace spec:project-bootstrap-readme, order:2031-z4rm
--
-- check-readme-discipline.lua [project-dir] — validate a project README's
-- FOR HUMANS / FOR ROBOTS structure. Ported from check-readme-discipline.sh
-- (paid as 2031-z4rm's shell-to-lua carried obligation).
--
-- Same checks, same ERROR:/WARN: lines, same exit codes as the .sh:
--   1 README.md exists (else ERROR and exit 1 at once)
--   2 '# FOR HUMANS' header      3 '# FOR ROBOTS' header
--   4 the auto-regeneration warning
--   5 a 'Generated:' timestamp that parses as ISO8601; WARN (not an error)
--     when it is more than 7 days old. An unparseable date counts as epoch 0,
--     exactly as the .sh's `date -d ... || echo 0` did, so it warns.
--   6 the H2 sections Tech Stack, Build/Runtime Dependencies, Security,
--     Architecture, Privacy, Recent Changes (prefix match, as `grep "^## X"`)
--   7 a requires_cheatsheets: block with 'path:' and 'tier:' entries
-- THE ONE DIFFERENCE: the runner requires a verdict line, so the summary line
-- is ok:readme-discipline, ok:readme-discipline:warnings=<n>, or
-- violation:readme-discipline:errors=<e>:warnings=<w>, where the .sh printed
-- "OK: README discipline validated", "OK: README validated (<n> warning(s))"
-- or "FAILED: <e> error(s), <w> warning(s)". No caller parses that line.
--
-- Usage: tillandsias-plan script run scripts/lua/check-readme-discipline.lua [-- <project-dir>]

local dir = (arg or {})[1] or "."
local readme = dir .. "/README.md"

local body = fs.exists(readme) and fs.read(readme) or nil
if not body then
    out.line("ERROR: README.md not found at " .. readme)
    verdict.emit("violation:readme-discipline:errors=1:warnings=0", 1)
end
local lines = text.lines(body)

local errors, warnings = 0, 0
local function err(m) out.line("ERROR: " .. m); errors = errors + 1 end

local function has_line(pred)
    for _, l in ipairs(lines) do if pred(l) then return true end end
    return false
end
local function exact(s) return function(l) return l == s end end
local function prefix(s) return function(l) return l:sub(1, #s) == s end end
local function contains(s) return function(l) return l:find(s, 1, true) ~= nil end end

if not has_line(exact("# FOR HUMANS")) then err("Missing '# FOR HUMANS' header") end
if not has_line(exact("# FOR ROBOTS")) then err("Missing '# FOR ROBOTS' header") end
if not has_line(contains("This file is auto-regenerated on every git push")) then
    err("Missing auto-regeneration warning")
end

-- Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's
-- days_from_civil), so no date(1) is needed and GNU/BSD cannot disagree.
local function days_from_civil(y, m, d)
    y = (m <= 2) and (y - 1) or y
    local era = (y >= 0 and y or y - 399) // 400
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = (153 * mp + 2) // 5 + d - 1
    local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468
end
-- What `date -d` would have read: YYYY-MM-DDTHH:MM[:SS] with an optional Z.
local function epoch_of(ts)
    local y, mo, d, h, mi, s = ts:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):?(%d*)Z?$")
    if not y then return 0 end
    return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + (tonumber(s) or 0)
end

local gen
for _, l in ipairs(lines) do
    if l:find("Generated:", 1, true) then gen = l; break end
end
if gen then
    -- awk -F'Generated: ' '{print $2}' | awk '{print $1}'
    local after = gen:match("Generated: (.*)$") or ""
    local ts = after:match("^%s*(%S+)") or ""
    if not ts:match("^%d%d%d%d%-%d%d%-%d%dT") then
        err("Timestamp does not parse as ISO8601: " .. ts)
    else
        local days_old = (time.now_ms() // 1000 - epoch_of(ts)) // 86400
        if days_old > 7 then
            out.line("WARN: README timestamp older than 7 days (age: " .. days_old .. " days)")
            warnings = warnings + 1
        end
    end
else
    err("No timestamp line found")
end

for _, section in ipairs({ "Tech Stack", "Build/Runtime Dependencies", "Security", "Architecture", "Privacy", "Recent Changes" }) do
    if not has_line(prefix("## " .. section)) then err("Missing '## " .. section .. "' section") end
end

if has_line(prefix("requires_cheatsheets:")) then
    if not has_line(contains("path:")) then err("requires_cheatsheets block missing 'path' entries") end
    if not has_line(contains("tier:")) then err("requires_cheatsheets block missing 'tier' entries") end
else
    err("Missing 'requires_cheatsheets:' YAML block")
end

if errors == 0 and warnings == 0 then verdict.emit("ok:readme-discipline", 0) end
if errors == 0 then verdict.emit("ok:readme-discipline:warnings=" .. warnings, 0) end
verdict.emit("violation:readme-discipline:errors=" .. errors .. ":warnings=" .. warnings, 1)

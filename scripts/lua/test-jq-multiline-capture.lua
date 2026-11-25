-- @env PATH HOME
-- @trace order:1049-s35z, order:823-u5zf, order:2332-rxkr
--
-- test-jq-multiline-capture.lua — a multi-line capture of jq output strips CR, and
-- check-jq-multiline-capture-strips-cr.lua can fail. Ported from the .sh of the same name
-- (2332-rxkr). Arms 1-3 measure this host's jq; where it writes CRLF the unstripped first row is
-- one longer, and the printed regime says which host this is.
--
--   1 a single-value capture has no CR     2 tr -d '\r' makes the first of two rows clean
--   3 head -1 reduces before the capture   4 an unstripped site is caught
--   5 a stripped one is cleared            6 a reducing filter is not flagged
--   7 the workspace is clean
--
-- Usage: tillandsias-plan script run scripts/lua/test-jq-multiline-capture.lua
-- Verdict: ok:jq-multiline-capture:<n> arms | violation:... | skip:...:no-jq

local fixture = require "common.fixture"
local T = fixture.new("jq-multiline-capture")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local JQ = "j" .. "q"
local m = T:run{ SH, "-s", "--", JQ, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000, stdin = [==[
command -v "$1" >/dev/null 2>&1 || exit 9
J='{"a":["one","two"]}'
one="$(printf '%s' "$J" | "$1" -r '.a[0]')"
raw=""; while IFS= read -r l; do raw="$l"; break; done < <(printf '%s' "$J" | "$1" -r '.a[]')
tr=""; while IFS= read -r l; do tr="$l"; break; done < <(printf '%s' "$J" | "$1" -r '.a[]' | tr -d '\r')
head="$(printf '%s' "$J" | "$1" -r '.a[]' | head -1)"
echo "one=${#one} raw=${#raw} tr=${#tr} head=${#head}"
]==] }
if m.code == 9 then T:skip("no-jq") end
local o = m.stdout or ""
local function len(k) return o:match(k .. "=(%d+)") end
out.line("regime: " .. (len("raw") == "4" and "crlf" or "lf"))
T:arm("1 a single-value capture has no CR", len("one") == "3", o)
T:arm("2 tr -d makes the first of two rows clean", len("tr") == "3", o)
T:arm("3 head -1 reduces before the capture", len("head") == "3", o)

local function check(body)
    local target = "scripts"
    if body then
        local d = T:scratch()
        fs.mkdir(d.rel .. "/scripts"); fs.write(d.rel .. "/scripts/offender.sh", body)
        target = d.rel .. "/scripts"
    end
    local r = proc.run{ argv = { PLAN, "script", "run", "scripts/lua/check-jq-multiline-capture-strips-cr.lua", "--", target }, cwd = ROOT,
        env_unset = { "TILLANDSIAS_*" }, env = { PATH = env.get("PATH"), HOME = env.get("HOME") }, timeout_ms = 120000 }
    local s = r.stdout or ""
    return r.code, s, "rc=" .. tostring(r.code) .. " " .. s:sub(1, 300) .. (r.stderr or ""):sub(1, 200)
end
local function site(filter, tail) return 'names="$(cat data.json | ' .. JQ .. " -r '" .. filter .. "'" .. (tail or "") .. ')"\necho "$names"\n' end
local rc, s, why = check(site(".models[].name"))
T:arm("4a an unstripped multi-line capture is caught", rc == 1 and text.contains(s, "violation:jq-multiline-capture-unstripped:"), why)
rc, s, why = check(site(".models[].name", " | sort"))
T:arm("4b a later pipe that neither strips nor reduces is caught", rc == 1 and text.contains(s, "violation:jq-multiline-capture-unstripped:"), why)
local function clear(name, body)
    rc, s, why = check(body)
    T:arm(name, rc == 0 and text.contains("\n" .. s, "\nok:jq-multiline-capture-strips-cr:"), why)
end
clear("5 a stripped one is cleared", site(".models[].name", " | tr -d '\\r'"))
clear("6 a reducing filter is not flagged", site("[.models[].size] | max"))
clear("7 the workspace is clean", nil)
T:finish()

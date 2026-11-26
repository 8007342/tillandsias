-- @env PATH HOME
-- @trace order:2400-az2b
--
-- test-litmus-stdlib-holds-large-haystack.lua — litmus-stdlib's mf_holds* primitives find a
-- match that IS present however large the haystack, under `set -o pipefail`, and so the mf_lacks*
-- built on them do not pass when the text is there.
--
-- MEASURED 2026-11-26: the primitives were `printf "$var" | grep -q PATTERN`. grep -q exits on the
-- first match and printf then writes into a closed pipe; under pipefail the pipeline's status is
-- printf's failure, so a 5 MB haystack whose FIRST line is the needle read not-found 40 times in
-- 40. A here-string has no pipe to race.
--
--   1 each of the six holds variants finds a needle on the first line of a large haystack
--   2 each mf_lacks variant is false there (the negative assertion does not pass vacuously)
--   3 CONTROL on a small haystack every variant agrees with the large one
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-stdlib-holds-large-haystack.lua
-- Verdict: ok:litmus-stdlib-holds-large-haystack:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("litmus-stdlib-holds-large-haystack")
local BASH = fixture.posix_shell()
local ROOT = fixture.repo_root()
local LIB = ROOT .. "/scripts/litmus-stdlib.sh"
-- For each variant: the pattern it must find on the first line, then 400000 filler lines (~4 MB).
local DRIVE = [[set -o pipefail
. "$1" || exit 9
big="needle-2400 Needle+X"
filler="$(printf 'filler line with nothing to find in it %s\n' $(seq 1 1000))"
for _ in $(seq 1 100); do big="$big"$'\n'"$filler"; done
small="needle-2400 Needle+X"
for hay in big small; do
  r=""
  mf_holds "$hay" 'needle-2400' && r="${r}1" || r="${r}0"
  mf_holds_ere "$hay" 'needle-[0-9]+' && r="${r}1" || r="${r}0"
  mf_holds_literal "$hay" 'Needle+X' && r="${r}1" || r="${r}0"
  mf_holds_line "$hay" 'needle-2400 Needle+X' && r="${r}1" || r="${r}0"
  mf_holds_i "$hay" 'NEEDLE-2400' && r="${r}1" || r="${r}0"
  mf_holds_i_ere "$hay" 'NEEDLE-[0-9]+' && r="${r}1" || r="${r}0"
  mf_lacks "$hay" 'needle-2400' && r="${r}1" || r="${r}0"
  mf_lacks_literal "$hay" 'Needle+X' && r="${r}1" || r="${r}0"
  printf '%s=%s\n' "$hay" "$r"
done
]]
local runs, bigs = 5, {}
local small
for i = 1, runs do
    local r = T:run{ BASH, "-s", "--", LIB, stdin = DRIVE, timeout_ms = 120000 }
    if r.code == 9 then T:refuse("stdlib-did-not-source", LIB) end
    bigs[i] = (r.stdout or ""):match("big=(%d+)") or ("rc=" .. tostring(r.code) .. " " .. (r.stderr or ""):sub(1, 200))
    small = small or (r.stdout or ""):match("small=(%d+)")
end
-- Six holds then two lacks: 11111100 is the only right answer.
local WANT = "11111100"
local bad = {}
for i, b in ipairs(bigs) do if b:sub(1, 6) ~= "111111" then bad[#bad + 1] = i .. ":" .. b end end
T:arm("1 every holds variant finds a first-line needle in a ~4 MB haystack, " .. runs .. " runs", #bad == 0, table.concat(bad, " "))
bad = {}
for i, b in ipairs(bigs) do if b:sub(7, 8) ~= "00" then bad[#bad + 1] = i .. ":" .. b end end
T:arm("2 mf_lacks and mf_lacks_literal are false when the text is there", #bad == 0, table.concat(bad, " "))
T:arm("3 CONTROL the small haystack gives the one right answer", small == WANT, tostring(small))
T:finish()

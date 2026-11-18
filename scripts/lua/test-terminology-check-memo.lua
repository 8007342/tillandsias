-- @trace order:1054-zvq4, order:2080-zcur
--
-- test-terminology-check-memo.lua — the terminology-check memo hits only on
-- unchanged inputs: the dictionary, every scanned locale file (names AND
-- contents) and the checker itself. Hermetic: a scratch dictionary and locale
-- dir handed over by TILLANDSIAS_TERMINOLOGY_DICT / TILLANDSIAS_LOCALE_DIR.
-- Ported from scripts/test-terminology-check-memo.sh onto common.fixture.
--
-- Usage: tillandsias-plan script run scripts/lua/test-terminology-check-memo.lua
-- Verdict: ok:terminology-check-memo:<n> arms | violation:terminology-check-memo:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("terminology-check-memo")
local W = T:scratch()
local L = W.rel .. "/locales"
fs.mkdir(L)
local DICT1 = '[[term]]\ncanonical = "Podman"\nwrong = ["podman"]\n'
fs.write(L .. "/terminology.toml", DICT1)
fs.write(L .. "/en.toml", 'greeting = "Hello"\n')
fs.write(L .. "/es.toml", 'greeting = "Hola"\n')
local E = { TILLANDSIAS_TERMINOLOGY_DICT = W.abs .. "/locales/terminology.toml",
    TILLANDSIAS_LOCALE_DIR = W.abs .. "/locales", TILLANDSIAS_TERMINOLOGY_MEMO = W.abs .. "/memo" }
local function run(verb)
    local r = T:run{ "bash", "scripts/terminology-check-memo.sh", verb, cwd = fixture.repo_root(), env = E }
    return text.trim(r.stdout or "")
end
local HIT, MISS = "ok:terminology-check-memoized:", "miss:dictionary-locales-or-instrument-changed"

local out = run("check")
T:arm("no memo -> miss:no-memo", out == "miss:no-memo", out)
out = run("record")
T:arm("record writes the memo", text.starts_with(out, "ok:terminology-check-memo-recorded:"), out)
out = run("check")
T:arm("unchanged inputs -> hit", text.starts_with(out, HIT), out)
fs.write(L .. "/terminology.toml", '[[term]]\ncanonical = "Podman"\nwrong = ["podman", "PODMAN"]\n')
out = run("check")
T:arm("a changed dictionary entry -> miss", out == MISS, out)
fs.write(L .. "/terminology.toml", DICT1)
out = run("check")
T:arm("dictionary restored -> hit again (digest is content, not time)", text.starts_with(out, HIT), out)
fs.write(L .. "/en.toml", 'greeting = "Hello there"\n')
out = run("check")
T:arm("a changed scanned source string -> miss", out == MISS, out)
fs.write(L .. "/en.toml", 'greeting = "Hello"\n')
out = run("check")
T:arm("source restored -> hit again", text.starts_with(out, HIT), out)
fs.write(L .. "/fr.toml", 'greeting = "Bonjour"\n')
out = run("check")
T:arm("a NEW locale file -> miss (names are in the key)", out == MISS, out)
T:must{ "rm", "-f", W.abs .. "/locales/fr.toml" }
out = run("check")
T:arm("file removed -> hit again", text.starts_with(out, HIT), out)
local d = run("digest")
T:arm("digest is a sha256", #d == 64 and d:match("^%x+$") ~= nil, d)
T:arm("the digest names the checker as an input (tool: tag present)",
    text.contains(fs.read("scripts/terminology-check-memo.sh") or "", "tool:%s"), "no tool: tag")
T:finish()

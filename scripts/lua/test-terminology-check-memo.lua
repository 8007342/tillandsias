-- @trace order:1054-zvq4, order:2301-eny9
--
-- The terminology-check memo hits only on an unchanged dictionary AND unchanged
-- scanned locales AND unchanged instrument; a byte in any of them is a miss.
-- Lua port of the .sh.
--
-- HERMETIC BY CONSTRUCTION, and it has to be: the checker honours
-- TILLANDSIAS_TERMINOLOGY_DICT and TILLANDSIAS_LOCALE_DIR, so the memo resolves
-- the same two variables. This fixture builds a THROWAWAY locale tree and points
-- both variables at it, rather than mutating locales/ in the working tree: a
-- locale file is a user-visible string source, and a fixture that crashed midway
-- would leave the repository's own dictionary altered.
--
-- The negative controls are the point. A memo that only ever hits is a memo
-- that has stopped checking, and the three inputs fail differently: the
-- dictionary changes what counts as a violation, a scanned file changes what is
-- examined, and the checker changes the verdict for identical input.
--
-- Usage: tillandsias-plan script run scripts/lua/test-terminology-check-memo.lua
-- Verdict: ok:terminology-check-memo:11 arms | violation:terminology-check-memo:<n>

local fixture = require "common.fixture"
local T = fixture.new("terminology-check-memo")
local ROOT = fixture.repo_root()
local MEMO = "scripts/terminology-check-memo.sh"
local W = T:scratch()
local CHANGED = "miss:dictionary-locales-or-instrument-changed"

local function locale(name, body) fs.write(W.rel .. "/locales/" .. name .. ".toml", body) end
local function dictionary(wrong)
    locale("terminology", '[[term]]\ncanonical = "Podman"\nwrong = [' .. wrong .. ']\n')
end
local function run(verb)
    local r = T:run{ fixture.posix_shell(), MEMO, verb, cwd = ROOT, env = {
        TILLANDSIAS_TERMINOLOGY_DICT = W.abs .. "/locales/terminology.toml",
        TILLANDSIAS_LOCALE_DIR = W.abs .. "/locales",
        TILLANDSIAS_TERMINOLOGY_MEMO = W.abs .. "/memo",
    } }
    return text.trim(r.stdout or "")
end
local function hits(name)
    local got = run("check")
    T:arm(name, got:find("ok:terminology-check-memoized:", 1, true) == 1, got)
end
local function misses(name, want)
    local got = run("check")
    T:arm(name, got == want, got)
end

-- A minimal locale tree: a dictionary and two scanned files.
fs.mkdir(W.rel .. "/locales")
dictionary('"podman"')
locale("en", 'greeting = "Hello"\n')
locale("es", 'greeting = "Hola"\n')

misses("no memo -> miss:no-memo", "miss:no-memo")
local recorded = run("record")
T:arm("record writes the memo",
    recorded:find("ok:terminology-check-memo-recorded:", 1, true) == 1, recorded)
hits("unchanged inputs -> hit")

-- 1. The DICTIONARY changes what counts as a violation.
dictionary('"podman", "PODMAN"')
misses("a changed dictionary entry -> miss", CHANGED)
dictionary('"podman"')
hits("dictionary restored -> hit again (digest is content, not time)")

-- 2. A SCANNED SOURCE STRING changes what is examined.
locale("en", 'greeting = "Hello there"\n')
misses("a changed scanned source string -> miss", CHANGED)
locale("en", 'greeting = "Hello"\n')
hits("source restored -> hit again")

-- 3. A locale file APPEARING is a miss even though no existing byte changed.
--    This is why the digest carries file NAMES and not only their contents.
locale("fr", 'greeting = "Bonjour"\n')
misses("a NEW locale file -> miss (names are in the key)", CHANGED)
T:must{ fixture.posix_shell(), "-s", "--", W.abs .. "/locales/fr.toml", stdin = 'rm -f -- "$1"\n' }
hits("file removed -> hit again")

-- 4. The digest itself is a sha256.
local digest = run("digest")
T:arm("digest is a sha256", #digest == 64, digest)

-- 5. THE INSTRUMENT: a changed checker must miss on byte-identical input.
--    Verified against the real script path, since that is what the digest names.
T:arm("the digest names the checker as an input (tool: tag present)",
    fs.read(MEMO):find("tool:%s", 1, true) ~= nil, "no tool: tag in " .. MEMO)

T:finish()

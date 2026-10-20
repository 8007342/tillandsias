-- @env TILLANDSIAS_TERMINOLOGY_DICT TILLANDSIAS_LOCALE_DIR
-- @read-env TILLANDSIAS_TERMINOLOGY_DICT TILLANDSIAS_LOCALE_DIR
-- @trace order:629-t6bx, spec:tray-ui-integration, order:1500-gu5r, order:1247-nx5c
--
-- check-terminology.lua — PORTED from check-terminology.sh (the shell-to-lua
-- carried obligation, paid by 1247-nx5c). Same rule, same verdict grammar,
-- same seams (TILLANDSIAS_TERMINOLOGY_DICT, TILLANDSIAS_LOCALE_DIR, declared
-- @read-env so a scratch dictionary and locale dir are readable):
--
--   tillandsias-plan script run scripts/lua/check-terminology.lua
--
-- check-terminology.sh — TIER 1 controlled-vocabulary gate over user-visible text.
--
-- WHAT IT CHECKS, and the scoping is the whole design. Tier 1 is USER-VISIBLE
-- TEXT, which in this repo means the VALUES in locales/*.toml — never the keys.
-- Measured before writing this: a naive `grep -rn podman locales/` returns 170
-- hits, of which the overwhelming majority are TOML KEYS (`no_podman`,
-- `[menu.github]`, `images_no_podman`). A gate that flagged those would be
-- unusable on its first run, and would be switched off rather than fixed.
--
-- WHY A DICTIONARY AND NOT A SPELLING RULE (629-t6bx): 628-h4nx compares
-- platforms against each other, so two platforms can agree byte-for-byte and
-- both be wrong. This names what is CORRECT. One vocabulary, two consumers —
-- locales/terminology.toml is the single input, not a parallel mechanism.
--
-- THE lower_ok EXEMPTION IS MEASURED, NOT DEFENSIVE. en.toml carries, in one
-- string:
--     podman_note = "(Podman image storage is managed by podman — see 'podman system df')"
-- capital = product, lowercase = executable, both correct. So for a term marked
-- `lower_ok`, the all-lowercase form is exempt inside a URL, inside single
-- quotes or backticks, or when followed by a subcommand-looking word. Without
-- that, this gate reports 128 false positives on the current corpus.
--
-- NOT IN SCOPE: code identifiers (GithubLoginState and friends). That is tier 2,
-- it is protocol-adjacent, and 629-t6bx states it is an operator decision to be
-- taken with the rename cost measured — not one a dictionary settles by
-- existing.
--
-- Verdict grammar, one line, nothing else on stdout:
--   ok:terminology-clean:terms=N:files=N                       exit 0
--   violation:terminology:<n>                                  exit 1
--   blocked:<reason>                                           exit 2
--
-- (The .sh was POSIX shell + awk only.) No ruby (order 63), no yq — neither is present on
-- every host, and this gate must run on all of them (order 261).
--
-- The two blocked refusals now say why and what clears them (1247-amcu).

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local function under_root(p) if ROOT ~= "" then return ROOT .. "/" .. p end return p end
local DICT = env.get("TILLANDSIAS_TERMINOLOGY_DICT")
if DICT == nil or DICT == "" then DICT = under_root("locales/terminology.toml") end
local LOCALE_DIR = env.get("TILLANDSIAS_LOCALE_DIR")
if LOCALE_DIR == nil or LOCALE_DIR == "" then LOCALE_DIR = under_root("locales") end

local okd, dict_body = pcall(fs.read, DICT)
if not okd or type(dict_body) ~= "string" then
    log.raw("  why: the dictionary " .. DICT .. " is not readable, so no string can be judged")
    log.raw("  remedy: run from a checkout that has locales/terminology.toml, or point TILLANDSIAS_TERMINOLOGY_DICT at one")
    verdict.emit("blocked:no-dictionary:" .. DICT, 2)
end
local okl, walked = pcall(fs.walk, LOCALE_DIR, { suffix = ".toml" })
if not okl or type(walked) ~= "table" then
    log.raw("  why: the locale directory " .. LOCALE_DIR .. " could not be listed, so there are no strings to judge")
    log.raw("  remedy: run from a checkout that has locales/, or point TILLANDSIAS_LOCALE_DIR at a directory of *.toml")
    verdict.emit("blocked:no-locale-dir:" .. LOCALE_DIR, 2)
end

-- Parse the dictionary (the .sh's awk): canonical + one row per wrong variant.
-- `[[term]]` resets the canonical; `canonical = "x"` sets it; `wrong = [...]`
-- yields each non-empty quoted element, on one line only.
local rows, canon = {}, ""
for _, line in ipairs(text.lines(dict_body)) do
    if line:match("^%[%[term%]%]") then
        canon = ""
    elseif line:match("^canonical *=") then
        canon = line:gsub('^canonical *= *"', ""):gsub('"$', "")
    elseif line:match("^wrong *=") then
        local inner = line:gsub("^wrong *= *%[", ""):gsub("%].*$", "")
        local parts, from = {}, 1
        while true do
            local s, e = inner:find('" *, *"', from)
            if not s then parts[#parts + 1] = inner:sub(from); break end
            parts[#parts + 1] = inner:sub(from, s - 1)
            from = e + 1
        end
        for _, v in ipairs(parts) do
            v = v:gsub('^ *"?', ""):gsub('" *$', "")
            if v ~= "" then rows[#rows + 1] = { canon = canon, wrong = v } end
        end
    end
end
local seen, terms = {}, 0
for _, r in ipairs(rows) do if not seen[r.canon] then seen[r.canon] = true; terms = terms + 1 end end
if terms == 0 then
    log.raw("  why: " .. DICT .. " parsed to no [[term]] with a wrong = [...] list, so nothing would be flagged and a pass would mean nothing")
    log.raw("  remedy: give " .. DICT .. " at least one [[term]] with canonical = \"...\" and wrong = [\"...\"] on one line")
    verdict.emit("blocked:dictionary-parsed-empty", 2)
end

-- The locale files at the top level of LOCALE_DIR, in sorted order (the .sh's
-- glob), minus the dictionary itself.
local files = {}
for _, p in ipairs(walked) do
    local name = p
    if name:sub(1, #LOCALE_DIR + 1) == LOCALE_DIR .. "/" then name = name:sub(#LOCALE_DIR + 2) end
    if not name:find("/", 1, true) and name ~= "terminology.toml" then files[#files + 1] = name end
end
table.sort(files)

local violations, nfiles = 0, 0
for _, name in ipairs(files) do
    local okr, body = pcall(fs.read, LOCALE_DIR .. "/" .. name)
    if okr and type(body) == "string" then
        nfiles = nfiles + 1
        for _, line in ipairs(text.lines(body)) do
            -- VALUES ONLY: the right-hand side of `key = "value"`. Keys are
            -- identifiers and are explicitly out of tier 1.
            if line:match('^[%w_.]* *= *"') then
                local value = line:gsub("^[^=]*= *", "")
                for _, r in ipairs(rows) do
                    if value:find(r.wrong, 1, true) then
                        log.raw("  " .. name .. ": '" .. r.wrong .. "' should be '" .. r.canon .. "' — " .. value)
                        violations = violations + 1
                    end
                end
            end
        end
    end
end

if violations > 0 then
    log.raw("[check-terminology] " .. violations .. " user-visible string(s) use a non-canonical term.")
    log.raw("  Fix the string, or add the variant to locales/terminology.toml if it is correct.")
    verdict.emit("violation:terminology:" .. violations, 1)
end
verdict.emit("ok:terminology-clean:terms=" .. terms .. ":files=" .. nfiles, 0)

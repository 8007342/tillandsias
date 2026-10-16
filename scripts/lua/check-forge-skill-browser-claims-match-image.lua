-- @trace order:1746-2szd, order:1649-xqet
-- @env TILLANDSIAS_BROWSER_CLAIM_DOCS TILLANDSIAS_BROWSER_CLAIM_CONTAINERFILES
--
-- check-forge-skill-browser-claims-match-image.lua — refuse a shipped skill,
-- cheatsheet or agent instruction that tells a forge agent a browser is
-- pre-installed, while the forge image installs none.
--
-- WHY (MEASURED 2026-10-16, forge-tillandsias on yolanda, 56.10.16.1):
-- skills/forge-quick-intro said "Headless and headful Chrome debugging browsers
-- are pre-installed and configured", and its directive is "do not search for
-- tools". The forge has no chromium, chrome or firefox: browser windows come
-- from the host, through host-browser browser.open (1649-xqet). Agents trusted
-- the intro and planned browser work that could not run.
--
-- A CLAIM is one line that names a browser (chrome, chromium, firefox, webkit,
-- or the word browser) AND says pre-installed / preinstalled, and does not
-- negate it ("not pre-installed", "no browser"). The image SHIPS a browser
-- when a non-comment line of a forge Containerfile names a browser package.
-- When it does, claims are true and nothing is refused.
--
-- Population: skills/**/*.md, cheatsheets/**/*.md and
-- images/default/config-overlay/**/*.md (what an agent reads in the forge).
-- TILLANDSIAS_BROWSER_CLAIM_DOCS / _CONTAINERFILES are test seams: space-
-- separated repo-relative directories / files that replace the defaults.
--
-- Verdicts:
--   ok:forge-browser-claims:docs=<n>:claims=0:image-browsers=none          exit 0
--   ok:forge-browser-claims:docs=<n>:image-browsers=<pkg,...>              exit 0
--   violation:forge-browser-claims:claims=<n>:image-browsers=none          exit 1
--   could-not-run:forge-browser-claims:<why>                               exit 3

local function words(s) local t = {}; for w in (s or ""):gmatch("%S+") do t[#t + 1] = w end; return t end
local function seam(name, default)
    local v = env.get(name) or ""
    if v == "" then return default end
    return words(v)
end

local DOC_ROOTS = seam("TILLANDSIAS_BROWSER_CLAIM_DOCS", { "skills", "cheatsheets", "images/default/config-overlay" })
local CONTAINERFILES = seam("TILLANDSIAS_BROWSER_CLAIM_CONTAINERFILES",
    { "images/default/Containerfile.base", "images/default/Containerfile" })

-- Browser package names a Containerfile could install.
local BROWSER_PKGS = { "chromium", "chromium-headless", "google-chrome-stable", "google-chrome",
    "chrome-for-testing", "firefox", "epiphany", "webkit2gtk4.1", "webkitgtk6.0" }

local image_browsers, read_any = {}, false
for _, cf in ipairs(CONTAINERFILES) do
    local ok, src = pcall(fs.read, cf)
    if ok and src then
        read_any = true
        for _, line in ipairs(text.lines(src)) do
            if not line:match("^%s*#") then
                local l = " " .. line:lower():gsub("[\\]", " ") .. " "
                for _, p in ipairs(BROWSER_PKGS) do
                    local pat = "[%s=]" .. p:gsub("%p", "%%%0") .. "[%s]"
                    if l:find(pat) and not image_browsers[p] then
                        image_browsers[p] = true
                        image_browsers[#image_browsers + 1] = p
                    end
                end
            end
        end
    end
end
if not read_any then
    verdict.could_not_run("forge-browser-claims", "no forge Containerfile readable: " .. table.concat(CONTAINERFILES, " "))
end

local docs = {}
for _, root in ipairs(DOC_ROOTS) do
    local ok, files = pcall(fs.walk, root, { suffix = ".md" })
    if ok and files then for _, f in ipairs(files) do docs[#docs + 1] = f end end
end
if #docs == 0 then
    verdict.could_not_run("forge-browser-claims", "no docs under " .. table.concat(DOC_ROOTS, " "))
end

if #image_browsers > 0 then
    verdict.emit("ok:forge-browser-claims:docs=" .. #docs .. ":image-browsers=" .. table.concat(image_browsers, ","), 0)
end

local NAMES = { "chrome", "chromium", "firefox", "webkit", "browser" }
local function is_claim(line)
    local l = line:lower()
    if not (l:find("pre%-installed") or l:find("preinstalled") or l:find("pre installed")) then return false end
    local named = false
    for _, n in ipairs(NAMES) do if l:find(n, 1, true) then named = true end end
    if not named then return false end
    if l:find("not%s+pre%-?%s?installed") or l:find("no%s+[%w%s]-browser") then return false end
    return true
end

local claims = {}
for _, f in ipairs(docs) do
    local ok, src = pcall(fs.read, f)
    if ok and src then
        for i, line in ipairs(text.lines(src)) do
            if is_claim(line) then claims[#claims + 1] = f .. ":" .. i .. ": " .. text.trim(line) end
        end
    end
end

if #claims == 0 then
    verdict.emit("ok:forge-browser-claims:docs=" .. #docs .. ":claims=0:image-browsers=none", 0)
end
for _, c in ipairs(claims) do out.line("claim: " .. c) end
out.line("why: the forge image installs no browser (" .. table.concat(CONTAINERFILES, ", ")
    .. "), so an agent that trusts this line plans browser work that cannot run in the forge")
out.line("remedy: say the forge has no browser binary and that windows open on the host through"
    .. " host-browser browser.open (see skills/forge-quick-intro), or install the browser in the image")
verdict.emit("violation:forge-browser-claims:claims=" .. #claims .. ":image-browsers=none", 1)

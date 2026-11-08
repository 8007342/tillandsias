-- @trace order:1958-yfib, order:1958-jyfk
--
-- build-package-licence-register.lua — ask each LOCALLY BUILT Tillandsias image
-- what licence its distro packages declare, and write the answers to
-- docs/credits/package-licences.tsv for build-stack-ledger.lua to read.
-- Operator ruling 2026-11-01: the ledger's distro packages get the licence the
-- package manager declares; nothing is guessed, and a package no image
-- declares stays "unknown".
--
--   rpm (Fedora)   rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{LICENSE}\n'
--   apk (Alpine)   apk list -I  ->  name-ver arch {origin} (LICENCE) [installed]
--   dpkg (Debian)  declares NO licence field, so Debian/Ubuntu packages are listed
--                  with their version and licence "unknown" (honest, not a guess)
--
-- Only images present in the local podman store are asked (`podman image
-- exists localhost/tillandsias-<name>:latest`); an absent image leaves its
-- packages as they were. TSV columns: image  distro  package  version  licence
--   tillandsias-plan script run scripts/lua/build-package-licence-register.lua
-- Verdicts:
--   ok:package-licence-register:images=<n>:rows=<m>   exit 0
--   could-not-run:package-licence-register:<why>      exit 3  (no podman, or no image present)

local OUT = "docs/credits/package-licences.tsv"
local IMAGES = { "builder", "chromium-core", "chromium-framework", "default", "default-base", "flutter", "git", "imagegen",
    "imagegen-cuda", "imagegen-studio", "inference", "proxy", "router", "vault", "warp", "web", "web-studio-grapesjs",
    "web-wrangler", "webkit" }

local function run(argv, ms)
    return proc.run({ argv = argv, timeout_ms = ms or 120000 })
end
local have = run({ "podman", "--version" }, 20000)
if not have or not have.ok then
    verdict.emit("could-not-run:package-licence-register:no-podman", 3)
end

local rows, images = {}, 0
local function add(image, distro, pkg, ver, lic)
    lic = text.trim(lic or "")
    if lic == "" then lic = "unknown" end
    rows[#rows + 1] = table.concat({ image, distro, pkg, text.trim(ver or "unknown"), lic }, "\t")
end
local function sh(ref, script)
    return run({ "podman", "run", "--rm", "--entrypoint", "sh", ref, "-c", script })
end
for _, name in ipairs(IMAGES) do
    local ref = "localhost/tillandsias-" .. name .. ":latest"
    local ex = run({ "podman", "image", "exists", ref }, 20000)
    if ex and ex.ok then
        images = images + 1
        local r = sh(ref, "command -v rpm >/dev/null 2>&1 && rpm -qa --qf '%{NAME}\\t%{VERSION}-%{RELEASE}\\t%{LICENSE}\\n'")
        if r.ok and (r.stdout or "") ~= "" then
            for _, l in ipairs(text.lines(r.stdout)) do
                local p, v, lic = l:match("^([^\t]+)\t([^\t]*)\t(.*)$")
                if p then add(name, "fedora", p, v, lic) end
            end
        else
            r = sh(ref, "command -v apk >/dev/null 2>&1 && apk list -I 2>/dev/null")
            if r.ok and (r.stdout or "") ~= "" then
                for _, l in ipairs(text.lines(r.stdout)) do
                    local nv, lic = l:match("^(%S+)%s+%S+%s+{[^}]*}%s+%((.-)%)%s+%[installed%]")
                    if nv then
                        local p, v = nv:match("^(.-)%-(%d[^-]*%-r%d+)$")
                        add(name, "alpine", p or nv, v, lic)
                    end
                end
            else
                r = sh(ref, "command -v dpkg-query >/dev/null 2>&1 && dpkg-query -W -f '${Package}\\t${Version}\\n'")
                if r.ok and (r.stdout or "") ~= "" then
                    for _, l in ipairs(text.lines(r.stdout)) do
                        local p, v = l:match("^([^\t]+)\t(.*)$")
                        if p then add(name, "debian", p, v, "unknown") end
                    end
                end
            end
        end
    end
end
if images == 0 then
    verdict.emit("could-not-run:package-licence-register:no-local-image", 3)
end
table.sort(rows)
local body = "# @trace order:1958-yfib\n# Distro package licences AS DECLARED BY THE PACKAGE MANAGER inside each locally built\n"
    .. "# Tillandsias image (scripts/lua/build-package-licence-register.lua). dpkg declares no\n"
    .. "# licence field, so Debian/Ubuntu rows say unknown. Columns: image\tdistro\tpackage\tversion\tlicence\n"
    .. table.concat(rows, "\n") .. "\n"
pcall(fs.mkdir, "docs/credits")
fs.write(OUT, body)
verdict.emit(string.format("ok:package-licence-register:images=%d:rows=%d", images, #rows), 0)

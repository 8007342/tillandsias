-- @trace order:1762-bano, order:1761-bvyn
-- @env TILLANDSIAS_HOST_TRUST_SCAN
--
-- check-enclave-ca-not-host-trusted.lua — nothing in the tree installs a CA
-- into a HOST trust store unless the line says which constrained CA it is.
--
-- WHY (1762-bano, operator ruling 2026-10-17). The enclave CA now lives a
-- year and carries no name constraints: squid signs forge egress for real
-- domains with it. Trusted inside our containers that is the design, but
-- trusted by the HOST (the system store, an NSS db, the macOS keychain or the
-- Windows root store) its key would let anything that reads it impersonate
-- any site to the operator's browser for a year. A host-trusted CA must be
-- 1761-bvyn's separate preview CA, name-constrained to .localhost.
--
-- A SITE is a non-comment line of HOST-run code, crates/**/*.rs and
-- scripts/**/*.{sh,lua,ps1}, that runs a trust-store install: update-ca-trust,
-- `trust anchor`, certutil -A (an NSS add, or a quoted "-A" in a file that
-- runs certutil), the anchors directories,
-- `security add-trusted-cert` or Import-Certificate. A site is allowed only
-- when the line or the one above carries `host-trust-ok: <which CA>`.
-- images/** is NOT scanned: those entrypoints run inside our containers,
-- where trusting the enclave CA is the design (images/inference/entrypoint.sh
-- anchors it in the container's own store).
-- TILLANDSIAS_HOST_TRUST_SCAN (space-separated dirs) is the fixture seam.
--
-- Verdicts:
--   ok:enclave-ca-not-host-trusted:files=<n>:allowed=<k>      exit 0
--   violation:enclave-ca-not-host-trusted:sites=<n>           exit 1

local NAME = "enclave-ca-not-host-trusted"
local roots = {}
for w in (env.get("TILLANDSIAS_HOST_TRUST_SCAN") or ""):gmatch("%S+") do roots[#roots + 1] = w end
if #roots == 0 then roots = { "crates", "scripts" } end

local PATTERNS = {
    "update%-ca%-trust", "trust anchor", "certutil[^\n]-%-A[%s\"']", "ca%-trust/source/anchors",
    "share/ca%-certificates", "add%-trusted%-cert", "Import%-Certificate",
}
-- 1761-bvyn: an NSS add built as an argument list (Rust's
-- `vec!["-A", "-t", ...]`, a shell array) puts `-A` on a line without the word
-- certutil. In a file that runs certutil, a quoted "-A" token is a site too.
local function is_site(l, runs_certutil)
    for _, p in ipairs(PATTERNS) do if l:find(p) then return true end end
    return runs_certutil and l:find("[\"']%-A[\"']") ~= nil
end
local SUFFIX = { rs = true, sh = true, lua = true, ps1 = true }
local SELF = "check-enclave-ca-not-host-trusted.lua"
local TEST = "test-enclave-ca-not-host-trusted.lua"

local files, allowed, sites = 0, 0, {}
for _, root in ipairs(roots) do
    local ok, list = pcall(fs.walk, root)
    if ok and list then
        for _, f in ipairs(list) do
            local ext = f:match("%.(%w+)$")
            local base = f:match("([^/]+)$") or f
            if ext and SUFFIX[ext] and base ~= SELF and base ~= TEST and not f:find("/target/", 1, true) then
                local okr, src = pcall(fs.read, f)
                if okr and src then
                    files = files + 1
                    local prev = ""
                    local runs_certutil = src:find("certutil", 1, true) ~= nil
                    for i, l in ipairs(text.lines(src)) do
                        local code = not (l:match("^%s*#") or l:match("^%s*//") or l:match("^%s*%-%-"))
                        if code and is_site(l, runs_certutil) then
                            if l:find("host-trust-ok:", 1, true) or prev:find("host-trust-ok:", 1, true) then
                                allowed = allowed + 1
                            else
                                sites[#sites + 1] = f .. ":" .. i .. ": " .. text.trim(l)
                            end
                        end
                        prev = l
                    end
                end
            end
        end
    end
end

if #sites > 0 then
    for _, s in ipairs(sites) do out.line("site: " .. s) end
    out.line("why: the enclave CA is unconstrained and lives a year; in a host trust store its key would let anything that reads it impersonate any site to the operator's browser")
    out.line("remedy: install only 1761-bvyn's name-constrained preview CA on the host, and mark that line `host-trust-ok: <which CA, and its constraint>`")
    verdict.emit("violation:" .. NAME .. ":sites=" .. #sites, 1)
end
verdict.emit("ok:" .. NAME .. ":files=" .. files .. ":allowed=" .. allowed, 0)

-- @trace order:1716-t2gi
--
-- refresh-image-pins.lua — write images/image-pins.yaml, the record that
-- scripts/lua/check-image-pins.lua checks every `FROM …@sha256:` pin against
-- OFFLINE. This is the one step that needs the network: run it after adding
-- or changing a digest pin, then commit the record with the pin.
--
--   tillandsias-plan script run scripts/lua/refresh-image-pins.lua
--
-- For each pin the guard's census lists, it fetches the manifest BY DIGEST
-- from the pin's registry (anonymous pull; a 401 is answered with the
-- registry's own Bearer challenge), checks that the body hashes to the pinned
-- digest, and records the manifest's media type and, for an index, its
-- platforms. Nothing is trusted from a tag: the digest is what the build pulls.
-- A pin whose manifest cannot be read is NOT written as anything, so the guard
-- refuses it as unrecorded rather than passing it.
--
-- Verdict:
--   ok:refresh-image-pins:recorded=<n>                         exit 0
--   blocked:refresh-image-pins:<n> unreadable (stderr: which)   exit 1
--   blocked:refresh-image-pins:census-failed                    exit 2

local RECORD = "images/image-pins.yaml"

local census = proc.run({
    argv = { "tillandsias-plan", "script", "run", "scripts/lua/check-image-pins.lua", "--", "--census" },
    timeout_ms = 60000,
})
if census.status ~= "exited" or census.code ~= 0 then
    io.stderr:write("[refresh-image-pins] census failed: " .. tostring(census.stderr) .. "\n")
    verdict.emit("blocked:refresh-image-pins:census-failed", 2)
end

local pins = {}
for _, line in ipairs(text.lines(census.stdout or "")) do
    local ref, digest = line:match("^pin (%S+) (sha256:%x+)$")
    if ref then pins[#pins + 1] = { ref = ref, digest = digest } end
end

-- docker.io/library/x:tag -> registry-1.docker.io, library/x. A first path
-- component with a dot or colon is a registry host; otherwise Docker Hub.
local function locate(ref)
    local name = ref:gsub(":[^/:]+$", "")
    local first, rest = name:match("^([^/]+)/(.+)$")
    local registry, repo
    if first and (first:find("%.") or first:find(":")) then
        registry, repo = first, rest
    else
        registry, repo = "docker.io", name
    end
    if registry == "docker.io" then
        registry = "registry-1.docker.io"
        if not repo:find("/") then repo = "library/" .. repo end
    end
    return registry, repo
end

local ACCEPT = "Accept: application/vnd.oci.image.index.v1+json, "
    .. "application/vnd.docker.distribution.manifest.list.v2+json, "
    .. "application/vnd.oci.image.manifest.v1+json, "
    .. "application/vnd.docker.distribution.manifest.v2+json"

local function curl(argv)
    local full = { "curl", "-sS", "--max-time", "30" }
    for _, a in ipairs(argv) do full[#full + 1] = a end
    return proc.run({ argv = full, timeout_ms = 40000 })
end

-- Fetch the manifest body for registry/repo@digest. Returns body or nil, why.
local function fetch(registry, repo, digest)
    local url = "https://" .. registry .. "/v2/" .. repo .. "/manifests/" .. digest
    local probe = curl({ "-o", "/dev/null", "-D", "-", "-H", ACCEPT, url })
    local auth = nil
    local challenge = (probe.stdout or ""):match("[Ww][Ww][Ww]%-[Aa]uthenticate:%s*Bearer%s+([^\r\n]+)")
    if challenge then
        local realm = challenge:match('realm="([^"]+)"')
        local service = challenge:match('service="([^"]+)"')
        local scope = challenge:match('scope="([^"]+)"') or ("repository:" .. repo .. ":pull")
        if not realm then return nil, "no realm in the registry's challenge" end
        local turl = realm .. "?scope=" .. scope
        if service then turl = turl .. "&service=" .. service end
        local tr = curl({ "-f", turl })
        if tr.status ~= "exited" or tr.code ~= 0 then return nil, "token request failed" end
        local ok_j, tj = pcall(json.parse, tr.stdout or "")
        local token = ok_j and type(tj) == "table" and (tj.token or tj.access_token) or nil
        if not token then return nil, "no token in the registry's answer" end
        auth = "Authorization: Bearer " .. token
    end
    local argv = { "-f", "-H", ACCEPT }
    if auth then argv[#argv + 1] = "-H"; argv[#argv + 1] = auth end
    argv[#argv + 1] = url
    local r = curl(argv)
    if r.status ~= "exited" or r.code ~= 0 then return nil, "manifest request failed (curl " .. tostring(r.code) .. ")" end
    return r.stdout, nil
end

local entries, unreadable = {}, {}
for _, p in ipairs(pins) do
    local registry, repo = locate(p.ref)
    local body, why = fetch(registry, repo, p.digest)
    if body and "sha256:" .. hash.sha256(body) ~= p.digest then
        body, why = nil, "the body does not hash to the pinned digest"
    end
    local ok_j, m = false, nil
    if body then ok_j, m = pcall(json.parse, body) end
    if not (ok_j and type(m) == "table") then
        unreadable[#unreadable + 1] = p.ref .. "@" .. p.digest .. ": " .. (why or "not JSON")
    else
        local mt = m.mediaType
        local platforms = {}
        if type(m.manifests) == "table" then
            mt = mt or "application/vnd.oci.image.index.v1+json"
            for _, e in ipairs(m.manifests) do
                local pl = type(e) == "table" and e.platform or nil
                if type(pl) == "table" and pl.os and pl.architecture and pl.os ~= "unknown" then
                    local s = pl.os .. "/" .. pl.architecture
                    if pl.variant then s = s .. "/" .. pl.variant end
                    platforms[#platforms + 1] = s
                end
            end
        end
        entries[#entries + 1] = { ref = p.ref, digest = p.digest, media_type = mt or "unknown", platforms = platforms }
    end
end

local out = {
    "# images/image-pins.yaml — written by scripts/lua/refresh-image-pins.lua (order 1716-t2gi).",
    "# One entry per `FROM …@sha256:` pin, read from its registry BY DIGEST. Checked",
    "# offline by scripts/lua/check-image-pins.lua: each pin must be a multi-arch",
    "# index carrying linux/amd64 and linux/arm64. Do not hand-edit; re-run the script.",
    "pins:",
}
for _, e in ipairs(entries) do
    out[#out + 1] = "  - ref: " .. e.ref
    out[#out + 1] = "    digest: " .. e.digest
    out[#out + 1] = "    media_type: " .. e.media_type
    if #e.platforms == 0 then
        out[#out + 1] = "    platforms: []"
    else
        out[#out + 1] = "    platforms:"
        for _, pl in ipairs(e.platforms) do out[#out + 1] = "      - " .. pl end
    end
end
fs.write(RECORD, table.concat(out, "\n") .. "\n")

if #unreadable > 0 then
    for _, u in ipairs(unreadable) do io.stderr:write("unreadable:" .. u .. "\n") end
    verdict.emit("blocked:refresh-image-pins:" .. #unreadable .. " unreadable", 1)
end
verdict.emit("ok:refresh-image-pins:recorded=" .. #entries, 0)

-- @trace order:998-3z6g, order:975-rsgm, order:1625-9qyw
-- @env TILLANDSIAS_CA_DIR HOME
--
-- check-ca-bind-migration.lua — does any existing container bind a CA
-- directory that is no longer the declared one? (Ported from
-- scripts/check-ca-bind-migration.sh, the shell-to-lua item 1625-9qyw carried.)
--
-- WHY THIS IS NEEDED AT ALL, and why it is separate from changing the value.
-- Podman records a bind SOURCE in the container's stored definition at
-- CREATION. Changing images/default/ca-path.txt makes every NEW container
-- correct and leaves every EXISTING one binding a path that will not be there.
-- `podman start` then fails with:
--
--   crun: cannot stat `<old>/intermediate.crt`: No such file or directory
--
-- — which is the exact failure 975-rsgm is about, reintroduced by its own fix.
-- So the relocation is not a constant change: it needs affected containers
-- RECREATED, not restarted, and it needs to KNOW which ones are affected
-- rather than assuming a fresh host.
--
-- REPORTS, NEVER ACTS. Recreating a container is a mutation with a blast
-- radius (the proxy is the enclave's only egress path), and a check that
-- silently rebuilt containers would be a worse failure than the one it fixes.
-- It names what must be recreated and stops.
--
-- The declared directory: $TILLANDSIAS_CA_DIR when set, else the first
-- non-comment line of images/default/ca-path.txt with ${HOME} expanded, plus
-- "/ca" (the scripts/lib-ca-path.sh rule, unchanged).
--
-- Grammar (one line on stdout, nothing else; the detail goes to stderr):
--   ^(ok:ca-bind-current:[0-9]+|violation:ca-bind-stale:[0-9]+|skip:[a-z0-9-]+)$
-- The .sh printed the stale case as `migrate:ca-bind-stale:<n>`; the script
-- runner only emits house-prefix verdicts, so the port says `violation:` with
-- the same count, exit 1, and the same stderr detail. Nothing parsed the old
-- word (only archived prose quotes it).

local ca_dir = env.get("TILLANDSIAS_CA_DIR") or ""
if ca_dir == "" then
    local manifest = "images/default/ca-path.txt"
    local ok, body = pcall(fs.read, manifest)
    if not ok or not body then
        log.raw("blocked:ca-path:manifest-unreadable:" .. manifest)
        verdict.emit("skip:ca-path-manifest-unreadable", 1)
    end
    local tmpl
    for _, line in ipairs(text.lines(body)) do
        local t = text.trim(line)
        if t ~= "" and t:sub(1, 1) ~= "#" then tmpl = t:gsub("%s", ""); break end
    end
    if not tmpl then
        log.raw("blocked:ca-path:manifest-empty:" .. manifest)
        verdict.emit("skip:ca-path-manifest-empty", 1)
    end
    ca_dir = tmpl:gsub("%${HOME}", function() return env.get("HOME") or "" end) .. "/ca"
end

local probe = proc.run({ argv = { "podman", "--version" }, timeout_ms = 15000 })
if probe.code ~= 0 then verdict.emit("skip:no-podman", 0) end

-- Every container, not just the proxy: remote_projects.rs mounts the same
-- bundle into the git-login containers, and a migration that fixed only the
-- proxy would leave those failing on a path nobody looks at.
local ps = proc.run({ argv = { "podman", "ps", "-a", "--format", "{{.Names}}" }, timeout_ms = 30000 })
if ps.code ~= 0 then verdict.emit("skip:podman-unreadable", 0) end

local checked, stale, detail = 0, 0, {}
for _, c in ipairs(text.lines(ps.stdout or "")) do
    c = text.trim(c)
    if c ~= "" then
        local ins = proc.run({ argv = { "podman", "inspect", c, "--format",
            "{{range .HostConfig.Binds}}{{println .}}{{end}}" }, timeout_ms = 30000 })
        local binds = ins.stdout or ""
        if ins.code == 0 and binds:find("tillandsias-ca", 1, true) then
            checked = checked + 1
            if not binds:find(ca_dir .. "/", 1, true) then
                stale = stale + 1
                local src = binds:match("([^%s]*tillandsias%-ca[^:]*)") or "<unparsed>"
                detail[#detail + 1] = "  " .. c .. ": binds " .. src .. " but the declared directory is " .. ca_dir
            end
        end
    end
end

if stale > 0 then
    for _, d in ipairs(detail) do log.raw(d) end
    log.raw("  These containers bind a CA directory that is no longer declared.")
    log.raw("  podman recorded the bind SOURCE at creation, so 'podman start' will")
    log.raw("  fail with a crun stat error naming a path nobody chose — the very")
    log.raw("  failure 975-rsgm exists to remove.")
    log.raw("  REMEDY: RECREATE them through the enclave orchestration. Restarting")
    log.raw("  cannot work: the stale source is baked into the stored definition.")
    verdict.emit("violation:ca-bind-stale:" .. stale, 1)
end
verdict.emit("ok:ca-bind-current:" .. checked, 0)

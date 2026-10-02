-- @env TILLANDSIAS_GUEST_UNIT_ROOT
-- @read-env TILLANDSIAS_GUEST_UNIT_ROOT
-- @trace spec:vm-provisioning-lifecycle, spec:vsock-transport, order:1533-ew3n
-- Lua-authoritative port of check-guest-unit-hardening.sh.  The optional root
-- is a fixture seam; production reads the two shipped sources from this tree.
local root = env.get("TILLANDSIAS_GUEST_UNIT_ROOT") or ""
local function path(p) return root == "" and p or root .. "/" .. p end
local units = {
    { "crates/tillandsias-vm-layer/src/vz.rs", "cat > /etc/systemd/system/tillandsias-headless.service", "EOF" },
    { "crates/tillandsias-vm-layer/src/wsl.rs", "cat > /etc/systemd/system/tillandsias-headless.service", "systemctl enable tillandsias-headless.service" },
}
local pat = "NoNewPrivileges|CapabilityBoundingSet|AmbientCapabilities|ProtectSystem|ProtectHome|PrivateTmp|PrivateDevices|PrivateUsers|RestrictNamespaces|SystemCallFilter|ReadOnlyPaths|ProtectKernelModules|ProtectKernelTunables|LockPersonality|MemoryDenyWriteExecute|RestrictSUIDSGID"
local function raw_lines(s)
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    if s:sub(-1) == "\n" then out[#out] = nil end
    return out
end
local hits, found = 0, false
for _, unit in ipairs(units) do
    local ok, source = pcall(fs.read, path(unit[1]))
    if ok then
        local body, inside = {}, false
        for _, line in ipairs(raw_lines(source)) do
            if line:find(unit[2], 1, true) then inside = true end
            if inside then body[#body + 1] = line end
            if inside and line:find(unit[3], 1, true) and not line:find(unit[2], 1, true) then break end
        end
        if #body > 0 then
            found = true
            local bad = {}
            for n, line in ipairs(body) do
                if text.is_match(line, pat) then bad[#bad + 1] = n .. ":" .. line end
            end
            if #bad > 0 then
                log.raw("[check-guest-unit-hardening] " .. unit[1] .. " — the guest headless unit forks podman and must not be confined:")
                for i = 1, math.min(5, #bad) do log.raw(bad[i]) end
                hits = hits + 1
            end
        end
    end
end
if not found then
    log.raw("[check-guest-unit-hardening] could not locate any guest headless unit text; the markers have drifted and this guard is inert")
    verdict.emit("blocked:guest-unit-not-found", 1)
end
if hits > 0 then
    log.raw("[check-guest-unit-hardening] Order 308 shipped exactly this and wedged every podman ensure: a cap-stripped uid-0 podman selects ROOTLESS mode. Confinement requires the listener/orchestrator split first — see plan/issues/headless-least-privilege-split-design-2026-08-17.md (order 309). If the split HAS landed, re-aim this guard at the orchestrator unit rather than deleting it.")
    verdict.emit("blocked:guest-unit-hardened:" .. hits, 1)
end
verdict.emit("ok:guest-unit-unconfined", 0)

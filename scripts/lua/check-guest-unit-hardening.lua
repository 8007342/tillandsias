-- @env TILLANDSIAS_GUEST_UNIT_ROOT
-- @read-env TILLANDSIAS_GUEST_UNIT_ROOT
-- @trace spec:vm-provisioning-lifecycle, spec:vsock-transport, order:1533-ew3n
-- Lua-authoritative port of check-guest-unit-hardening.sh.  The optional root
-- is a fixture seam; production reads the shipped sources from this tree.
local root = env.get("TILLANDSIAS_GUEST_UNIT_ROOT") or ""
local function path(p) return root == "" and p or root .. "/" .. p end
-- ORDER 2262-bke7. Every file that SHIPS the headless unit, and each must be found. The
-- unit is the text from "[Unit]" to "[Install]" around its ExecStart line, which a
-- heredoc, a Rust format string and a shell script all have. Keyed on the `cat >`
-- line, this guard saw only a reference once 740-3k4s hoisted the WSL unit into
-- headless_unit(), and finding one file's unit excused a drifted other.
local units = {
    "crates/tillandsias-vm-layer/src/vz.rs",
    "crates/tillandsias-vm-layer/src/wsl.rs",
    "crates/tillandsias-windows-tray/src/wsl_lifecycle.rs",
    "images/vm/bootstrap/20-tillandsias.sh",
}
local EXEC = "ExecStart=/usr/local/bin/tillandsias-headless"
local REACH = 60 -- lines either side of ExecStart
local pat = "NoNewPrivileges|CapabilityBoundingSet|AmbientCapabilities|ProtectSystem|ProtectHome|PrivateTmp|PrivateDevices|PrivateUsers|RestrictNamespaces|SystemCallFilter|ReadOnlyPaths|ProtectKernelModules|ProtectKernelTunables|LockPersonality|MemoryDenyWriteExecute|RestrictSUIDSGID"
local function raw_lines(s)
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    if s:sub(-1) == "\n" then out[#out] = nil end
    return out
end
local hits, missing = 0, {}
for _, file in ipairs(units) do
    local ok, source = pcall(fs.read, path(file))
    local found = false
    if ok and source then
        local L = raw_lines(source)
        for i, line in ipairs(L) do
            if line:find(EXEC, 1, true) then
                local from, to
                for j = i, math.max(1, i - REACH), -1 do if L[j]:find("[Unit]", 1, true) then from = j; break end end
                for j = i, math.min(#L, i + REACH) do if L[j]:find("[Install]", 1, true) then to = j; break end end
                if from and to then
                    found = true
                    local bad = {}
                    for j = from, to do
                        local t = text.trim(L[j])
                        if t:sub(1, 2) ~= "//" and t:sub(1, 1) ~= "#" and text.is_match(t, pat) then bad[#bad + 1] = j .. ":" .. L[j] end
                    end
                    if #bad > 0 then
                        log.raw("[check-guest-unit-hardening] " .. file .. " — the guest headless unit forks podman and must not be confined:")
                        for k = 1, math.min(5, #bad) do log.raw(bad[k]) end
                        hits = hits + 1
                    end
                end
            end
        end
    end
    if not found then missing[#missing + 1] = file end
end
if #missing > 0 then
    log.raw("[check-guest-unit-hardening] no guest headless unit text found in: " .. table.concat(missing, ", "))
    log.raw("  why: this guard is inert for a file whose unit it cannot find, and that must not read as unconfined")
    log.raw("  remedy: point it at where the unit moved; drop the file from its list only when it no longer ships one")
    verdict.emit("blocked:guest-unit-not-found:" .. missing[1], 1)
end
if hits > 0 then
    log.raw("[check-guest-unit-hardening] Order 308 shipped exactly this and wedged every podman ensure: a cap-stripped uid-0 podman selects ROOTLESS mode. Confinement requires the listener/orchestrator split first — see plan/issues/headless-least-privilege-split-design-2026-08-17.md (order 309). If the split HAS landed, re-aim this guard at the orchestrator unit rather than deleting it.")
    verdict.emit("blocked:guest-unit-hardened:" .. hits, 1)
end
verdict.emit("ok:guest-unit-unconfined", 0)

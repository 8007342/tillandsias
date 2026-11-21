-- @env TILLANDSIAS_PURGE_GUARD_SOFT_SRC
-- @trace order:803-49re, order:900-z3kv, order:2007-vy3p, spec:host-state-lifecycle, order:1559-2uw3
--
-- check-purge-clears-vault-credentials.lua — a script that DESTROYS THE GUEST
-- must also clear the host's copy of that guest's Vault identity.
-- (Ported from scripts/check-purge-clears-vault-credentials.sh, a shell-to-lua
-- item; history in `git log -- scripts/check-purge-clears-vault-credentials.sh`.)
--
-- WHY THIS GUARD EXISTS RATHER THAN A THIRD CAREFUL EDIT. Part A landed the
-- clearing in scripts/install-windows.ps1 in a8cd8cc32 and the packet read as
-- fixed. Measured 2026-09-02 on yolanda, six days later:
-- scripts/build-and-install-windows-local.ps1 -Purge unregistered the
-- `tillandsias` distro and cleared nothing, so the developer-facing installer
-- still produced the 2026-08-17 incident end to end. "One copy fixed and one
-- copy missed" is this project's most-repeated defect; the remedy is to make
-- the second copy impossible to add silently. So the clearing is ONE function
-- in scripts/clear-vault-host-credentials.ps1 and this refuses any purge path
-- that unregisters the distro without calling it.
--
-- WHAT IT CHECKS, deliberately narrow:
--   WINDOWS  any tracked .ps1 containing `wsl --unregister tillandsias` must
--            also name Clear-TillandsiasVaultHostCredentials (the definition
--            file is exempt). Not reachability: a text scan cannot know that.
--   LINUX    (900-z3kv) any tracked .sh with a line that EXECUTES
--            `podman system reset` (the match must precede any `#` on its
--            line, so a comment naming it is not a purge path) must name
--            clear-vault-host-credentials.sh. Exempt: the clearer itself and
--            scripts/test-* fixtures.
--   SOFT     (1559-2uw3, negative arm) the Windows SOFT reset body, cut from
--            `pub fn reset_state_once() -> i32 {` to the next
--            `pub fn reset_guest_once(` with // comments stripped, must call
--            NO clearer. A body that cannot be found is a violation by name.
--            TILLANDSIAS_PURGE_GUARD_SOFT_SRC is the fixture seam
--            (scripts/test-purge-guard-soft-arm.sh); it must lie inside the
--            repository, since fs is confined to it.
-- 2007-vy3p: a tracked file this guard cannot read is a violation
-- (`<file>:unreadable-grep-exit-2`, the .sh's word), never a skip.
--
-- Prints exactly one line matching
--   ^(ok:purge-clears-vault-credentials:[0-9]+ scanned|violation:purge-without-credential-clear:.+)$
-- and exits 0 when every such script calls the shared clearer, 1 otherwise,
-- exactly as the .sh.

local function git(...)
    return proc.run({ argv = { "git", ... }, timeout_ms = 30000 })
end

local top = git("rev-parse", "--show-toplevel")
local ROOT = (top.status == "exited" and top.code == 0) and text.trim(top.stdout or "") or ""
if ROOT == "" then
    verdict.emit("violation:purge-without-credential-clear:not-a-git-repo", 1)
end

local function tracked(glob)
    local r = proc.run({ argv = { "git", "ls-files", glob }, cwd = ROOT, timeout_ms = 30000 })
    if r.status ~= "exited" or r.code ~= 0 then return {} end
    local out = {}
    for _, l in ipairs(text.lines(r.stdout or "")) do
        if l ~= "" then out[#out + 1] = l end
    end
    return out
end

-- Returns contents, or nil + "missing" (the .sh's `[ -f ]` skip) / "unreadable".
local function slurp(rel)
    local abs = rel:sub(1, 1) == "/" and rel or (ROOT .. "/" .. rel)
    if not fs.exists(abs) then return nil, "missing" end
    local ok, body = pcall(fs.read, abs)
    if not ok then return nil, "unreadable" end
    return body
end

local scanned = 0
local violations = {}

-- WINDOWS ARM
local CLEARER = "Clear-TillandsiasVaultHostCredentials"
local DESTROYS = "wsl --unregister tillandsias"
for _, f in ipairs(tracked("*.ps1")) do
    local body, why = slurp(f)
    if why == "unreadable" then
        violations[#violations + 1] = f .. ":unreadable-grep-exit-2"
    elseif body and text.contains(body, DESTROYS) then
        scanned = scanned + 1
        if f ~= "scripts/clear-vault-host-credentials.ps1" and not text.contains(body, CLEARER) then
            violations[#violations + 1] = f
        end
    end
end

-- LINUX ARM: executes, not mentions.
local LINUX_CLEARER = "clear-vault-host-credentials.sh"
local LINUX_DESTROYS = "^[^#]*podman[[:space:]]+system[[:space:]]+reset"
for _, f in ipairs(tracked("*.sh")) do
    local body, why = slurp(f)
    if why == "unreadable" then
        violations[#violations + 1] = f .. ":unreadable-grep-exit-2"
    elseif body then
        local hit = false
        for _, l in ipairs(text.lines(body)) do
            if text.is_match(l, LINUX_DESTROYS) then hit = true; break end
        end
        if hit then
            scanned = scanned + 1
            local exempt = f == "scripts/clear-vault-host-credentials.sh" or f:sub(1, 13) == "scripts/test-"
            if not exempt and not text.contains(body, LINUX_CLEARER) then
                violations[#violations + 1] = f
            end
        end
    end
end

-- SOFT ARM (negative)
local SOFT_SRC = env.get("TILLANDSIAS_PURGE_GUARD_SOFT_SRC")
if SOFT_SRC == nil or SOFT_SRC == "" then
    SOFT_SRC = "crates/tillandsias-windows-tray/src/notify_icon.rs"
end
local soft_lines = {}
do
    local src = slurp(SOFT_SRC)
    local inside = false
    for _, l in ipairs(src and text.lines(src) or {}) do
        if not inside and text.is_match(l, "^pub fn reset_state_once\\(\\) -> i32 \\{") then inside = true end
        if inside and text.is_match(l, "^pub fn reset_guest_once\\(") then break end
        if inside then
            local c = l:find("//", 1, true)
            soft_lines[#soft_lines + 1] = c and l:sub(1, c - 1) or l
        end
    end
end
local soft_body = table.concat(soft_lines, "\n"):gsub("\n+$", "")
scanned = scanned + 1
if soft_body == "" then
    violations[#violations + 1] = SOFT_SRC .. ":soft-body-not-found"
elseif text.is_match(soft_body, "clear_guest_vault_credentials\\(|Clear-TillandsiasVaultHostCredentials|\\.wipe_guest\\(") then
    violations[#violations + 1] = SOFT_SRC .. ":soft-reset-calls-a-clearer"
end

if #violations > 0 then
    verdict.emit("violation:purge-without-credential-clear:" .. table.concat(violations, ","), 1)
end
verdict.emit("ok:purge-clears-vault-credentials:" .. scanned .. " scanned", 0)

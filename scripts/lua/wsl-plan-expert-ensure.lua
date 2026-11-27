-- @env TILLANDSIAS_WSL_BUILD_DISTRO TILLANDSIAS_WSL_FAKE_UNAME
-- @trace order:770-ehym, order:2421-7wvs
--
-- wsl-plan-expert-ensure.lua — the OUTER lane of scripts/wsl-plan-expert-ensure.sh, ported (2421-7wvs).
-- Ensure the WSL-side MCP expert binary exists on a path the WINDOWS lifecycle cannot touch (770-ehym;
-- plan/issues/windows-host-tooling-hits-linux-elves-in-target-2026-08-16.md): the Windows daily cache
-- sweep deleted the Linux ELF the WSL experts exec'd from the shared target/, so every tool call died.
-- The fix builds the WSL expert into a WSL-local CARGO_TARGET_DIR and installs it to
-- ~/.local/bin/tillandsias-plan inside the distro.
--
-- This file is the Windows-host side only: it finds the build distro and re-execs the INNER lane, which
-- stays in scripts/wsl-plan-expert-ensure.sh because it runs inside the guest, where no Lua runner exists
-- until 2420-rd7x.
--
-- GRAMMAR (one verdict line; always exit 0 — advisory, the direct-binary fallback keeps a cycle alive):
--   ok:wsl-plan-expert:<installed-path>
--   skip:(not-windows|no-wsl|no-build-distro)
--   degraded:(no-cargo-in-distro|wsl-build-failed|install-failed|capabilities-refused|wsl-invoke-failed|cannot-cd-repo)
-- Test seams: TILLANDSIAS_WSL_FAKE_UNAME stands in for `uname -s`.
--
-- Usage: tillandsias-plan script run scripts/lua/wsl-plan-expert-ensure.lua

local function done(line) verdict.emit(line, 0) end

local uname = env.get("TILLANDSIAS_WSL_FAKE_UNAME")
if not uname or uname == "" then
    local r = proc.run({ argv = { "uname", "-s" }, timeout_ms = 10000 })
    uname = text.trim(r.ok and r.stdout or "")
end
if not (uname:match("^MINGW") or uname:match("^MSYS") or uname:match("^CYGWIN")) then done("skip:not-windows") end

-- wsl.exe emits UTF-16LE; strip NULs and CRs before matching (as the .sh's tr -d '\0\r').
local function clean(s) return ((s or ""):gsub("%z", ""):gsub("\r", "")) end
local list = proc.run({ argv = { "wsl.exe", "-l", "-q" }, timeout_ms = 60000 })
if list.status == "spawn_failed" then done("skip:no-wsl") end
local distro = env.get("TILLANDSIAS_WSL_BUILD_DISTRO")
if not distro or distro == "" then distro = "tillandsias-build" end
local found = false
for _, l in ipairs(text.lines(clean(list.stdout))) do if text.trim(l) == distro then found = true end end
if not found then done("skip:no-build-distro") end

-- The repo as the distro sees it: C:/x is /mnt/c/x under default WSL mounts.
local root = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 10000 }).stdout or "")
local drive, rest = root:match("^(%a):[/\\](.*)$")
if not drive then done("degraded:wsl-invoke-failed") end
local repo_wsl = "/mnt/" .. drive:lower() .. "/" .. rest:gsub("\\", "/")
-- Argv, not a shell string: wsl.exe runs bash on the inner lane's FILE, with `inner` as its argument.
local r = proc.run({ argv = { "wsl.exe", "-d", distro, "--", "bash", "-l", repo_wsl .. "/scripts/wsl-plan-expert-ensure.sh", "inner" },
    timeout_ms = 1800000 })
local lines = text.lines(text.trim(clean(r.stdout)))
local v = lines[#lines] or ""
if v:match("^ok:wsl%-plan%-expert:") or v:match("^degraded:") or v:match("^skip:") then done(v) end
done("degraded:wsl-invoke-failed")

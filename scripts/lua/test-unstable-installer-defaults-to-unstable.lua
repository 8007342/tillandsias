-- @trace order:1369-sjbc, spec:ci-release, order:2111-inst
--
-- test-unstable-installer-defaults-to-unstable.lua — fixture for 1369-sjbc: an
-- installer fetched from the UNSTABLE release must install unstable with
-- TILLANDSIAS_CHANNEL unset, and the stable copy must not. Ported from
-- scripts/test-unstable-installer-defaults-to-unstable.sh (2111-inst) onto the
-- scratch.* door, with the same arms. The manifests are built and verified in
-- Lua with hash.sha256 (the shell used sha256sum / sha256sum -c).
--
-- Builds a fake artifact directory from the REAL installers, stages it through
-- scripts/stage-unstable-installers.sh exactly as the release jobs do, then RUNS
-- each installer with TILLANDSIAS_INSTALL_RESOLVE_ONLY=1 (it prints its
-- resolved-channel line and exits before any host step) and reads the base URL.
--   A  the unstable copy of install.sh / install-macos.sh resolves /releases/download/unstable
--   B  CONTROL: the stable copies still resolve /releases/latest/download
--   C  an explicit TILLANDSIAS_CHANNEL=stable on the unstable copy still wins
--   D  install-windows.ps1: the rewritten default line; RUN through PowerShell
--      where one exists, otherwise a named skip
--   E  the rewritten SHA256SUMS-windows verifies; a CRLF .ps1 keeps its CRs
--   F  exactly the files that were signed in the source are listed for re-signing
--   G  refusals: a missing default line, and a directory with no installer
-- The installers are launched through `env -u ...`: the runner's child env
-- inherits the caller's TILLANDSIAS_* and its door cannot unset one (2110-unst).
--
-- USAGE   tillandsias-plan script run scripts/lua/test-unstable-installer-defaults-to-unstable.lua
-- GRAMMAR ok:unstable-installer-fixture:ran=<n> skipped=<k> (exit 0) | refused:unstable-installer-fixture:failed=<n> ... (exit 1)

local fixture = require "common.fixture"
local T = fixture.new("unstable-installer-fixture")

local ROOT = fixture.repo_root()
local STAGE = ROOT .. "/scripts/stage-unstable-installers.sh"
local UNSTABLE_BASE = "https://github.com/8007342/tillandsias/releases/download/unstable"
local STABLE_BASE = "https://github.com/8007342/tillandsias/releases/latest/download"
local has = text.contains
local w = T:scratch()
local BASEPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

local function stage(src, dst) -- -> rc, stdout
    local r = proc.run{ argv = { fixture.posix_shell(), STAGE, w.abs .. "/" .. src, w.abs .. "/" .. dst },
        env = { PATH = BASEPATH }, timeout_ms = 60000 }
    return (r.status == "exited") and r.code or -1, r.stdout or "", r.stderr or ""
end
local function manifest(dir, names, binary)
    local lines = {}
    for _, n in ipairs(names) do
        lines[#lines + 1] = hash.sha256(scratch.read(dir .. "/" .. n)) .. (binary and " *" or "  ") .. n
    end
    scratch.write(dir .. "/SHA256SUMS-windows", table.concat(lines, "\n") .. "\n")
end
-- Every manifest line names a present file whose bytes hash to the listed digest.
local function verifies(dir)
    local body = scratch.read(dir .. "/SHA256SUMS-windows")
    local n = 0
    for _, l in ipairs(text.lines(body)) do
        if text.trim(l) ~= "" then
            local digest, name = l:match("^(%x+) [ *](.+)$")
            if not digest or not scratch.exists(dir .. "/" .. name) then return false end
            if hash.sha256(scratch.read(dir .. "/" .. name)) ~= digest then return false end
            n = n + 1
        end
    end
    return n > 0
end

-- The fake release artifacts.
local src = w.leaf .. "/release-artifacts"
scratch.mkdir(src)
for _, f in ipairs({ "install.sh", "install-macos.sh", "install-windows.ps1" }) do
    scratch.write(src .. "/" .. f, fs.read("scripts/" .. f))
    scratch.chmod(src .. "/" .. f, tonumber("755", 8))
end
scratch.write(src .. "/tillandsias-tray.exe", "tray\n")
manifest(src, { "install-windows.ps1", "tillandsias-tray.exe" })
for _, b in ipairs({ "install.sh", "install-macos.sh", "install-windows.ps1", "SHA256SUMS-windows", "tillandsias-tray.exe" }) do
    scratch.write(src .. "/" .. b .. ".cosign.bundle", "")
end

local rc, o = stage("release-artifacts", "unstable")
T:arm("stage: rewritten=3 resign=4", rc == 0 and has(o, "ok:stage-unstable-installers:rewritten=3 resign=4"),
    "rc=" .. rc .. " " .. o)

-- F: the four signed files that changed, and nothing else.
local got = {}
for _, l in ipairs(text.lines(o)) do if l:sub(1, 7) == "resign:" then got[#got + 1] = l end end
table.sort(got)
local want = { "resign:SHA256SUMS-windows", "resign:install-macos.sh", "resign:install-windows.ps1", "resign:install.sh" }
T:arm("F the resign list is exactly the four rewritten signed files", table.concat(got, ",") == table.concat(want, ","),
    table.concat(got, ","))
T:arm("F an unchanged file keeps its bundle", scratch.exists(w.leaf .. "/unstable/tillandsias-tray.exe.cosign.bundle"), "lost")
T:arm("F no stale bundle beside a rewritten installer", not scratch.exists(w.leaf .. "/unstable/install.sh.cosign.bundle"), "left")

-- A, B and C, both POSIX installers.
local function resolved(inst, channel)
    local argv = { "/usr/bin/env", "-u", "TILLANDSIAS_CHANNEL", "-u", "TILLANDSIAS_RELEASE_BASE", "-u", "TILLANDSIAS_VERSION" }
    if channel then argv[#argv + 1] = "TILLANDSIAS_CHANNEL=" .. channel end
    for _, a in ipairs({ "TILLANDSIAS_INSTALL_RESOLVE_ONLY=1", fixture.posix_shell(), w.abs .. "/" .. inst }) do argv[#argv + 1] = a end
    local r = proc.run{ argv = argv, env = { PATH = BASEPATH }, timeout_ms = 30000 }
    return (r.stdout or "") .. (r.stderr or "")
end
local function base_ok(out_, want_base, want_src)
    for _, l in ipairs(text.lines(out_)) do
        local i = l:find("resolved-channel: ", 1, true)
        if i and l:sub(-#("(" .. want_src .. ") base: " .. want_base)) == "(" .. want_src .. ") base: " .. want_base then
            return true
        end
    end
    return false
end
for _, inst in ipairs({ "install.sh", "install-macos.sh" }) do
    local g = resolved("unstable/" .. inst)
    T:arm("A " .. inst .. " unstable copy, channel unset", base_ok(g, UNSTABLE_BASE, "default of this installer copy"), g)
    g = resolved("release-artifacts/" .. inst)
    T:arm("B " .. inst .. " stable copy, channel unset (control)", base_ok(g, STABLE_BASE, "default of this installer copy"), g)
    g = resolved("unstable/" .. inst, "stable")
    T:arm("C " .. inst .. " unstable copy, explicit stable wins", base_ok(g, STABLE_BASE, "TILLANDSIAS_CHANNEL"), g)
end

-- D: the Windows installer.
local n = 0
for _, l in ipairs(text.lines((scratch.read(w.leaf .. "/unstable/install-windows.ps1"):gsub("\r", "")))) do
    if l == "$DefaultChannel = 'unstable'" then n = n + 1 end
end
T:arm("D install-windows.ps1 has exactly one unstable default line", n == 1, "count " .. n)
local skipped, ps_ran = 0, false
for _, pair in ipairs({ { "unstable", UNSTABLE_BASE, "unstable" }, { "stable", STABLE_BASE, "release-artifacts" } }) do
    local r
    for _, c in ipairs({ "pwsh", "powershell" }) do
        if not (r and r.status == "exited") then
            r = proc.run{ argv = { "/usr/bin/env", "-u", "TILLANDSIAS_CHANNEL", "-u", "TILLANDSIAS_VERSION",
                "TILLANDSIAS_INSTALL_RESOLVE_ONLY=1", c, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                w.abs .. "/" .. pair[3] .. "/install-windows.ps1" }, env = { PATH = BASEPATH }, timeout_ms = 60000 }
        end
    end
    local po = ((r.stdout or "") .. (r.stderr or "")):gsub("\r", "")
    -- env exits 127 when the program is absent.
    if r.status == "exited" and r.code ~= 127 then
        ps_ran = true
        T:arm("D install-windows.ps1 " .. pair[1] .. " copy resolves its base",
            has(po, "(default of this installer copy) base: " .. pair[2]), po)
    end
end
if not ps_ran then
    out.line("skip:unstable-installer-fixture:D-run:no-pwsh-on-this-host")
    skipped = skipped + 1
end

-- E: the manifest verifies, and a CRLF .ps1 is rewritten with its CRs kept.
T:arm("E the rewritten SHA256SUMS-windows verifies", verifies(w.leaf .. "/unstable"), "a digest does not match")
local crlf = w.leaf .. "/crlf-src"
scratch.mkdir(crlf)
local ps1 = fs.read("scripts/install-windows.ps1"):gsub("\n", "\r\n")
scratch.write(crlf .. "/install-windows.ps1", ps1)
manifest(crlf, { "install-windows.ps1" }, true)
local crc = stage("crlf-src", "crlf-dst")
T:arm("E CRLF staging is accepted", crc == 0, "rc=" .. crc)
local function crs(s) return select(2, s:gsub("\r", "")) end
local before, after = crs(ps1), crs(scratch.exists(w.leaf .. "/crlf-dst/install-windows.ps1")
    and scratch.read(w.leaf .. "/crlf-dst/install-windows.ps1") or "")
T:arm("E a CRLF .ps1 keeps every CR", before == after and before > 0, before .. " CRs before, " .. after .. " after")
T:arm("E the binary-form (*name) manifest verifies after the rewrite", verifies(w.leaf .. "/crlf-dst"), "a digest does not match")

-- G: refusals.
local broken = w.leaf .. "/broken-src"
scratch.mkdir(broken)
local inst = fs.read("scripts/install.sh")
local sabotaged, k = inst:gsub('\nDEFAULT_CHANNEL="stable"\n', '\nDEFAULT_CHANNEL=stable\n')
scratch.write(broken .. "/install.sh", sabotaged)
local grc, go = stage("broken-src", "broken-dst")
T:arm("G a missing default line is refused by name",
    k == 1 and text.trim(go) == "refused:stage-unstable-installers:default-line-count:install.sh:0",
    "sabotage applied=" .. k .. " got '" .. text.trim(go) .. "'")
local empty = w.leaf .. "/empty-src"
scratch.mkdir(empty)
scratch.write(empty .. "/tillandsias-linux-x86_64", "x\n")
local erc, eo = stage("empty-src", "empty-dst")
T:arm("G a directory with no installer is refused by name",
    text.trim(eo) == "refused:stage-unstable-installers:no-installer-in:" .. w.abs .. "/empty-src", "got '" .. text.trim(eo) .. "'")

T:finish({
    ok = function(np) return "ok:unstable-installer-fixture:ran=" .. np .. " skipped=" .. skipped end,
    fail = function(nf) return "refused:unstable-installer-fixture:failed=" .. nf .. " ran=" .. (T.passed + nf) .. " skipped=" .. skipped end,
})

-- @trace order:1068-phrh, spec:install-progress
--
-- test-install-refuses-unverified-asset.lua — scripts/install.sh never installs a
-- binary it could not check against the release's SHA256SUMS (1068-phrh).
--
-- Before the fix, each of three failure paths printed "skipping checksum
-- verification" and installed anyway: SHA256SUMS absent, the asset unlisted in
-- it, sha256sum not on PATH. The block between BEGIN/END-ASSET-VERIFY is cut
-- from the installer and run under its own `set -euo pipefail`, against a
-- file:// release directory in scratch. "proceeded" means the installer would
-- go on to install.
--
-- Arms
--   H  HEALTHY      a matching checksum proceeds (must keep passing)
--   M  MISMATCH     a wrong checksum stops
--   A  ABSENT       no SHA256SUMS: refused, saying nothing was installed (the
--                   override is not printed: installer output is end-user only)
--   U  UNLISTED     the asset missing from SHA256SUMS: refused
--   S  SHASUM       no sha256sum, shasum present: verified through shasum,
--                   and a wrong checksum still stops (S2)
--   N  NO-TOOL      neither tool: refused
--   O  OVERRIDE     TILLANDSIAS_INSTALL_UNVERIFIED=1 proceeds on ABSENT, and says so
--   P  PLAIN        every refusal is one ERROR line with no "skipping" wording
--
-- Usage: tillandsias-plan script run scripts/lua/test-install-refuses-unverified-asset.lua

local fixture = require "common.fixture"
local T = fixture.new("install-refuses-unverified-asset")
local SH = fixture.posix_shell()
-- each case runs under a PATH of chosen tools only, so the shell itself is named absolutely
local SH_ABS = fixture.which(SH) or SH

local src = "\n" .. (fs.read("scripts/install.sh") or ""):gsub("\r\n", "\n") .. "\n"
local from, to = "\n# BEGIN-ASSET-VERIFY\n", "\n# END-ASSET-VERIFY\n"
local a, b = src:find(from, 1, true), src:find(to, 1, true)
if not a or not b then T:refuse("markers", "scripts/install.sh has no BEGIN/END-ASSET-VERIFY block") end
local BLOCK = src:sub(a + 1, b + #to - 1)

local ASSET = "tillandsias-linux-x86_64"
local W = T:scratch("verify")

-- A PATH holding only what the block may use, with sha256sum and shasum optional.
local function toolbin(name, with_sha256sum, with_shasum)
    local dir = W.rel .. "/bin-" .. name
    fs.mkdir(dir)
    local tools = { "curl", "grep", "awk", "cat", "basename", "dirname", "env", "mkdir", "rm", "printf", "tr", "sed", "head" }
    if with_sha256sum then tools[#tools + 1] = "sha256sum" end
    -- A Linux host often has no shasum (it ships with perl on macOS). There the
    -- arm still needs one, so a stand-in drops "-a 256" and runs sha256sum.
    local real_shasum = fixture.which("shasum")
    if with_shasum and real_shasum then tools[#tools + 1] = "shasum"; tools[#tools + 1] = "perl" end
    for _, t in ipairs(tools) do
        local p = fixture.which(t)
        if p then T:must{ "ln", "-s", p, W.abs .. "/bin-" .. name .. "/" .. t } end
    end
    if with_shasum and not real_shasum then
        local s256 = fixture.which("sha256sum")
        if not s256 then T:refuse("tools", "this host has neither shasum nor sha256sum") end
        fs.write(dir .. "/shasum", "#!" .. SH_ABS .. "\n[ \"$1\" = -a ] && shift 2\nexec " .. s256 .. " \"$@\"\n")
        T:must{ "chmod", "+x", W.abs .. "/bin-" .. name .. "/shasum" }
    end
    return W.abs .. "/bin-" .. name
end

local function sha_of(path)
    local r = T:run{ "shasum", "-a", "256", path }
    if r.code ~= 0 then r = T:run{ "sha256sum", path } end
    return (r.stdout or ""):match("^(%x+)")
end

-- One case: a release dir with the asset and (optionally) a SHA256SUMS.
local n = 0
local function case(opts)
    n = n + 1
    local d = W.rel .. "/c" .. n
    fs.mkdir(d .. "/rel"); fs.mkdir(d .. "/tmp")
    fs.write(d .. "/rel/" .. ASSET, "binary bytes " .. n .. "\n")
    fs.write(d .. "/tmp/" .. ASSET, "binary bytes " .. n .. "\n")
    local sum = sha_of(W.abs .. "/c" .. n .. "/rel/" .. ASSET)
    if opts.sums ~= "absent" then
        local line = (opts.sums == "wrong" and string.rep("0", 64) or sum) .. "  " .. (opts.sums == "unlisted" and "other-asset" or ASSET)
        fs.write(d .. "/rel/SHA256SUMS", line .. "\n")
    end
    local abs = W.abs .. "/c" .. n
    local script = table.concat({
        "set -euo pipefail",
        "say() { printf '  %s\\n' \"$*\"; }",
        "die() { printf '  ERROR: %s\\n' \"$*\" >&2; exit 1; }",
        'ASSET="' .. ASSET .. '"',
        'RELEASE_BASE="file://' .. abs .. '/rel"',
        'TMPDIR_TILLANDSIAS="' .. abs .. '/tmp"',
        'BINARY_TMP="$TMPDIR_TILLANDSIAS/$ASSET"',
        'CHECKSUMS_TMP="$TMPDIR_TILLANDSIAS/SHA256SUMS"',
        'CHECKSUM_ONE="$TMPDIR_TILLANDSIAS/SHA256SUMS.$ASSET"',
        BLOCK,
        "echo proceeded", "" }, "\n")
    local env_ = { PATH = toolbin("c" .. n, opts.sha256sum ~= false, opts.shasum ~= false) }
    if opts.override then env_.TILLANDSIAS_INSTALL_UNVERIFIED = "1" end
    local r = T:run{ SH_ABS, "-s", stdin = script, env = env_, env_unset = { "TILLANDSIAS_INSTALL_UNVERIFIED" } }
    local o = (r.stdout or "") .. (r.stderr or "")
    return { ok = text.contains(r.stdout or "", "proceeded"), out = o, err = r.stderr or "", code = r.code }
end

local function show(c) if c.code == nil then T:refuse("spawn", c.out) end return "rc=" .. tostring(c.code) .. " " .. c.out:gsub("\n", " | ") end
local function plain_refusal(c)
    local errs = 0
    for _, l in ipairs(text.lines(c.err)) do if l:find("ERROR:", 1, true) then errs = errs + 1 end end
    return not c.ok and errs == 1 and not c.out:lower():find("skipping", 1, true)
end

local h = case{ sums = "ok" }
T:arm("H HEALTHY a matching checksum proceeds", h.ok and h.code == 0, show(h))
local m = case{ sums = "wrong" }
T:arm("M MISMATCH a wrong checksum stops", not m.ok and m.code ~= 0, show(m))
local ab = case{ sums = "absent" }
T:arm("A ABSENT no SHA256SUMS is refused, saying nothing was installed", not ab.ok and ab.code ~= 0
    and text.contains(ab.err, "nothing was installed") and not text.contains(ab.out, "TILLANDSIAS_"), show(ab))
local u = case{ sums = "unlisted" }
T:arm("U UNLISTED an asset missing from SHA256SUMS is refused", not u.ok and u.code ~= 0, show(u))
local s = case{ sums = "ok", sha256sum = false }
T:arm("S SHASUM without sha256sum, shasum verifies and proceeds", s.ok and s.code == 0, show(s))
local s2 = case{ sums = "wrong", sha256sum = false }
T:arm("S2 SHASUM a wrong checksum through shasum still stops", not s2.ok and s2.code ~= 0, show(s2))
local nt = case{ sums = "ok", sha256sum = false, shasum = false }
T:arm("N NO-TOOL neither tool is refused", not nt.ok and nt.code ~= 0, show(nt))
local ov = case{ sums = "absent", override = true }
T:arm("O OVERRIDE TILLANDSIAS_INSTALL_UNVERIFIED=1 proceeds and says it did not verify", ov.ok
    and ov.out:lower():find("not verified", 1, true) ~= nil, show(ov))
T:arm("P PLAIN each refusal is one ERROR line, never 'skipping'",
    plain_refusal(ab) and plain_refusal(u) and plain_refusal(nt), show(ab) .. " // " .. show(u) .. " // " .. show(nt))

T:finish()

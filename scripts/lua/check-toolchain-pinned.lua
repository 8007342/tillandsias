-- @env TILLANDSIAS_TOOLCHAIN_PIN_ROOT
-- @read-env TILLANDSIAS_TOOLCHAIN_PIN_ROOT
-- @trace order:1562-tc7p
--
-- check-toolchain-pinned.lua — every build reads ONE pinned Rust toolchain.
--
-- WHY. v56.10.8.1's macOS release job installed `toolchain: stable`, which had
-- moved to rustc 1.99.0 on 2026-09-28. The darwin host gated on 1.96.1 and the
-- Nix release build on 1.98.0 (rust-overlay's `stable.latest` at its lock), and
-- 1.99 denies a declaration all of them accepted, so the cut failed after every
-- gate passed (PR #256). Three builds, three compilers, and no gate measured
-- the one that shipped.
--
-- WHAT IT REFUSES, each naming the file and line:
--   * rust-toolchain.toml missing, or `channel` not an exact X.Y.Z;
--   * a `toolchain:` input in .github/workflows/*.yml that is not read from
--     the pin (`${{ steps.rust-pin.outputs.channel }}`) — `stable`, `beta`,
--     `nightly` and a hand-copied version all drift;
--   * flake.nix selecting `rust-bin.<channel>.latest`, or not reading
--     rust-toolchain.toml;
--   * a build script that does not consult rust-toolchain.toml
--     (scripts/build-macos-tray.sh, scripts/build-windows-tray.ps1).
--
-- The optional root is a fixture seam (scripts/test-check-toolchain-pinned.sh).
--
-- Verdicts:
--   ok:toolchain-pinned:<version>:workflow-sites=<n>
--   violation:toolchain-floats:<n> site(s) — one `violation:toolchain-floats:<path>:<line>:<why>` line each
local root = env.get("TILLANDSIAS_TOOLCHAIN_PIN_ROOT") or ""
local function path(p) return root == "" and p or root .. "/" .. p end
local function read(p)
    local ok, s = pcall(fs.read, path(p))
    if ok then return s end
    return nil
end
local function raw_lines(s)
    local out = {}
    for line in (s .. "\n"):gmatch("(.-)\n") do out[#out + 1] = line end
    if s:sub(-1) == "\n" then out[#out] = nil end
    return out
end

local PIN_FILE = "rust-toolchain.toml"
local PIN_EXPR = "${{ steps.rust-pin.outputs.channel }}"
local violations = {}
local function refuse(where, why) violations[#violations + 1] = where .. ":" .. why end

-- 1. The single source.
local pin = nil
local toml = read(PIN_FILE)
if not toml then
    refuse(PIN_FILE .. ":0", "missing — the single source of the build toolchain")
else
    for n, line in ipairs(raw_lines(toml)) do
        local v = line:match('^%s*channel%s*=%s*"([^"]*)"')
        if v then
            if v:match("^%d+%.%d+%.%d+$") then
                pin = v
            else
                refuse(PIN_FILE .. ":" .. n, "channel '" .. v .. "' floats — pin an exact X.Y.Z")
            end
        end
    end
    if not pin and #violations == 0 then
        refuse(PIN_FILE .. ":0", "no `channel = \"X.Y.Z\"` line")
    end
end

-- 2. Every workflow toolchain input reads the pin.
local workflow_sites = 0
local ok_walk, workflows = pcall(fs.walk, path(".github/workflows"), { suffix = ".yml" })
if not ok_walk or #workflows == 0 then
    refuse(".github/workflows:0", "no workflow files found — the guard cannot see the release toolchain and refuses rather than pass blind")
else
    for _, f in ipairs(workflows) do
        local src = read(root == "" and f or f:sub(#root + 2)) or fs.read(f)
        local shown = root == "" and f or f:sub(#root + 2)
        for n, line in ipairs(raw_lines(src)) do
            if not line:match("^%s*#") then
                local v = line:match("^%s*toolchain:%s*(.-)%s*$")
                if v then
                    workflow_sites = workflow_sites + 1
                    if v ~= PIN_EXPR then
                        refuse(shown .. ":" .. n, "toolchain '" .. v .. "' is not read from " .. PIN_FILE .. " (want " .. PIN_EXPR .. ")")
                    end
                end
            end
        end
    end
end

-- 3. The Nix (Linux release) toolchain.
local flake = read("flake.nix")
if not flake then
    refuse("flake.nix:0", "missing — the Linux release toolchain cannot be checked")
else
    local reads_pin = false
    for n, line in ipairs(raw_lines(flake)) do
        if not line:match("^%s*#") then
            if line:find("rust%-bin%.[%w_]+%.latest") then
                refuse("flake.nix:" .. n, "selects `rust-bin.<channel>.latest`, which floats with the rust-overlay lock")
            end
            if line:find("./" .. PIN_FILE, 1, true) then reads_pin = true end
        end
    end
    if not reads_pin then
        refuse("flake.nix:0", "does not read ./" .. PIN_FILE)
    end
end

-- 4. The platform build scripts consult the pin.
for _, script in ipairs({ "scripts/build-macos-tray.sh", "scripts/build-windows-tray.ps1" }) do
    local src = read(script)
    if not src then
        refuse(script .. ":0", "missing")
    elseif not src:find(PIN_FILE, 1, true) then
        refuse(script .. ":0", "never reads " .. PIN_FILE .. ", so it builds on whatever rustc is first on PATH")
    end
end

if #violations > 0 then
    for _, v in ipairs(violations) do out.line("violation:toolchain-floats:" .. v) end
    log.raw("[check-toolchain-pinned] every build must use the ONE toolchain pinned in " .. PIN_FILE .. " (1562-tc7p). Moving the pin is a deliberate PR: change `channel`, bump the rust-overlay lock if needed, and gate it on every platform.")
    verdict.emit(("violation:toolchain-floats:%d site(s)"):format(#violations), 1)
end
verdict.emit(("ok:toolchain-pinned:%s:workflow-sites=%d"):format(pin, workflow_sites), 0)

-- @trace spec:forge-as-only-runtime, order:444, order:1598-kgra
--
-- check-launch-artifacts-untracked.lua — no agent-harness launch write may
-- land on a TRACKED checkout path (order 444). OpenCode's npm install
-- regenerated the TRACKED .opencode/package-lock.json on every launch,
-- dirtying the shared checkout (cross-forge dirt, 2026-07-20).
--
--   1. Every KNOWN launch artifact (manifest below) must be UNTRACKED and
--      GITIGNORED, so it can never be accidentally re-added.
--   2. The harness entrypoints are scanned for write idioms into per-harness
--      checkout dirs; any write target not covered by the manifest or by
--      .gitignore fails loud, demanding a manifest entry. New launch artifacts
--      are declared, not discovered as dirt.
--
-- PORTED from the shell check of the same name (1598-kgra), rule
-- for rule. Output:
--   ok:launch-artifacts-untracked                      exit 0 (byte-identical;
--                                                      the litmus reads it)
--   fail:(tracked|unignored|unmanifested)-launch-artifact:<path>, then
--   violation:launch-artifacts-untracked:<kind>:<path> exit 1
-- The .sh ended on the fail: line. Nothing reads it, and the runner's verdict
-- grammar has no fail: prefix, so the same fail: line is printed unchanged and
-- a violation: verdict follows it.
--
-- Usage: tillandsias-plan script run scripts/lua/check-launch-artifacts-untracked.lua [-- <root>]
--   <root> is a checkout-relative directory to judge instead of the checkout
--   (the fixture's scratch repos live under target/plan-scratch).

local ROOT = arg[1] or "."
local function at(p) return ROOT == "." and p or (ROOT .. "/" .. p) end
local function git(args)
    local argv = { "git", "-C", ROOT }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 30000 })
    return r.status == "exited" and r.code == 0
end

-- Checkout-relative paths harness launches write on every start.
local LAUNCH_ARTIFACTS = {
    ".opencode/package-lock.json",
    ".opencode/node_modules",
    ".forge-startup-context.md",
}

local function fail(why, kind, path)
    out.line("fail:" .. kind .. "-launch-artifact:" .. path)
    verdict.emit("violation:launch-artifacts-untracked:" .. kind .. ":" .. path, 1, why)
end

for _, p in ipairs(LAUNCH_ARTIFACTS) do
    if git({ "ls-files", "--error-unmatch", p }) then
        fail("Launch artifact '" .. p .. "' is TRACKED — every forge start would dirty the checkout (order 444).", "tracked", p)
    end
    if not git({ "check-ignore", "-q", p }) then
        fail("Launch artifact '" .. p .. "' is not gitignored — a routine 'git add -A' would re-track it (order 444).", "unignored", p)
    end
end

-- Discovery: write idioms in the forge entrypoints that target per-harness
-- dirs inside the checkout, in the .sh's order (entrypoint-forge-*.sh sorted,
-- then lib-common.sh). Comments are stripped; matches report file:line.
local WRITE = [=[(^|[^#])((>|>>)[[:space:]]*"?\$?[A-Za-z_{}"]*/?\.(opencode|codex|claude|gemini)/|npm (install|ci)[^#]*\.(opencode|codex|claude|gemini)/)]=]
local TOKEN = [=[(\.(?:opencode|codex|claude|gemini)/[A-Za-z0-9._/-]+)]=]
local files = {}
for _, f in ipairs(fs.walk(at("images/default"))) do
    local name = f:match("[^/]+$") or ""
    if name:match("^entrypoint%-forge%-.*%.sh$") and not f:sub(#at("images/default") + 2):find("/", 1, true) then
        files[#files + 1] = f
    end
end
table.sort(files)
files[#files + 1] = at("images/default/lib-common.sh")

local unmanifested = {}
for _, f in ipairs(files) do
    local okr, body = pcall(fs.read, f)
    if okr and body then
        local shown = ROOT == "." and f or f:sub(#ROOT + 2)
        for n, line in ipairs(text.lines(body)) do
            if text.is_match(line, WRITE) then
                local hit = (shown .. ":" .. n .. ":" .. line):gsub("%s*#.*$", "")
                local token = text.captures_all(hit, TOKEN)[1]
                if token and token ~= "" then
                    local covered = false
                    for _, p in ipairs(LAUNCH_ARTIFACTS) do
                        if token == p or token:sub(1, #p + 1) == p .. "/" then covered = true; break end
                    end
                    if not covered and git({ "check-ignore", "-q", token }) then covered = true end
                    if not covered then unmanifested[#unmanifested + 1] = { where = shown .. ":" .. n, token = token } end
                end
            end
        end
    end
end

if #unmanifested > 0 then
    local lines = {}
    for _, u in ipairs(unmanifested) do lines[#lines + 1] = u.where .. " writes " .. u.token end
    fail(table.concat(lines, "\n") .. "\nAdd the path(s) to LAUNCH_ARTIFACTS in this script AND .gitignore, or stop writing into the checkout (order 444).",
        "unmanifested", unmanifested[1].token)
end

verdict.emit("ok:launch-artifacts-untracked", 0)

-- @trace order:1505-42zx, order:1595-pvju
--
-- test-configure-codex.lua — PORTED from test-configure-codex.sh (1595-pvju).
-- ORDER 1505-42zx: scripts/configure-codex.sh no longer prompts for a host
-- GitHub token. Its help advertises --check, --launch and --login-codex but
-- not --seed-github-token; the removed mode stops at usage during parsing,
-- before git, a terminal, stdin or a credential command; no token-seeding path
-- remains in the launcher; and device login and the namespaced launch still
-- dispatch through `tillandsias`.
--
-- The .sh matched with `rg`; this port matches in Lua, so the fixture no longer
-- needs ripgrep on the host.
--
--   1 LAUNCHER  every check above, on configure-codex.sh (or the launcher
--               named as the first argument, as the .sh accepted)
--   2 MUTANT    a copy that still advertises and parses --seed-github-token
--               is refused, so these checks can fail
--   3 READERS   the .sh's retired FAIL: lines have no reader in scripts/, the
--               gate steps or the litmus specs; the count searched is printed
--
-- Terminal line, unchanged because the litmus expects it byte for byte:
-- ok:configure-codex:no-token-prompt, or refused:configure-codex:<failed>.
--
-- Usage: tillandsias-plan script run scripts/lua/test-configure-codex.lua [-- <launcher>]

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
local LAUNCHER = arg[1] or "scripts/configure-codex.sh"
local REL = "target/plan-scratch/configure-codex-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
fs.mkdir(REL)
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return s:find(sub, 1, true) ~= nil end
local function any_line_starts(s, prefix)
    for _, l in ipairs(text.lines(s)) do
        if l:sub(1, #prefix) == prefix then return true end
    end
    return false
end

-- Every check the .sh made, on one launcher; returns the failures.
local function judge(path)
    local why = {}
    local abs = path:sub(1, 1) == "/" and path or (ROOT .. "/" .. path)
    local help = proc.run({ argv = { "bash", abs, "--help" }, timeout_ms = 30000 })
    local h = help.stdout or ""
    if help.code ~= 0 then why[#why + 1] = "launcher help did not succeed" end
    if has(h, "--seed-github-token") then why[#why + 1] = "rejected token-seeding mode is advertised" end
    for _, mode in ipairs({ "--check", "--launch", "--login-codex" }) do
        if not has(h, mode) then why[#why + 1] = "missing launcher mode " .. mode end
    end
    -- The old mode must stop at usage while parsing, before git, a terminal,
    -- stdin or a credential command.
    local rej = proc.run({ argv = { "bash", abs, "--seed-github-token" }, timeout_ms = 30000 })
    local e = rej.stderr or ""
    if rej.code == 0 then why[#why + 1] = "rejected mode succeeded" end
    if not any_line_starts(e, "Usage: ") then why[#why + 1] = "rejected mode did not stop at usage" end
    if has(e, "GitHub token for this host") or has(e, "Token entry requires") then
        why[#why + 1] = "rejected mode reached credential handling"
    end
    local src = fs.read(path) or ""
    if has(src, "seed-github-token") or has(src, "read -r -s token") or has(src, "--github-login --with-token") then
        why[#why + 1] = "credential-seeding path remains in launcher"
    end
    if not (has(src, "exec tillandsias --codex-login") and has(src, "export TILLANDSIAS_FORGE_INSTANCE=")
        and has(src, 'exec tillandsias "$root" --codex')) then
        why[#why + 1] = "device-login or namespaced launch dispatch changed"
    end
    return why
end

local w = judge(LAUNCHER)
if #w == 0 then ok(LAUNCHER .. ": no token prompt, the removed mode stops at usage, and device login and launch dispatch are intact")
else bad(LAUNCHER .. ": " .. table.concat(w, "; ")) end

-- 2: a launcher that still offers the removed mode must be refused.
local real = fs.read("scripts/configure-codex.sh") or ""
local mutant = real:gsub("  %-%-login%-codex ", "  --seed-github-token  Prompt for a GitHub token (removed)\n  --login-codex ", 1)
mutant = mutant:gsub("\n", '\ncase "${1:-}" in --seed-github-token) echo "GitHub token for this host:" >&2; exit 0 ;; esac\n', 1)
fs.write(REL .. "/configure-codex.sh", mutant)
local mw = judge(REL .. "/configure-codex.sh")
if #mw >= 2 then ok("a mutant launcher that still offers --seed-github-token is refused (" .. table.concat(mw, "; ") .. ")")
else bad("the mutant launcher was not refused: " .. table.concat(mw, "; ")) end

-- 3: the retired FAIL: lines, assembled so this file cannot match itself.
local NEEDLES = { "FA" .. "IL: launcher help did not succeed", "FA" .. "IL: rejected mode did not stop at usage" }
local SELF = "scripts/lua/test-configure-codex.lua"
local searched, hits = 0, {}
for _, root in ipairs({ "scripts", "openspec/litmus-tests" }) do
    for _, f in ipairs(fs.walk(root)) do
        if f ~= SELF and (f:sub(-3) == ".sh" or f:sub(-4) == ".lua" or f:sub(-5) == ".step" or f:sub(-5) == ".yaml") then
            searched = searched + 1
            local okr, body = pcall(fs.read, f)
            if okr and body then
                for _, n in ipairs(NEEDLES) do
                    if has(body, n) then hits[#hits + 1] = f; break end
                end
            end
        end
    end
end
if #hits == 0 and searched > 100 then
    ok("the retired FAIL: lines have 0 readers (" .. searched .. " files searched: scripts/, gate steps, litmus specs)")
else
    bad("readers of the retired FAIL: lines: " .. #hits .. " in " .. searched .. " files: " .. table.concat(hits, ", "))
end

proc.run({ argv = { "rm", "-rf", ROOT .. "/" .. REL } })
if failed == 0 then verdict.emit("ok:configure-codex:no-token-prompt", 0) end
verdict.emit("refused:configure-codex:" .. failed, 1)

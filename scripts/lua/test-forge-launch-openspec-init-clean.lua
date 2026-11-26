-- @trace plan/issues/forge-opsx-skill-sync-dirties-checkout-2026-07-31.md (order 1422-w3p8)
-- @trace order:2333-rqjn
--
-- test-forge-launch-openspec-init-clean.lua — openspec_init_if_absent
-- (images/default/lib-common.sh): a forge launch lands on a clean checkout
-- (operator ruling 2026-09-27). Every entrypoint ran `openspec init` with a CLI
-- refreshed to @latest, so the first launch after a release rewrote the committed
-- /opsx set. Ported from the .sh (2333-rqjn).
--
-- The stub CLI behaves like a NEWER openspec: init for a tool rewrites that tool's
-- set, bare init rewrites every configured tool.
--   1 the pre-fix call dirties the tree (control); the helper leaves it clean
--   2 an absent set is still generated, as new files only
--   3 no CLI, or no project dir, is a silent no-op
--   4 every forge entrypoint routes through the helper
--   5 (optional) the real openspec CLI, when the host has one
--
-- Verdict: ok:forge-launch-openspec-init-clean | violation:forge-launch-openspec-init-clean:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("forge-launch-openspec-init-clean")
local SH = fixture.posix_shell()
local W = T:scratch()
local DROP = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }

-- Only the function under test: lib-common.sh as a whole sets up a container.
local lib = "\n" .. fs.read("images/default/lib-common.sh")
local fn = lib:match("\n(openspec_init_if_absent%(%).-\n}\n)")
if not fn then T:refuse("no-subject", "openspec_init_if_absent is not in images/default/lib-common.sh") end
fs.write(W.rel .. "/launch.sh", 'set -uo pipefail\ntrace_lifecycle() { :; }\n' .. fn .. 'OS_BIN="$1"; shift\nopenspec_init_if_absent "$@"\n')
fs.write(W.rel .. "/openspec", [==[#!/usr/bin/env bash
[ "${1:-}" = init ] || exit 2
gen() {
    case "$1" in
        claude)   mkdir -p .claude/commands/opsx .claude/skills/openspec-explore
                  echo 'generatedBy: "NEW"' > .claude/commands/opsx/explore.md
                  echo 'generatedBy: "NEW"' > .claude/skills/openspec-explore/SKILL.md ;;
        opencode) mkdir -p .opencode/commands .opencode/skills/openspec-explore
                  echo 'generatedBy: "NEW"' > .opencode/commands/opsx-explore.md
                  echo 'generatedBy: "NEW"' > .opencode/skills/openspec-explore/SKILL.md ;;
    esac
    mkdir -p openspec; [ -e openspec/config.yaml ] || echo 'schema: x' > openspec/config.yaml
}
if [ "${2:-}" = --tools ]; then gen "$3"; exit 0; fi
n=0
[ -d .claude/commands/opsx ] && { gen claude; n=1; }
[ -d .opencode/commands ] && { gen opencode; n=1; }
[ "$n" = 1 ] || { echo "No tools detected. Use --tools" >&2; exit 1; }
]==])
local STUB = W.abs .. "/openspec"
T:must{ "chmod", "+x", STUB }

local function git(d, ...)
    return T:must{ "git", "-C", d.abs, "-c", "user.email=t@example.invalid", "-c", "user.name=t", "-c", "commit.gpgsign=false", ... }
end
-- A checkout whose committed /opsx sets came from an OLDER CLI.
local function repo(name)
    local d = { rel = W.rel .. "/" .. name, abs = W.abs .. "/" .. name }
    for _, f in ipairs({ ".claude/commands/opsx/explore.md", ".claude/skills/openspec-explore/SKILL.md",
        ".opencode/commands/opsx-explore.md", ".opencode/skills/openspec-explore/SKILL.md" }) do
        fs.mkdir(d.rel .. "/" .. f:match("^(.*)/"))
        fs.write(d.rel .. "/" .. f, 'generatedBy: "OLD"\n')
    end
    fs.mkdir(d.rel .. "/openspec")
    fs.write(d.rel .. "/openspec/config.yaml", "schema: x\n")
    T:must{ "git", "init", "-q", d.abs }
    git(d, "add", "-A"); git(d, "commit", "-qm", "init")
    return d
end
local function dirt(d, untracked) return (text.trim(git(d, "status", "--porcelain", "--untracked-files=" .. (untracked or "all")).stdout or "")) end
local function launch(bin, ...)
    local a = { SH, W.abs .. "/launch.sh", bin, cwd = W.abs, env_unset = DROP, timeout_ms = 60000 }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    local r = T:run(a)
    return r.code, "rc=" .. tostring(r.code) .. " " .. (r.stdout or "") .. (r.stderr or "")
end

local pre = repo("prefix")
T:run{ SH, STUB, "init", "--tools", "claude", cwd = pre.abs, env_unset = DROP, timeout_ms = 20000 }
T:arm("1 CONTROL the pre-fix call dirties the checkout", dirt(pre) ~= "", "the stub did not reproduce the launch dirt")
for _, tool in ipairs({ "claude", "opencode", "" }) do
    local d = repo("fixed-" .. (tool == "" and "bare" or tool))
    local c, said
    if tool == "" then c, said = launch(STUB, d.abs) else c, said = launch(STUB, d.abs, tool) end
    local after = dirt(d)
    T:arm("1 a " .. (tool == "" and "bare" or tool) .. " launch leaves the checkout clean", c == 0 and after == "", said .. " | " .. after)
end

local d = repo("absent")
git(d, "rm", "-rq", ".opencode"); git(d, "commit", "-qm", "drop")
local c, said = launch(STUB, d.abs, "opencode")
T:arm("2 an absent set is generated", c == 0 and fs.exists(d.rel .. "/.opencode/commands/opsx-explore.md"), said)
T:arm("2 generating it modifies no tracked file", dirt(d, "no") == "", dirt(d, "no"))

local before = dirt(pre)
c, said = launch("", pre.abs, "claude")
T:arm("3 a missing CLI is a no-op", c == 0 and said == "rc=0 " and dirt(pre) == before, said)
c, said = launch(STUB, "", "claude")
T:arm("3 an empty project dir is a no-op", c == 0 and said == "rc=0 ", said)

for _, ep in ipairs({ "entrypoint-forge-claude.sh", "entrypoint-forge-opencode.sh", "entrypoint-forge-opencode-web.sh", "entrypoint-terminal.sh" }) do
    local s = fs.read("images/default/" .. ep)
    local direct = s:find('"%$OS_BIN"%s+init') or s:find('"%$OS_BIN"%s+update')
    T:arm("4 " .. ep .. " goes through the helper", s:find('openspec_init_if_absent "$PROJECT_DIR"', 1, true) ~= nil and not direct,
        direct and "runs openspec init/update directly" or "does not call openspec_init_if_absent")
end

local cli = fixture.which("openspec")
if cli then
    local r = { rel = W.rel .. "/real", abs = W.abs .. "/real" }
    T:must{ "git", "init", "-q", r.abs }
    local init = T:run{ cli, "init", "--tools", "claude", cwd = r.abs, env_unset = DROP, timeout_ms = 120000 }
    -- Age the committed set, so any rewrite shows as a diff.
    local aged = 0
    for _, f in ipairs(fs.walk(r.rel .. "/.claude/skills") or {}) do
        if f:match("/openspec%-[^/]*/SKILL%.md$") then
            fs.write(f, (fs.read(f):gsub('generatedBy: "[^"]*"', 'generatedBy: "0.0.0"'))); aged = aged + 1
        end
    end
    git(r, "add", "-A"); git(r, "commit", "-qm", "init")
    launch(cli, r.abs, "claude"); launch(cli, r.abs, "")
    T:arm("5 the real openspec CLI leaves the checkout clean", init.code == 0 and aged > 0 and dirt(r) == "", "init rc=" .. tostring(init.code) .. " aged=" .. aged .. " " .. dirt(r):sub(1, 200))
else
    out.line("skip:case5:no-openspec-cli")
end
T:finish({ ok = function() return "ok:forge-launch-openspec-init-clean" end })

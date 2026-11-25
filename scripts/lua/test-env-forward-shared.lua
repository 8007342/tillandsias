-- @trace order:891-5shq, order:2312-d2gf
--
-- test-env-forward-shared.lua — the TILLANDSIAS_* namespace forward has ONE
-- implementation (scripts/lib-env-forward.sh), does not manufacture values, and
-- is not re-implemented per boundary. Ported from the .sh (2312-d2gf).
--
-- Neither `toolbox run` nor `wsl.exe` forwards the caller's environment, so each
-- TILLANDSIAS_* flag died silently at a dispatch. The toolbox boundary was
-- fixed, then the WSL one got its own copy of the same four lines: a third could
-- diverge silently the same way.
--
--   1 a set flag is carried
--   2 NEGATIVE CONTROL an unset flag is not manufactured ("forwards correctly"
--     and "exports everything" differ only here); an EMPTY-but-set one crosses
--   3 a value survives verbatim and is data, not a command (the fragment is
--     evaluated by a remote shell)
--   4 both dispatches reach the shared helper and neither rolls its own loop
--   5 arm 4's detector reds on a re-introduced copy
--
-- Verdict: ok:env-forward-shared:10 arm(s) | violation:env-forward-shared:<n> arm(s) failed

local fixture = require "common.fixture"
local T = fixture.new("env-forward-shared")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()

-- The caller's own TILLANDSIAS_* names are dropped, so only the four below (and
-- never NEVER_SET) can be in the fragment.
fs.write(W.rel .. "/near.sh", '. "$1"\nexport TILLANDSIAS_FIXTURE_SET=1 TILLANDSIAS_FIXTURE_EMPTY=\n'
    .. "export TILLANDSIAS_FIXTURE_TRICKY='a b; touch pwned'\ntillandsias_env_forward_prefix\n")
local near = T:run{ SH, W.abs .. "/near.sh", ROOT .. "/scripts/lib-env-forward.sh", cwd = W.abs,
    env_unset = { "TILLANDSIAS_*" }, timeout_ms = 20000 }
local frag = near.stdout or ""
local function has(s, w) return s:find(w, 1, true) ~= nil end
T:arm("1 a set flag is carried", near.code == 0 and has(frag, "TILLANDSIAS_FIXTURE_SET=1"), frag .. (near.stderr or ""))
T:arm("2 NEGATIVE CONTROL an unset flag is not manufactured", near.code == 0 and not has(frag, "TILLANDSIAS_FIXTURE_NEVER_SET"), frag)
T:arm("2 an empty-but-SET flag still crosses", has(frag, "TILLANDSIAS_FIXTURE_EMPTY="), frag)

-- The far side: a fresh shell that evaluates the fragment.
fs.write(W.rel .. "/far.sh", frag .. 'printf "%s" "$TILLANDSIAS_FIXTURE_TRICKY"\n')
local far = T:run{ SH, W.abs .. "/far.sh", cwd = W.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 20000 }
T:arm("3 the value survives verbatim", far.stdout == "a b; touch pwned", "[" .. tostring(far.stdout) .. "]")
T:arm("3 the value is data, not a command", far.code == 0 and not fs.exists(W.rel .. "/pwned"), "rc=" .. tostring(far.code))

local function rolls_own(s) return s:find("compgen %-v%s*|%s*grep") ~= nil end
local wsl = ""
for _, d in ipairs({ "with-wsl2-builder.sh", "with-tillandsias-builder.sh" }) do
    local s = fs.read("scripts/" .. d)
    if d == "with-wsl2-builder.sh" then wsl = s end
    T:arm("4 " .. d .. " uses the shared helper", has(s, "lib-env-forward.sh"), "no lib-env-forward.sh in it")
    T:arm("4 " .. d .. " does not roll its own", not rolls_own(s), "a compgen loop")
end
T:arm("5 CONTROL the detector catches a re-introduced copy", rolls_own(wsl
    .. '\n_MINE=""\nwhile IFS= read -r v; do _MINE="${_MINE}export $v=${!v}; "; done < <(compgen -v | grep \'^TILLANDSIAS_\')\n'), "not caught")

T:finish({ ok = function(n) return "ok:env-forward-shared:" .. n .. " arm(s)" end,
    fail = function(n) return "violation:env-forward-shared:" .. n .. " arm(s) failed" end })

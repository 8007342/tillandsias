-- @env PATH HOME
-- inputs: Cargo.toml images/default/lib-common.sh methodology.yaml plan/index.yaml README.md scripts/allocate-gate-step-prefix.sh scripts/attest-native-lint.sh scripts/build-sidecar.sh scripts/check-credential-channel.sh scripts/check-host-tools.sh scripts/check-litmus-pin-claims.sh scripts/check-native-lint-attested.sh scripts/check-script-exec-bits.sh scripts/gate-stamp.sh scripts/gate-steps.d/README.md scripts/hooks/pre-push-linux-next-merged.sh scripts/hooks/pre-push-local-gate.sh scripts/land-on-platform-branch.sh scripts/litmus-covering-specs.sh scripts/lua/check-fragment-status-loss.lua scripts/lua/check-oom-postmortem.lua scripts/lua/check-unrunnable-platform-arms.lua scripts/lua/test-gate-stamp.lua scripts/lua/test-gate-stamp-portable-digest.lua scripts/lua/test-gate-step-append-no-conflict.lua scripts/lua/test-land-auth-retry.lua scripts/lua/test-land-push-bounded.lua scripts/lua/test-mode-only-regression-887-bz88.lua scripts/plan-binary-probe.sh scripts/run-litmus-test.sh scripts/salvage-dirty-worktree.sh scripts/test-gate-stamp-memoization.sh VERSION lib/lua/common/ crates/tillandsias-plan/
-- @trace order:1174-u5wp, order:1056-5344, order:1524-jnby, order:2331-8emp
--
-- test-land-adopts-valid-stamp.lua — land-on-platform-branch.sh adopts a gate stamp only when
-- it covers what is pushed. Ported from the .sh of the same name (2331-8emp). The DECISION block is
-- cut from the shipped tool and run under the tool's own options (1175-wuwr) with git and
-- gate-stamp.sh stubbed: no arm runs a gate, pushes, or runs the land tool.
--
--   1 a green full stamp is adopted, and the verdict names its time
--   2 a stamp older than the tree is not          3 a scope missing a pushed class is not
--   4 un-gated union debt vetoes adoption (1056-5344)
--   5 the gate call is guarded by the adoption    6 so is the gate-failed branch
--   7 a scope covering every pushed class is      8 an empty push diff is never covered
--
-- Usage: tillandsias-plan script run scripts/lua/test-land-adopts-valid-stamp.lua
-- Verdict: ok:land-adopts-valid-stamp:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("land-adopts-valid-stamp")
local SH = fixture.posix_shell()
local TOOL = fs.read("scripts/land-on-platform-branch.sh"):gsub("\r", "")
-- From the line `open` to the next line that is exactly four spaces and `fi`.
local function block(open)
    local a = TOOL:find("\n" .. open .. "\n", 1, true)
    local _, z = TOOL:find("\n    fi\n", a or 1, true)
    return a and z and TOOL:sub(a + 1, z) or nil
end
local DECISION = block('    _adopted=""')
if not DECISION then T:refuse("extraction-empty", "the markers moved") end

local STAMP = "2026-01-01T00:00:00Z"
local function drive(debt, verify, scope, paths)
    local d = T:scratch()
    fs.mkdir(d.rel .. "/scripts"); fs.mkdir(d.rel .. "/gitdir")
    fs.write(d.rel .. "/block.sh", DECISION)
    fs.write(d.rel .. "/paths", paths or "")
    fs.write(d.rel .. "/um", debt and "a union record\n" or "")
    fs.write(d.rel .. "/gitdir/tillandsias-gate-stamp", "version 2\ndigest deadbeef\nscope full\nstamped " .. STAMP .. "\n")
    fs.write(d.rel .. "/scripts/gate-stamp.sh", '#!/usr/bin/env bash\ncase "$1" in\n  verify) echo "' .. verify .. '" ;;\n  scope) echo "' .. scope .. '" ;;\n'
        .. '  classify) while IFS= read -r p; do case "$p" in "") ;; crates/*) echo rust ;; scripts/*) echo build-scripts ;; plan/*) echo plan-ledger ;; *) echo other ;; esac; done ;;\nesac\n')
    fs.write(d.rel .. "/scripts/git", '#!/usr/bin/env bash\ncase "$1" in rev-parse) echo "' .. d.abs .. '/gitdir" ;; diff) cat "' .. d.abs .. '/paths" ;; esac\nexit 0\n')
    local r = T:run{ SH, "-s", cwd = d.abs, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 30000,
        stdin = 'chmod +x scripts/*\nexport PATH="$PWD/scripts:$PATH"\nset -uo pipefail\nattempt=1; BRANCH=linux-next; _um="$PWD/um"\n. ./block.sh\nprintf "ADOPTED=[%s]\\n" "${_adopted:-}"\n' }
    local o = (r.stdout or "") .. (r.stderr or "")
    return o, "rc=" .. tostring(r.code) .. " " .. o
end
local function not_adopted(name, ...)
    local o, why = drive(...)
    T:arm(name, text.contains(o, "ADOPTED=[]"), why)
end
local PARTIAL = "build-scripts,plan-ledger"
local o, why = drive(false, "ok:gate-fresh", "full")
T:arm("1a a green full stamp is adopted and the verdict names the token", text.contains(o, "ok:land-adopts-valid-stamp:"), why)
T:arm("1b the adoption names the stamp's time", text.contains(o, "ADOPTED=[" .. STAMP .. "]"), why)
not_adopted("2 NC a stamp older than the tree is not adopted", false, "stale:tree-changed-since-gate", "full")
not_adopted("3 NC a scope that misses a pushed class (rust) is not adopted", false, "ok:gate-fresh", PARTIAL, "scripts/x.sh\ncrates/demo/lib.rs\n")
not_adopted("4 NC un-gated union debt vetoes a green full stamp", true, "ok:gate-fresh", "full")
local guarded = block("    _gate_rc=0")
T:arm("5 the gate call is guarded by the adoption", guarded ~= nil and text.contains(guarded, 'if [ -z "$_adopted" ]; then'), guarded or "gate call not found")
T:arm("6 the gate-failed branch is scoped to attempts that gated", text.contains(TOOL, 'if [ -z "$_adopted" ] && [ "$_gate_rc" -ne 0 ]; then'), "guard not found")
o, why = drive(false, "ok:gate-fresh", PARTIAL, "scripts/x.sh\nplan/index.d/a.yaml\n")
T:arm("7 a scope covering every pushed class is adopted, naming the classes", text.contains(o, "ok:land-adopts-valid-stamp:")
    and text.contains(o, "covers every class this push carries: build-scripts plan-ledger") and text.contains(o, "ADOPTED=[" .. STAMP .. "]"), why)
not_adopted("8 NC an empty push diff is never covered", false, "ok:gate-fresh", PARTIAL, "")
T:finish()

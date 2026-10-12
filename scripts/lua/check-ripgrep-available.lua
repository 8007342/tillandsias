-- @trace order:1129-xm5z, order:527
--
-- check-ripgrep-available.lua — is ripgrep present on this host?
--
-- ONE LINE ON STDOUT, exit 0 either way. This is a PRESENCE PROBE, not a gate:
-- it answers a question and never refuses. Since 1570-k4fx the cheatsheet
-- reference checker (scripts/lua/check-cheatsheet-refs.lua) uses no rg at all;
-- whether this probe (and its check-host-tools.sh SPEC row) is still needed is
-- 1578-7s8h — if the answer is "not needed", delete THIS file and that row.
--
--   ok:rg:<version>   ripgrep resolves on PATH
--   skip:rg:missing   it does not
--
-- Ported from check-ripgrep-available.sh (the carried shell-to-lua item paid by
-- order 527). The absent token was `missing:rg`; a Lua decider must END on a
-- verdict, and `missing:` is not one, so it is now `skip:rg:missing` and its
-- one reader (the rg row's <expect> in check-host-tools.sh) moved with it.
--
-- WHY STDOUT AND WHY EXIT 0. scripts/test-host-tools.sh falsifies every
-- prover-backed row by hiding the tool and reading the prover's LAST STDOUT
-- LINE, then matching it against the row's <expect>. A prover that reports
-- absence on stderr, or exits non-zero, cannot be falsified by that arm.
--
-- proc.run resolves `rg` on the caller's PATH, which is exactly what that arm
-- farms without rg; a spawn failure is the absent answer.

local r = proc.run({ argv = { "rg", "--version" }, timeout_ms = 10000 })
if r.status ~= "exited" or r.code ~= 0 then
    verdict.skip("rg", "missing")
end
-- rg --version prints several lines; the row asserts presence, not a version
-- floor, so the second word of the first line is the whole answer.
local first = (r.stdout or ""):match("^[^\n]*") or ""
local version = first:match("^%S+%s+(%S+)")
verdict.ok("rg", version or "unknown")

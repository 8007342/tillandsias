-- @trace order:1219-dcma, order:975-rsgm, order:2301-2r4s, spec:enclave-network
--
-- test-enclave-remedy-covers-the-named-service.lua — the way out a guard prints
-- must work for the service it is complaining about. Ported from the .sh
-- (2301-2r4s).
--
-- THE DEFECT, measured on lenovinha 2026-09-16 by FOLLOWING the instruction: for
-- a dead tillandsias-inference the guard prescribed `tillandsias
-- --ensure-enclave`, which answered ok:enclave-ensured:proxy=running rc=0 and
-- left the service Exited(137). It ensures VAULT and PROXY only; the guard
-- counts five services.
--
-- ARMS 2 AND 3 ARE THE NEGATIVE CONTROLS. Disclaiming --ensure-enclave for every
-- class would leave a dead proxy with no stated way out, and re-legitimising
-- `podman start` would bring back 975-rsgm's failure, which names neither the
-- certificate nor the key.
--
-- Asserted against the guard's SOURCE, so the fixture has a verdict on a host
-- whose enclave is healthy, where no detail lines exist to classify.
--
-- Verdict: ok:enclave-remedy:<n> | violation:enclave-remedy:<n> |
--          skip:enclave-remedy:<guard> absent (exit 3)

local fixture = require "common.fixture"
local V = require "common.verdict"
local T = fixture.new("enclave-remedy")
local GUARD = "scripts/check-enclave-service-health.sh"
if not fs.exists(GUARD) then V.emit("skip:enclave-remedy:" .. GUARD .. " absent", 3) end
local src = fs.read(GUARD)
local function has(s) return src:find(s, 1, true) ~= nil end

T:arm("1 a service --ensure-enclave does NOT cover is named as uncovered",
    has("1219-dcma") and has("NOT COVERED BY THAT REMEDY") and has("VAULT and PROXY only"),
    "the guard prints one remedy for every class again; an operator following it for inference gets rc=0 and no change")
T:arm("2 CONTROL the original remedy survives for the classes it does cover",
    has("ensure-enclave") and has("idempotent"),
    "the original remedy was removed; a dead proxy now has no stated way out")
T:arm("3 CONTROL 'podman start' stays foreclosed, with 975-rsgm's reason",
    has("NOT 'podman start") and has("X509_check_private_key"),
    "the podman-start foreclosure or its measured reason was lost")
T:arm("4 the uncovered list is DERIVED from this run's detail lines, not hardcoded",
    src:find("sed %-n [^\n]s/%.%*:service=") ~= nil,
    "the uncovered set looks hardcoded; a service added later would be misclassified")
T:arm("5 rc=137 is not left to read as an OOM without a check", has("journalctl -k"),
    "rc=137 is presented without the check that tells an OOM from an external kill")
T:finish({ ok = function(n) return "ok:enclave-remedy:" .. n end, fail = function(n) return "violation:enclave-remedy:" .. n end })

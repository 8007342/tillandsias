-- @trace spec:runtime-diagnostics-stream, spec:logging-accountability
-- @trace order:525, order:2247-fb89
--
-- Fixture for the inference engine's pull-failure classifier. Ported whole
-- from scripts/test-inference-pull-failure-classification.sh (2247-fb89);
-- cases, assertions and verdict grammar unchanged.
--
-- THE DEFECT (order 525, exit criterion 3). A failed pull and an empty cache
-- both reached the agent as `inference_reason=no-models`, whose detail named
-- three causes at once. The one that mattered — the enclave CA not trusted by
-- ollama's Go TLS stack, so every pull through squid's bump failed x509
-- non-fatally — was indistinguishable from "nothing has been pulled yet".
--
-- WHAT IS PINNED: the classifier maps real engine output to stable tokens, and
-- in particular does not fold a TRUST failure into the generic bucket. The
-- strings below are the shapes Go's crypto/x509 and ollama actually emit.
--
-- Verdict grammar:
--   ok:pull-failure-classification:<n> passed   exit 0
--   violation:pull-failure-classification:<case> exit 1
--   blocked:<reason>                             exit 2

local fixture = require "common.fixture"
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local EP = "images/inference/entrypoint.sh"
if not fs.exists(EP) then verdict.emit("blocked:entrypoint-missing", 2) end

-- Extract only the two functions. Sourcing the entrypoint would start an engine.
local unit, inside = {}, false
for _, l in ipairs(text.lines(fs.read(EP) or "")) do
    if text.starts_with(l, "tillandsias_classify_pull_failure() {")
        or text.starts_with(l, "tillandsias_report_pull_failure() {") then inside = true end
    if inside then unit[#unit + 1] = l end
    if inside and text.starts_with(l, "}") then inside = false end
end
local UNIT = table.concat(unit, "\n") .. "\n"
if not UNIT:find("tillandsias_classify_pull_failure()", 1, true) then verdict.emit("blocked:extraction-failed", 2) end
if not UNIT:find("tillandsias_report_pull_failure()", 1, true) then verdict.emit("blocked:extraction-failed-report", 2) end

-- The unit is POSIX sh (the container entrypoint's dialect); posix_shell()
-- runs it, and the engine output travels in the environment, never quoted
-- into the script.
local function classify(s)
    local r = proc.run{ argv = { SH, "-s" }, cwd = ROOT, timeout_ms = 30000, env = { OUT = s },
        stdin = UNIT .. 'tillandsias_classify_pull_failure "$OUT"\n' }
    return text.trim(r.stdout or "")
end
local function report(s)
    local r = proc.run{ argv = { SH, "-s" }, cwd = ROOT, timeout_ms = 30000, env = { OUT = s },
        stdin = UNIT .. 'tillandsias_report_pull_failure "L" "M" "$OUT"\n' }
    return (r.stdout or "") .. (r.stderr or "")
end

local pass, fail = 0, {}
local function expect(label, want, output)
    local got = classify(output)
    if got == want then pass = pass + 1 else fail[#fail + 1] = label .. "(got:" .. got .. ")" end
end

-- The real shapes. Go's x509 wording differs from OpenSSL's, and ollama surfaces
-- both depending on where the failure happens, so both are pinned.
expect("tls-go", "pull-failed-tls-untrusted", "Error: pull model manifest: tls: failed to verify certificate: x509: certificate signed by unknown authority")
expect("tls-openssl", "pull-failed-tls-untrusted", "curl: (60) SSL certificate problem: unable to get local issuer certificate")
expect("tls-verify", "pull-failed-tls-untrusted", "Error: certificate verify failed")
expect("unreachable", "pull-failed-unreachable", 'Error: pull model manifest: Get "https://registry.ollama.ai/v2/": dial tcp: lookup registry.ollama.ai: no such host')
expect("refused", "pull-failed-unreachable", "Error: connection refused")
expect("notfound", "pull-failed-not-found", "Error: pull model manifest: file does not exist")
expect("other", "pull-failed-other", "Error: something entirely unexpected happened")

-- NEGATIVE CONTROL. Without this, a classifier that returns
-- pull-failed-tls-untrusted unconditionally satisfies every arm above.
if classify("Error: something entirely unexpected happened") == "pull-failed-tls-untrusted" then
    fail[#fail + 1] = "classifier-always-says-tls"
else pass = pass + 1 end

-- The TRUST case must name itself loudly AND say that no-models will lie, since
-- being mistaken for an empty cache is the whole defect.
local out = report("x509: certificate signed by unknown authority")
if out:find("reason=pull-failed-tls-untrusted", 1, true) then pass = pass + 1 else fail[#fail + 1] = "report-omits-token" end
if out:find("NOT an empty cache", 1, true) then pass = pass + 1 else fail[#fail + 1] = "report-omits-no-models-warning" end

-- EVIDENCE SURVIVES. A classifier that hides the output it classified is a
-- nicer-looking swallow than the one this replaced.
if out:find("pull-output|", 1, true) then pass = pass + 1 else fail[#fail + 1] = "report-drops-evidence" end

-- A non-trust failure must NOT carry the trust remedy, or the remedy is noise.
if report("Error: connection refused"):find("NOT an empty cache", 1, true) then
    fail[#fail + 1] = "non-trust-carries-trust-remedy"
else pass = pass + 1 end

if #fail > 0 then verdict.emit("violation:pull-failure-classification:" .. table.concat(fail, " "), 1) end
verdict.ok("pull-failure-classification:" .. pass .. " passed")

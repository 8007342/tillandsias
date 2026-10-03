-- @trace order:1525-c6jm, methodology.yaml base64_script_injection_ban
-- @trace plan/issues/violation-python-base64-injection-2026-07-01.md
--
-- check-no-base64-script-injection.lua — PORTED from
-- check-no-base64-script-injection.sh, byte for byte, every exemption and
-- diagnostic kept. Enforces methodology.yaml base64_script_injection_ban:
-- embedding an executable script inside a base64 literal and decoding+running
-- it at runtime is forbidden (used 2026-07-01 to smuggle Python; reintroduced
-- as a bash shim on windows-next and removed 2026-07-02).
--
-- Verifiable constraint: refuses (exit 1) if any tracked file exhibits the
-- decode-to-EXECUTABLE idiom — a `base64 -d`/`--decode`/`-D` AND a `chmod +x`
-- (or a `TILLANDSIAS_PODMAN_BIN=`/interpreter-swap) in the SAME file. That is
-- the smell of "materialise a script from a base64 blob and run it".
--
-- Deliberately narrow: decoding base64 DATA (a Shamir key, a cert, a doc
-- example) is legitimate and uses `base64 -d` WITHOUT making the output
-- executable, so it does not trip. Legitimate Rust base64 uses the crate API,
-- not shell decode.
--
-- WHAT THE PORT MAKES UNREPRESENTABLE RATHER THAN AVOIDS: the .sh printed
-- NOTHING on stdout on a refusal (every diagnostic line was `>&2`, and the
-- script exited 1 in silence on its own success channel). The runner that
-- hosts every Lua decider always emits exactly one stdout verdict line
-- (`refused:<name>`), so this port prints one more stdout line on refusal
-- than the .sh did. Every stderr line is unchanged. Checked against every
-- live caller (build.sh, pre-push-local-gate.sh, local-ci.sh): none parses
-- refusal stdout content, only the exit code and (for the two hooks) a
-- `head`-truncated display of the combined 2>&1 stream.
--
-- Verdicts (unchanged grammar):
--   ok:no-base64-script-injection                exit 0
--   refused:no-base64-script-injection:<n>        exit 1 (NEW stdout line; see above)
local DECODE = [[base64 (-d|--decode|-D)\b]]
local EXECUTABLE = [[(chmod \+x|_PODMAN_BIN=|TILLANDSIAS_PODMAN_BIN)]]

-- Candidate files: those containing a shell base64 decode, excluding this
-- checker, the incident record, the methodology rule text, and archived docs.
-- `|| true` in the .sh is reproduced by treating ANY non-zero git exit (no
-- matches, or a real error) as "no candidates" — the same swallow.
local res = proc.run({
    argv = {
        "git", "grep", "-lE", DECODE, "--",
        ":(exclude)scripts/lua/check-no-base64-script-injection.lua",
        ":(exclude)*.md",
        ":(exclude)plan/archive/**",
        ":(exclude)methodology.yaml",
    },
})

local candidates = {}
if res.status == "exited" and res.code == 0 then
    for _, l in ipairs(text.lines(res.stdout)) do
        if l ~= "" then candidates[#candidates + 1] = l end
    end
end

local violations = {}
for _, f in ipairs(candidates) do
    local ok, content = pcall(fs.read, f)
    if ok and text.is_match(content, EXECUTABLE) then
        violations[#violations + 1] = f
    end
end

if #violations > 0 then
    log.raw("base64-script-injection-ban: VIOLATION — decode-to-executable idiom in:")
    for _, v in ipairs(violations) do log.raw("  " .. v) end
    log.raw("Do not materialise+run a script from a base64 literal. Use an approved-")
    log.raw("language path, or surface the constraint and leave the flow broken-but-honest.")
    verdict.refused("no-base64-script-injection:" .. #violations)
end

verdict.ok("no-base64-script-injection")

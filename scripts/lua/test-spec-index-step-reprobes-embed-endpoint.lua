-- @trace order:1747-e9d6, order:712-r5x8, order:919-vvyv
-- @env PATH
--
-- test-spec-index-step-reprobes-embed-endpoint.lua — the forge's spec-index
-- step derives the embed endpoint itself when the launch-time probe lost the
-- race with a cold inference service, and says why when it still cannot.
--
-- MEASURED 2026-10-16 on yolanda (56.10.16.1): the startup context said
-- inference_state=ready, yet embed_endpoint=unset; the spec-index step skipped
-- (no-embed-endpoint) and spec_answer refused for the whole session. By hand ten
-- minutes later the endpoint answered in 29 ms. lib-common.sh had probed once
-- at source time (3 s ceiling) and discarded the verdict.
--
--   1 RE-PROBE   curl fails twice (inference still starting) then answers: the
--                step logs `re-probed: ok:embed-endpoint:derived:` and the
--                ensure runs with the derived endpoint
--   2 NAMED      curl never answers: the skip line carries the verdict
--                (`unreachable:embed-endpoint:`), not only "unset"
--   3 EXPLICIT   an explicit TILLANDSIAS_EMBED_ENDPOINT is never re-probed
--   4 MUTANT     the re-probe block removed from a copy: arm 1 goes red
--
-- Hermetic: real ensure_forge_spec_index (awk-extracted from
-- images/default/lib-common.sh) and the real lib-embed-endpoint.sh; curl and
-- the project's scripts/spec-index-ensure.sh are stubs in a scratch dir.
--
-- Usage: tillandsias-plan script run scripts/lua/test-spec-index-step-reprobes-embed-endpoint.lua

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run("spec-index-step-reprobes-embed-endpoint", "git rev-parse --show-toplevel did not answer")
end

local LIB = ROOT .. "/images/default/lib-common.sh"
local EMBED_LIB = ROOT .. "/images/default/lib-embed-endpoint.sh"
local ex = proc.run({ argv = { "awk", "/^ensure_forge_spec_index\\(\\) \\{/,/^\\}/", LIB }, timeout_ms = 30000 })
local IMPL = ex.stdout or ""
-- PREMISE anchors on the skip line the step has always had, not on the
-- re-probe this fixture looks for (a guard keyed on its own subject would
-- go silent when the subject is removed).
if not text.contains(IMPL, "skipped (no-embed-endpoint)") then
    verdict.emit("violation:spec-index-step-reprobes-embed-endpoint:premise:no ensure_forge_spec_index with its skip line in lib-common.sh", 1)
end

local REL = "target/plan-scratch/spec-index-reprobe-" .. time.iso_utc():gsub("[^0-9A-Za-z]", "")
    .. "-" .. tostring(math.random(100000, 999999))
local W = ROOT .. "/" .. REL
fs.mkdir(REL .. "/bin")
fs.mkdir(REL .. "/project/scripts")

-- curl: fails $CURL_FAILS times (or always), counting in a file, then serves a model list.
fs.write(REL .. "/bin/curl", [=[#!/usr/bin/env bash
n=$(cat "$CURL_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$CURL_COUNT"
if [ "${CURL_FAILS:-0}" = always ] || [ "$n" -le "${CURL_FAILS:-0}" ]; then exit 7; fi
for a in "$@"; do last="$a"; done
case "$*" in *"-o /dev/null"*) exit 0 ;; esac
echo '{"data":[{"id":"nomic-embed-text:latest"}]}'
]=])
fs.write(REL .. "/project/scripts/spec-index-ensure.sh", [=[#!/usr/bin/env bash
echo "ok:ensure-stub ep=${TILLANDSIAS_EMBED_ENDPOINT:-UNSET}"
]=])
proc.run({ argv = { "chmod", "0755", W .. "/bin/curl", W .. "/project/scripts/spec-index-ensure.sh" }, timeout_ms = 5000 })

local HARNESS = [=[
set -uo pipefail
source "$EMBED_LIB"
eval "$IMPL"
cd "$PROJECT"
ensure_forge_spec_index
]=]
fs.write(REL .. "/harness.sh", HARNESS)

local runs = 0
local function run(impl, extra)
    runs = runs + 1
    local e = {
        PATH = W .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"),
        EMBED_LIB = EMBED_LIB, IMPL = impl, PROJECT = W .. "/project",
        CURL_COUNT = W .. "/count-" .. runs,
        TILLANDSIAS_HOST_KIND = "forge",
        TILLANDSIAS_INFERENCE_ENDPOINT = "http://inference-stub:11434",
        FORGE_EMBED_REPROBE_WAIT = "5", FORGE_EMBED_REPROBE_INTERVAL = "0",
        FORGE_SPEC_INDEX_MODEL_WAIT = "0",
        -- A host may export its own dev endpoint (yoga does, for its local
        -- inference); proc.run passes every TILLANDSIAS_* through, so the
        -- launch-time state is pinned here: unset unless an arm sets it.
        TILLANDSIAS_EMBED_ENDPOINT = "", OLLAMA_HOST = "",
    }
    for k, v in pairs(extra) do e[k] = v end
    local r = proc.run({ argv = { "bash", W .. "/harness.sh" }, env = e, timeout_ms = 60000 })
    if r.status ~= "exited" then
        verdict.could_not_run("spec-index-step-reprobes-embed-endpoint", "harness did not run: " .. tostring(r.status))
    end
    return (r.stdout or "") .. (r.stderr or "")
end

local DERIVED = "http://inference-stub:11434/v1"
local failed = {}
local function arm(name, cond, got)
    if cond then out.line("ok:   " .. name) else
        out.line("FAIL: " .. name .. " — " .. got:gsub("\n", " | "))
        failed[#failed + 1] = name
    end
end

local function reprobed(o)
    return text.contains(o, "re-probed: ok:embed-endpoint:derived:" .. DERIVED)
        and text.contains(o, "ok:ensure-stub ep=" .. DERIVED)
end

local o = run(IMPL, { CURL_FAILS = "2" })
arm("1 RE-PROBE: inference answers on the third probe; the step derives the endpoint and the ensure runs with it", reprobed(o), o)

o = run(IMPL, { CURL_FAILS = "always" })
arm("2 NAMED: inference never answers; the skip line carries the unreachable verdict",
    text.contains(o, "skipped (no-embed-endpoint)") and text.contains(o, "unreachable:embed-endpoint:" .. DERIVED)
    and not text.contains(o, "ok:ensure-stub"), o)

o = run(IMPL, { CURL_FAILS = "0", TILLANDSIAS_EMBED_ENDPOINT = "http://explicit:1/v1" })
arm("3 EXPLICIT: an explicit endpoint is used as given and never re-probed",
    not text.contains(o, "re-probed") and text.contains(o, "ok:ensure-stub ep=http://explicit:1/v1"), o)

local s = IMPL:find("    # ORDER 1747-e9d6: the source-time probe", 1, true)
local e2 = s and IMPL:find('    ep="${TILLANDSIAS_EMBED_ENDPOINT:-}"', s, true)
if s and e2 then
    o = run(IMPL:sub(1, s - 1) .. IMPL:sub(e2), { CURL_FAILS = "2" })
    arm("4 MUTANT: with the re-probe removed, arm 1 goes red", not reprobed(o), o)
else
    arm("4 MUTANT: with the re-probe removed, arm 1 goes red [re-probe block anchor not found]", false, "")
end

proc.run({ argv = { "rm", "-rf", W }, timeout_ms = 30000 })

if #failed > 0 then
    verdict.emit("violation:spec-index-step-reprobes-embed-endpoint:" .. #failed .. ":of:4", 1, table.concat(failed, "; "))
end
verdict.emit("ok:spec-index-step-reprobes-embed-endpoint:4:of:4", 0)

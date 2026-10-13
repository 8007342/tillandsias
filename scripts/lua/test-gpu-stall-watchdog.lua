-- @trace order:1648-gy9z, order:793-a8e7, spec:inference-container
-- @env PATH SystemRoot TEMP TMP USERPROFILE LOCALAPPDATA HOME
--
-- test-gpu-stall-watchdog.lua — images/inference/gpu-stall-watchdog.sh, RUN tick
-- by tick against stubs, sourced unchanged after decode-floor-pin.sh:
--   * a fake process table (TGW_PROC_ROOT) holding llama-server runners;
--   * a stub `curl` answering a runner's /slots and ollama's /api/ps from files;
--   * a stub `ollama` keeping a model store (the decode-floor fixture's shape);
--   * a stub kill (TGW_KILL) that records instead of signalling;
--   * TGW_NOW for time.
--
-- Arms:
--   1 progress advancing: never killed
--   2 a stall past TGW_STALL_S with one GPU-resident model: killed once, the
--     model pinned num_gpu 0 and recorded in the decode-floor pin record, one
--     gpu-stall line; under the threshold nothing happens
--   3 BLIND, /slots unreachable: "watchdog blind ... slots-unreachable", no
--     kill, and logged once, not every tick
--   4 BLIND, /slots without the verified fields: blind, no kill even after long
--   5 BLIND, a stall that cannot be attributed to one GPU model: no kill, no pin
--   6 an idle runner (is_processing false) is never killed
--   7 the quarantine is restored on opt-out (decode-floor reconcile, tier cpu):
--     no residual num_gpu 0
--
-- Usage: tillandsias-plan script run scripts/lua/test-gpu-stall-watchdog.lua

local SUBJECT = "images/inference/gpu-stall-watchdog.sh"
local PIN = "images/inference/decode-floor-pin.sh"
for _, f in ipairs({ SUBJECT, PIN }) do
    if not fs.exists(f) then verdict.could_not_run("gpu-stall-watchdog-fixture", "subject missing: " .. f) end
end

local function run(argv, extra_env)
    local env_tbl = {}
    for _, k in ipairs({ "PATH", "SystemRoot", "TEMP", "TMP", "USERPROFILE", "LOCALAPPDATA", "HOME" }) do
        local v = env.get(k)
        if v ~= nil then env_tbl[k] = v end
    end
    for k, v in pairs(extra_env or {}) do env_tbl[k] = v end
    return proc.run({ argv = argv, timeout_ms = 120000, env = env_tbl })
end

local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local REL = "target/plan-scratch/gpu-stall-watchdog-" .. time.iso_utc():gsub("[^%w]", "") .. "-" .. tostring(math.random(100000, 999999))
local ABS = ROOT .. "/" .. REL
fs.mkdir(REL .. "/bin")

fs.write(REL .. "/bin/curl", [=[#!/usr/bin/env bash
url=""; for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */api/ps) f="$TGW_FAKE/ps" ;;
  */slots) port="${url#http://127.0.0.1:}"; port="${port%%/*}"; f="$TGW_FAKE/slots-$port" ;;
  *) exit 7 ;;
esac
[ -f "$f" ] || exit 7
cat "$f"
]=])
fs.write(REL .. "/bin/fake-kill", "#!/usr/bin/env bash\necho \"$*\" >> \"$TGW_FAKE/killed\"\n")
fs.write(REL .. "/bin/ollama", [=[#!/usr/bin/env bash
S="$TDF_STORE"
enc() { printf '%s' "$1" | sed 's/:/__/g'; }
dec() { printf '%s' "$1" | sed 's/__/:/g'; }
case "$1" in
  list) echo "NAME ID SIZE MODIFIED"; for d in "$S"/*/; do [ -d "$d" ] && echo "$(dec "$(basename "$d")") 0 1MB now"; done ;;
  show)
    if [ "$2" = "--parameters" ]; then grep '^PARAMETER ' "$S/$(enc "$3")/mf" | sed 's/^PARAMETER //'
    elif [ "$2" = "--modelfile" ]; then cat "$S/$(enc "$3")/mf"
    else echo "    parameters          $(cat "$S/$(enc "$2")/size")"; fi ;;
  create)
    d="$S/$(enc "$2")"; from="$(sed -n 's/^FROM //p' "$4" | head -1)"
    if [ "$from" = "$2" ]; then { cat "$d/mf"; grep '^PARAMETER ' "$4"; } > "$d/mf.new"; else grep -v '^#' "$4" > "$d/mf.new"; fi
    mv "$d/mf.new" "$d/mf" ;;
esac
]=])
run({ "chmod", "+x", ABS .. "/bin/curl", ABS .. "/bin/fake-kill", ABS .. "/bin/ollama" })
fs.write(REL .. "/tick.sh", ". \"$TDF_SUBJECT\"\n. \"$TGW_SUBJECT\"\ntillandsias_gpu_stall_tick \"$TGW_STATE\" \"$TGW_RECORD\"\n")
fs.write(REL .. "/optout.sh", ". \"$TDF_SUBJECT\"\ntillandsias_decode_floor_reconcile \"$TGW_RECORD\"\n")

local function slots(processing, done)
    return '[{"id":0,"n_ctx":8192,"is_processing":' .. processing .. ',"id_task":0,"n_prompt_tokens":5093,"n_prompt_tokens_processed":'
        .. done .. ',"params":{"top_k":40}}]'
end
local PS_ONE = '{"models":[{"name":"qwen2.5:3b","model":"qwen2.5:3b","size":2000,"size_vram":2000}]}'
local PS_TWO = '{"models":[{"name":"qwen2.5:3b","size_vram":2000},{"name":"other:7b","size_vram":5000}]}'

-- A scenario: one runner (pid 4242 on port 5555), a model store, a fake dir.
local function scenario(name)
    local d = REL .. "/" .. name
    run({ "rm", "-rf", ROOT .. "/" .. d })
    fs.mkdir(d .. "/proc/4242")
    fs.write(d .. "/proc/4242/cmdline", "/home/ollama/.ollama/models/.tools/lib/ollama/llama-server --model /blobs/sha256-x --port 5555 --ctx-size 8192")
    fs.mkdir(d .. "/proc/77")
    fs.write(d .. "/proc/77/cmdline", "/usr/bin/ollama serve")
    fs.mkdir(d .. "/fake")
    fs.mkdir(d .. "/store/qwen2.5__3b")
    fs.write(d .. "/store/qwen2.5__3b/size", "3.1B")
    fs.write(d .. "/store/qwen2.5__3b/mf", "FROM /blobs/sha256-x\n")
    return d
end
local function tick(d, now, extra)
    local e = {
        PATH = ABS .. "/bin:" .. (env.get("PATH") or ""),
        TGW_PROC_ROOT = ROOT .. "/" .. d .. "/proc",
        TGW_FAKE = ROOT .. "/" .. d .. "/fake",
        TGW_KILL = ABS .. "/bin/fake-kill",
        TGW_NOW = tostring(now),
        TGW_STALL_S = "120",
        TGW_STATE = ROOT .. "/" .. d .. "/state",
        TGW_RECORD = ROOT .. "/" .. d .. "/pins",
        TDF_STORE = ROOT .. "/" .. d .. "/store",
        TDF_SUBJECT = ROOT .. "/" .. PIN,
        TGW_SUBJECT = ROOT .. "/" .. SUBJECT,
    }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = run({ "bash", ABS .. "/" .. (e.SCRIPT or "tick.sh") }, e)
    return text.trim(r.stdout or ""), (r.stderr or "")
end
local function killed(d) return fs.exists(d .. "/fake/killed") and fs.read(d .. "/fake/killed") or "" end
local function mf(d) return fs.read(d .. "/store/qwen2.5__3b/mf") end

local passed, failed = 0, 0
local function check(name, cond, why)
    if cond then passed = passed + 1; out.line("ok:   " .. name)
    else failed = failed + 1; out.line("FAIL: " .. name .. " — " .. why) end
end

-- 1 advancing.
local d = scenario("adv")
fs.write(d .. "/fake/ps", PS_ONE)
local outs = {}
for i, p in ipairs({ { 0, 512 }, { 130, 1024 }, { 260, 1536 }, { 400, 2048 } }) do
    fs.write(d .. "/fake/slots-5555", slots("true", p[2]))
    outs[i] = tick(d, p[1])
end
check("1 advancing progress is never killed", killed(d) == "" and table.concat(outs, "") == "",
    "killed=[" .. killed(d) .. "] out=[" .. table.concat(outs, "|") .. "]")

-- 2 stall.
d = scenario("stall")
fs.write(d .. "/fake/ps", PS_ONE)
fs.write(d .. "/fake/slots-5555", slots("true", 2048))
local o1 = tick(d, 0)
local o2 = tick(d, 60)
check("2 under the threshold nothing happens", o1 == "" and o2 == "" and killed(d) == "", "o1=[" .. o1 .. "] o2=[" .. o2 .. "]")
local o3, e3 = tick(d, 130)
check("2 a stall past the threshold kills the runner once", killed(d) == "-TERM 4242\n", "killed=[" .. killed(d) .. "] err=[" .. e3 .. "]")
check("2 and quarantines the model to the CPU, recorded",
    text.contains(mf(d), "PARAMETER num_gpu 0") and fs.exists(d .. "/pins") and fs.read(d .. "/pins") == "qwen2.5:3b\n",
    "mf=[" .. mf(d) .. "]")
check("2 one gpu-stall line naming model, runner and stall",
    o3 == "gpu-stall: model=qwen2.5:3b runner=4242 stalled=130s progress=2048; killed, quarantined to the CPU until the next start",
    "[" .. o3 .. "]")

-- 3 blind: unreachable.
d = scenario("unreach")
fs.write(d .. "/fake/ps", PS_ONE)
local b1 = tick(d, 0)
local b2 = tick(d, 500)
check("3 BLIND unreachable: logged, never killed",
    b1 == "watchdog blind: runner=4242 slots-unreachable:port=5555" and killed(d) == "", "[" .. b1 .. "] killed=[" .. killed(d) .. "]")
check("3 logged once, not every tick", b2 == "", "[" .. b2 .. "]")

-- 4 blind: unrecognised shape.
d = scenario("shape")
fs.write(d .. "/fake/ps", PS_ONE)
fs.write(d .. "/fake/slots-5555", '[{"id":0,"state":"busy","progress":0.4}]')
local u1 = tick(d, 0)
tick(d, 1000)
check("4 BLIND unrecognised /slots: logged, never killed",
    u1 == "watchdog blind: runner=4242 slots-unrecognised:port=5555" and killed(d) == "" and not text.contains(mf(d), "num_gpu"),
    "[" .. u1 .. "] killed=[" .. killed(d) .. "]")

-- 5 blind: ambiguous model.
d = scenario("ambig")
fs.write(d .. "/fake/ps", PS_TWO)
fs.write(d .. "/fake/slots-5555", slots("true", 2048))
tick(d, 0)
local a2 = tick(d, 200)
check("5 BLIND unattributable stall: no kill, no pin",
    text.contains(a2, "watchdog blind: runner=4242 stalled-200s-but-no-single-gpu-model") and killed(d) == ""
        and not text.contains(mf(d), "num_gpu"),
    "[" .. a2 .. "] killed=[" .. killed(d) .. "]")

-- 6 idle.
d = scenario("idle")
fs.write(d .. "/fake/ps", PS_ONE)
fs.write(d .. "/fake/slots-5555", slots("false", 0))
tick(d, 0)
local i2 = tick(d, 5000)
check("6 an idle runner is never killed", killed(d) == "" and i2 == "", "[" .. i2 .. "]")

-- 7 the quarantine is restored on opt-out.
d = REL .. "/stall"
local r7 = tick(d, 0, { SCRIPT = "optout.sh", TILLANDSIAS_INFERENCE_TIER = "cpu" })
check("7 opt-out restores the quarantined model, no residual num_gpu 0",
    text.contains(r7, "restored=1") and not text.contains(mf(d), "num_gpu") and not fs.exists(d .. "/pins"),
    "[" .. r7 .. "] mf=[" .. mf(d) .. "]")

run({ "rm", "-rf", ABS })
if failed > 0 then
    verdict.emit("refused:gpu-stall-watchdog-fixture:" .. failed .. "-of-" .. (passed + failed), 1)
end
verdict.emit("ok:gpu-stall-watchdog-fixture:" .. passed .. " arms", 0)

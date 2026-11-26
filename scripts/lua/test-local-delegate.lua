-- @trace order:1833-ytbe, spec:local-coding-delegation, order:2386-lrg1
-- @env PATH HOME
--
-- test-local-delegate.lua — hermetic fixture for scripts/local-delegate.sh. Ported from
-- test-local-delegate.sh (2386-lrg1); same five arms.
--
-- Each arm builds a scratch git repo carrying a fixture ledger row (owned_files: greeting.txt;
-- closure scripts/check-greeting.sh, which passes when greeting.txt says hello and counts its
-- own runs) and drives the delegate against a STUB endpoint: a `curl` first on PATH that
-- answers /v1/models and replays canned chat replies (reply-<n>.json, default: a finish call),
-- saving each request. The no-endpoint arm uses the REAL curl against a port nothing listens on.
--
--   1 OK          greeting.txt=hello, finish -> ok:...:ok:rounds=1:closure=passed; closure ran
--                 once; edit left uncommitted; HEAD unchanged
--   2 STRAY       greeting.txt AND other.txt (not owned) -> out-of-scope; other.txt restored,
--                 tree clean, closure never ran, no commit
--   3 NO ENDPOINT http://127.0.0.1:1 -> no-endpoint, non-zero, tree untouched, no chat request
--   4 RED         greeting.txt=wrong, --max-rounds 2 -> closure-red:rounds=2; closure ran twice;
--                 the third request carried the closure's failure output; tree clean
--   5 NO JQ/PY    the delegate's two files name neither tool
--
-- ENV. Every TILLANDSIAS_* is dropped (an ambient TILLANDSIAS_INFERENCE_MODEL or _ENDPOINT
-- must not reach the subject); the delegate gets PATH (stub bin first), HOME,
-- TILLANDSIAS_STUB_DIR, TILLANDSIAS_INFERENCE_ENDPOINT and TILLANDSIAS_PLAN_BIN (absolute).
-- Nothing re-enters build.sh. The scratch repos are made with `git init <dir>` (it creates
-- the repo even under this checkout) and every later git call is `git -C <scratch repo>`.
--
-- GRAMMAR ok:local-delegate:<n> arms | violation:local-delegate:<n>-failed
--       | skip:local-delegate:no-plan-binary | refused:local-delegate:<reason>

local fixture = require "common.fixture"
local T = fixture.new("local-delegate")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()
local DELEGATE = ROOT .. "/scripts/local-delegate.sh"
local LUA = ROOT .. "/scripts/lua/local-delegate.lua"
local PLAN = fixture.plan_binary()
if PLAN == "" then T:skip("no-plan-binary") end
if not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local REAL_CURL = fixture.which("curl")
if not REAL_CURL then T:refuse("no-curl", "curl is not on PATH") end
local PATH = env.get("PATH") or "/usr/bin:/bin"
local HOME = env.get("HOME") or ""

local W = T:scratch()
fs.mkdir(W.rel .. "/bin")
fs.write(W.rel .. "/bin/curl", [==[#!/usr/bin/env bash
url=""; for a in "$@"; do case "$a" in http://*|https://*) url="$a" ;; esac; done
case "$url" in
    http://stub.invalid/*) ;;
    *) exec "]==] .. REAL_CURL .. [==[" "$@" ;;
esac
d="$TILLANDSIAS_STUB_DIR"
case "$url" in
    */v1/models) printf '{"object":"list","data":[{"id":"stub"}]}\n'; exit 0 ;;
    */v1/chat/completions)
        n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/count"
        cat > "$d/req-$n.json"
        if [ -f "$d/reply-$n.json" ]; then cat "$d/reply-$n.json"
        else printf '%s\n' '{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"f","type":"function","function":{"name":"finish","arguments":"{\"summary\":\"done\"}"}}]}}]}'
        fi
        exit 0 ;;
esac
exit 22
]==])
T:must{ "chmod", "+x", W.abs .. "/bin/curl" }

-- One canned reply calling write_file (content gets a trailing \n, as the .sh's printf).
local function write_call(path, content)
    return '{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"w","type":"function","function":{"name":"write_file","arguments":"{\\"path\\":\\"'
        .. path .. '\\",\\"content\\":\\"' .. content .. '\\\\n\\"}"}}]}}]}\n'
end

local LEDGER_ROW = [[
packets:
  - packet_id: fixture-greeting-says-hello
    order: 9-ldfx
    status: ready
    kind: feature
    priority: p2
    pickup_role: any
    owned_files:
      - greeting.txt
    title: greeting.txt says hello
    exit_criteria:
      - 'greeting.txt contains hello'
    verifiable_closure: 'bash scripts/check-greeting.sh exits 0 (pre-fix result: FAILS — greeting.txt says hi)'
]]
local CHECK = [[
#!/usr/bin/env bash
echo run >> "$TILLANDSIAS_STUB_DIR/closure-runs"
grep -qx hello greeting.txt && { echo "ok:greeting"; exit 0; }
echo "FAIL: greeting.txt is '$(cat greeting.txt)', want hello"; exit 1
]]

local function git(d, ...)
    local spec = { "git", "-C", d.abs .. "/repo", ... }
    return T:run(spec)
end
local function mkrepo(tag)
    local d = T:scratch(tag)
    local R = d.rel .. "/repo"
    fs.mkdir(R .. "/plan/index.d"); fs.mkdir(R .. "/scripts"); fs.mkdir(d.rel .. "/stub")
    fs.write(R .. "/plan/index.yaml", "packets: []\n")
    fs.write(R .. "/plan/index.d/20261023t000000z-00000000-fixture.yaml", LEDGER_ROW)
    fs.write(R .. "/scripts/check-greeting.sh", CHECK)
    fs.write(R .. "/greeting.txt", "hi\n")
    fs.write(R .. "/other.txt", "keep me\n")
    T:must{ "git", "init", "-q", d.abs .. "/repo" }
    T:must{ "git", "-C", d.abs .. "/repo", "add", "-A" }
    T:must{ "git", "-C", d.abs .. "/repo", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
        "-c", "commit.gpgsign=false", "commit", "-qm", "fixture" }
    return d
end
local function drive(d, ep, ...)
    local spec = { SH, DELEGATE, "implement", "9-ldfx", "--model", "stub", ... }
    spec.cwd = d.abs .. "/repo"
    spec.env_unset = { "TILLANDSIAS_*" }
    spec.env = { PATH = W.abs .. "/bin:" .. PATH, HOME = HOME, TILLANDSIAS_STUB_DIR = d.abs .. "/stub",
        TILLANDSIAS_INFERENCE_ENDPOINT = ep, TILLANDSIAS_PLAN_BIN = PLAN }
    spec.timeout_ms = 300000
    local r = T:run(spec)
    return text.trim(r.stdout or ""), r.code, r.stderr or ""
end
local function head_of(d) return text.trim(git(d, "rev-parse", "HEAD").stdout or "") end
local function porcelain(d, all)
    local spec = { "status", "--porcelain" }
    if all then spec[#spec + 1] = "--untracked-files=all" end
    return (git(d, table.unpack(spec)).stdout or ""):gsub("\n$", "")
end
local function clean(d) return porcelain(d, true) == "" end
local function runs(d)
    local f = d.rel .. "/stub/closure-runs"
    if not fs.exists(f) then return 0 end
    local n = 0
    for _, l in ipairs(text.lines(fs.read(f) or "")) do if l ~= "" then n = n + 1 end end
    return n
end
local function file(d, p) return text.trim(fs.read(d.rel .. "/repo/" .. p) or "") end
local function stub(d, name, body) fs.write(d.rel .. "/stub/" .. name, body) end

-- 1
local d = mkrepo("a1"); local h0 = head_of(d)
stub(d, "reply-1.json", write_call("greeting.txt", "hello"))
local o, rc, err = drive(d, "http://stub.invalid")
T:arm("1 in-bounds edit + passing closure -> ok, closure ran once, edit uncommitted",
    o == "ok:local-delegate:9-ldfx:ok:rounds=1:closure=passed" and rc == 0 and runs(d) == 1
        and head_of(d) == h0 and file(d, "greeting.txt") == "hello" and porcelain(d) == " M greeting.txt",
    "'" .. o .. "' rc=" .. tostring(rc) .. " runs=" .. runs(d) .. " status='" .. porcelain(d) .. "' stderr=" .. err)

-- 2
d = mkrepo("a2"); h0 = head_of(d)
stub(d, "reply-1.json", write_call("greeting.txt", "hello"))
stub(d, "reply-2.json", write_call("other.txt", "hacked"))
o, rc, err = drive(d, "http://stub.invalid")
T:arm("2 stray edit -> out-of-scope, other.txt restored, tree clean, closure not run, no commit",
    o == "refused:local-delegate:9-ldfx:out-of-scope:other.txt" and rc ~= 0 and clean(d)
        and file(d, "other.txt") == "keep me" and runs(d) == 0 and head_of(d) == h0,
    "'" .. o .. "' rc=" .. tostring(rc) .. " runs=" .. runs(d) .. " other='" .. file(d, "other.txt") .. "' stderr=" .. err)

-- 3
d = mkrepo("a3"); h0 = head_of(d)
o, rc, err = drive(d, "http://127.0.0.1:1")
T:arm("3 endpoint down -> no-endpoint, non-zero, tree untouched",
    o == "refused:local-delegate:9-ldfx:no-endpoint" and rc ~= 0 and clean(d)
        and not fs.exists(d.rel .. "/stub/count") and head_of(d) == h0,
    "'" .. o .. "' rc=" .. tostring(rc) .. " stderr=" .. err)

-- 4
d = mkrepo("a4"); h0 = head_of(d)
stub(d, "reply-1.json", write_call("greeting.txt", "wrong"))
o, rc, err = drive(d, "http://stub.invalid", "--max-rounds", "2")
local req3 = fs.exists(d.rel .. "/stub/req-3.json") and (fs.read(d.rel .. "/stub/req-3.json") or "") or ""
T:arm("4 red closure -> closure-red:rounds=2, ran twice, failure fed back, tree clean",
    o == "refused:local-delegate:9-ldfx:closure-red:rounds=2" and rc ~= 0 and runs(d) == 2 and clean(d)
        and head_of(d) == h0 and text.contains(req3, "want hello"),
    "'" .. o .. "' rc=" .. tostring(rc) .. " runs=" .. runs(d) .. " stderr=" .. err)

-- 5
local g = T:run{ "grep", "-nwiE", "jq|python[0-9.]*", DELEGATE, LUA }
T:arm("5 no jq or python in the delegate",
    fs.exists("scripts/local-delegate.sh") and fs.exists("scripts/lua/local-delegate.lua") and g.code == 1,
    "delegate absent or names jq/python: " .. (g.stdout or ""))

T:finish()

-- @trace order:1776-brk3, openspec/changes/on-demand-image-ensure/design.md
-- @env PATH
-- @env CARGO_TARGET_DIR
--
-- test-image-ensure-breaker.lua — a failed on-demand image build is
-- remembered by (image, inputs digest), and every later ensure refuses fast
-- instead of building again.
--
-- Drives the REAL binary's `--internal-ensure-image` (detached helper and
-- all) against a fake image root and a podman shim that counts `build`
-- calls. The shim fails a build whose Containerfile has a `RUN false` line
-- and otherwise records the built tag with its source-digest label, so
-- `image exists` / `image inspect` answer as a real store would.
--
--   run 1   a broken proxy context fails and writes the marker (attempts 1,
--           a cause);
--   run 2   the same inputs exit non-zero within 5 s, print
--           build-failed-previously with the log path, and ZERO new builds;
--   run 3   an edited Containerfile builds again, and the marker it leaves
--           is for the NEW digest (the old one is gone);
--   dep     a broken forge-base: ensuring forge records forge-base's marker
--           and none for forge; a second forge ensure refuses naming
--           forge-base without building;
--   control (NEGATIVE) a context that builds leaves no marker and the
--           second ensure decides skip;
--   verdict every ensure prints exactly one `image-ensure <name> decided=`
--           line into the helper log.
--
-- PRE-FIX RESULT: FAILS (run 2 builds again; there is no marker).
local NAME = "image-ensure-breaker"

local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.status ~= "exited" or top.code ~= 0 or ROOT == "" then
    verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer")
end

local penv = { PATH = env.get("PATH") or "/usr/bin:/bin" }
local ctd = env.get("CARGO_TARGET_DIR") or ""
if ctd ~= "" then penv.CARGO_TARGET_DIR = ctd end
local probe = proc.run({ argv = { "bash", "-s" }, cwd = ROOT, env = penv, timeout_ms = 60000,
    stdin = '. scripts/plan-binary-probe.sh\nresolve_target_binary tillandsias debug "$PWD"\n' })
local BIN = text.trim(probe.stdout or "")
if probe.status ~= "exited" or probe.code ~= 0 or BIN == "" then
    verdict.could_not_run(NAME, "no built tillandsias binary (cargo build -p tillandsias-headless --bin tillandsias)")
end

local failed = {}
local function arm(name, cond, got)
    got = got and tostring(got):gsub("\n", " | ") or nil
    if cond then out.line("ok:   " .. name .. (got and (" — " .. got) or "")) else
        out.line("FAIL: " .. name .. " — got: " .. tostring(got))
        failed[#failed + 1] = name
    end
end

local REL = "target/plan-scratch/image-ensure-breaker-" .. time.iso_utc():gsub("[^%w]", "") .. "-"
    .. tostring(math.random(100000, 999999))
local ABS = ROOT .. "/" .. REL

-- The podman shim. State lives in $SHIM_STATE: `builds` (one line per build
-- call) and one file per tag holding its source digest.
local SHIM = [[#!/bin/sh
st="$SHIM_STATE"
mkdir -p "$st/tags"
key() { printf '%s' "$1" | tr '/:' '__'; }
case "$1" in
  build)
    echo build >> "$st/builds"
    tag=""; digest=""; cf=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) tag="$2"; shift ;;
        -f) cf="$2"; shift ;;
        --label) case "$2" in io.tillandsias.image.source-digest=*) digest="${2#*=}" ;; esac; shift ;;
      esac
      shift
    done
    echo "STEP 1/2: FROM scratch"
    # `heal` stands for the outside cause going away (the index answers again).
    if grep -qx 'RUN false' "$cf" && [ ! -f "$st/heal" ]; then
      echo "STEP 2/2: RUN false"
      echo "Error: building at STEP \"RUN false\": while running runtime: exit status 1" >&2
      exit 1
    fi
    printf '%s' "$digest" > "$st/tags/$(key "$tag")"
    exit 0 ;;
  image)
    f="$st/tags/$(key "$3")"
    case "$2" in
      exists) [ -f "$f" ] && exit 0; exit 1 ;;
      inspect)
        [ -f "$f" ] || exit 125
        d=$(cat "$f")
        printf '[{"Id":"sha256:fake%s","Config":{"Labels":{"io.tillandsias.image.source-digest":"%s"}}}]\n' "$(key "$d")" "$d"
        exit 0 ;;
    esac
    exit 0 ;;
  tag)
    s="$st/tags/$(key "$2")"; [ -f "$s" ] || exit 125
    cp "$s" "$st/tags/$(key "$3")"; exit 0 ;;
  *) exit 0 ;;
esac
]]

local function setup(case_name)
    local dir = REL .. "/" .. case_name
    fs.mkdir(dir .. "/bin")
    fs.mkdir(dir .. "/state")
    fs.mkdir(dir .. "/cache")
    fs.mkdir(dir .. "/home")
    fs.mkdir(dir .. "/run")
    fs.mkdir(dir .. "/root/images/proxy")
    fs.mkdir(dir .. "/root/images/default")
    fs.write(dir .. "/root/VERSION", "0.0.0.1\n")
    fs.write(dir .. "/bin/podman", SHIM)
    proc.run({ argv = { "chmod", "755", ROOT .. "/" .. dir .. "/bin/podman" }, timeout_ms = 5000 })
    return dir, ROOT .. "/" .. dir
end

local TAGVER = "0.0.0.1"
local function run_bin(abs, argv)
    local t0 = time.now_ms()
    local full = { BIN }
    for _, a in ipairs(argv) do full[#full + 1] = a end
    local r = proc.run({
        argv = full,
        env = {
            TILLANDSIAS_ROOT = abs .. "/root",
            PATH = abs .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"),
            TILLANDSIAS_PODMAN_BIN = abs .. "/bin/podman",
            SHIM_STATE = abs .. "/state",
            XDG_CACHE_HOME = abs .. "/cache",
            HOME = abs .. "/home",
            XDG_RUNTIME_DIR = abs .. "/run",
        },
        timeout_ms = 120000,
    })
    return r, (time.now_ms() - t0) / 1000, (r.stdout or "") .. (r.stderr or "")
end

local function ensure(abs, image)
    return run_bin(abs, { "--internal-ensure-image", abs .. "/root", image,
        "localhost/tillandsias-" .. image .. ":v" .. TAGVER })
end

local function read_or_empty(path)
    if not fs.exists(path) then return nil end
    return fs.read(path)
end

local function builds(rel)
    local s = read_or_empty(rel .. "/state/builds") or ""
    local n = 0
    for _ in s:gmatch("build\n") do n = n + 1 end
    return n
end

local function marker(rel, image)
    local s = read_or_empty(rel .. "/cache/tillandsias/image-ensure-failures/" .. image .. ".json")
    if not s then return nil end
    return {
        text = s,
        attempts = tonumber(s:match('"attempts"%s*:%s*(%d+)')),
        digest = s:match('"source_digest"%s*:%s*"([^"]*)"'),
        cause = s:match('"cause"%s*:%s*"([^"]*)"'),
    }
end

local function log_text(rel, image)
    return read_or_empty(rel .. "/cache/tillandsias/image-build-" .. image .. ".log") or ""
end

local function count(hay, needle)
    local n, i = 0, 1
    while true do
        local s = hay:find(needle, i, true)
        if not s then return n end
        n, i = n + 1, s + #needle
    end
end

-- ── the breaker: run 1, run 2, run 3 ─────────────────────────────────────────
local rel, abs = setup("broken")
fs.write(rel .. "/root/images/proxy/Containerfile", "FROM scratch\nRUN false\n")
local r1, _, o1 = ensure(abs, "proxy")
local m1 = marker(rel, "proxy")
arm("run 1: a broken context fails", r1.status == "exited" and r1.code ~= 0, r1.status .. ":" .. tostring(r1.code))
arm("run 1: one build was spawned", builds(rel) == 1, builds(rel))
arm("run 1: the marker exists with attempts=1 and a cause",
    m1 ~= nil and m1.attempts == 1 and (m1.cause or "") ~= "", m1 and m1.text or o1:sub(-300))
local log1 = log_text(rel, "proxy")
arm("verdict: run 1 printed exactly one proxy verdict line",
    count(log1, "image-ensure proxy decided=") == 1, count(log1, "image-ensure proxy decided="))

local r2, secs2, o2 = ensure(abs, "proxy")
arm("run 2: exits non-zero", r2.status == "exited" and r2.code ~= 0, r2.status .. ":" .. tostring(r2.code))
arm("run 2: within 5 s", secs2 <= 5, string.format("%.1f s", secs2))
arm("run 2: says build-failed-previously", o2:find("build-failed-previously", 1, true) ~= nil, o2:sub(-400))
arm("run 2: names the log path", o2:find("image-build-proxy.log", 1, true) ~= nil, o2:sub(-400))
arm("run 2: ZERO new builds", builds(rel) == 1, builds(rel))
local log2 = log_text(rel, "proxy")
arm("verdict: run 2 printed exactly one more proxy verdict line, decided=refuse",
    count(log2, "image-ensure proxy decided=") == 2 and log2:find("image-ensure proxy decided=refuse", 1, true) ~= nil,
    log2:sub(#log1 + 1, #log1 + 400))

fs.write(rel .. "/root/images/proxy/Containerfile", "FROM scratch\n# edited\nRUN false\n")
local r3, _, o3 = ensure(abs, "proxy")
local m3 = marker(rel, "proxy")
arm("run 3: edited inputs build again", builds(rel) == 2, builds(rel) .. " / " .. o3:sub(-200))
arm("run 3: the old marker is gone (the marker is for the new digest, attempts 1)",
    m1 ~= nil and m3 ~= nil and m3.digest ~= m1.digest and m3.attempts == 1, m3 and m3.text)
arm("run 3: still fails", r3.status == "exited" and r3.code ~= 0, r3.status .. ":" .. tostring(r3.code))

-- ── the operator's retry ─────────────────────────────────────────────────────
-- The outside cause goes away; the same inputs still refuse until a retry.
fs.write(rel .. "/state/heal", "")
local r4, _, o4 = ensure(abs, "proxy")
arm("heal: the same inputs still refuse without a retry",
    r4.code ~= 0 and builds(rel) == 2 and o4:find("build-failed-previously", 1, true) ~= nil, builds(rel))
local rr, _, orr = run_bin(abs, { "--retry-image", "proxy" })
arm("retry-image: exits 0 after a forced rebuild", rr.status == "exited" and rr.code == 0,
    tostring(rr.code) .. " " .. orr:sub(-300))
arm("retry-image: built once more", builds(rel) == 3, builds(rel))
arm("retry-image: the marker is gone", marker(rel, "proxy") == nil, marker(rel, "proxy") and marker(rel, "proxy").text)
arm("retry-image: its verdict says decided=force_rebuild",
    log_text(rel, "proxy"):find("image-ensure proxy decided=force_rebuild", 1, true) ~= nil, log_text(rel, "proxy"):sub(-300))
local ru, _, oru = run_bin(abs, { "--retry-image", "no-such-image" })
arm("retry-image: an unknown image is refused with a remedy",
    ru.code ~= 0 and oru:find("refused:retry-image:unknown-image:no-such-image", 1, true) ~= nil, oru:sub(-200))

-- ── a broken base: the dependent writes no marker of its own ────────────────
rel, abs = setup("dep")
fs.write(rel .. "/root/images/default/Containerfile.base", "FROM scratch\nRUN false\n")
fs.write(rel .. "/root/images/default/Containerfile", "ARG BASE_IMAGE\nFROM ${BASE_IMAGE}\n")
local d1, _, od1 = ensure(abs, "forge")
arm("dep: forge fails when forge-base does", d1.status == "exited" and d1.code ~= 0, d1.code)
arm("dep: forge-base has a marker", marker(rel, "forge-base") ~= nil, od1:sub(-300))
arm("dep: forge has none", marker(rel, "forge") == nil)
local before = builds(rel)
local d2, _, od2 = ensure(abs, "forge")
arm("dep: a second forge ensure refuses naming forge-base's marker",
    d2.code ~= 0 and od2:find("image-ensure:forge-base:build-failed-previously", 1, true) ~= nil, od2:sub(-400))
arm("dep: and builds nothing", builds(rel) == before, builds(rel) .. " vs " .. before)

-- ── NEGATIVE CONTROL: a context that builds ─────────────────────────────────
rel, abs = setup("ok")
fs.write(rel .. "/root/images/proxy/Containerfile", "FROM scratch\n")
local c1, _, oc1 = ensure(abs, "proxy")
arm("control: a healthy context builds", c1.status == "exited" and c1.code == 0 and builds(rel) == 1,
    tostring(c1.code) .. " builds=" .. builds(rel) .. " " .. oc1:sub(-200))
arm("control: no marker", marker(rel, "proxy") == nil)
local c2 = ensure(abs, "proxy")
local logc = log_text(rel, "proxy")
arm("control: the second ensure succeeds without building", c2.code == 0 and builds(rel) == 1, builds(rel))
arm("control: and its verdict says decided=skip",
    logc:find("image-ensure proxy decided=skip", 1, true) ~= nil, logc:sub(-300))

if #failed > 0 then
    verdict.emit("violation:" .. NAME .. ":" .. #failed .. "-failed", 1)
end
verdict.ok(NAME, "run1 + run2 + run3 + dependent + control + verdict arms")

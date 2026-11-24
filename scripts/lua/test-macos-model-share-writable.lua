-- @trace spec:inference-container
-- @trace order:1183-j9dk
-- @env TILLANDSIAS_TRAY_BIN HOME
--
-- test-macos-model-share-writable.lua — order 1183-j9dk. Ported from
-- scripts/test-macos-model-share-writable.sh (shell-to-lua, macbookair
-- 2026-11-23); the arms, verdicts and grammar are unchanged.
--
-- WHAT IT PROTECTS. On macOS the model cache is a virtiofs SHARE, not the
-- podman volume the Linux lane uses (order 313). The engine self-installs into
-- `${OLLAMA_MODELS}.tools/ollama`, TWO levels down. If the inference container
-- cannot create that path, the engine FATALs on every launch and the cache stays
-- empty forever.
--
-- THE MECHANISM IS SELINUX LABELLING, NOT OWNERSHIP. Measured on
-- tlatoanis-macbook-air 2026-09-18 against a live guest:
--   guest root, outside a container, any depth          -> OK
--   unconfined container uid 1000, mkdir at mount ROOT  -> OK
--   unconfined container uid 1000, one level DOWN       -> Permission denied
--   unconfined container as ROOT (--user 0:0), one down -> Permission denied
--   share chmod 0777 first                              -> still denied
--   `chown` inside the share                            -> returns 0, does NOT apply
--   same command with --security-opt label=disable      -> OK
-- virtiofs under Virtualization.framework cannot persist security xattrs, so
-- confined container_t is denied. `:z`/`:Z` on the bind are NOT the remedy: both
-- were measured and failed, and `:Z` stamped an MCS category on the SHARED
-- directory that outlived the container and denied every later one.
--
-- WHAT IT PINS. The inference container ships `--security-opt=label=disable`
-- (build_inference_run_args in crates/tillandsias-headless/src/main.rs), which
-- is the ONLY reason the share is writable. Arm 0 guards that flag in source on
-- every host. Arms 1 and 2 run the SAME two-level probe in the guest, with and
-- without the flag: 1 must pass, 2 must fail, or the fixture does not
-- discriminate.
--
-- WHY THE PRECONDITION IS THE WHOLE TEST. The defect exists only before
-- `.tools/` is created, so a populated cache verifies nothing and is refused as
-- a could-not-run. WHY TWO LEVELS: a one-level mkdir in the mount root succeeds
-- (the root carries container_file_t); a probe that stops there is green on a
-- broken host, and one already produced a false retraction.
--
-- GRAMMAR, one line, or two on a could-not-run:
--   ^(ok:macos-model-share-writable:[0-9]+|violation:macos-model-share-writable:.*|unsupported:macos-model-share-writable:.*|skip:macos-model-share-writable:.*|refused:macos-model-share-writable:.*)$
-- Every verdict line ends with ` subject=[<tray --version line>]` (1332-tdde):
-- the whole line, since two builds can share a version number.
-- A COULD-NOT-RUN PRINTS TWO LINES, `unsupported:` (the detail) then `skip:`
-- (what the litmus runner scores from the last line; 1330-i4hu). Order is
-- load-bearing.

local fixture = require "common.fixture"
local NAME = "macos-model-share-writable"
local SUBJECT = "unresolved"

local function run(argv, ms)
    local r = proc.run({ argv = argv, timeout_ms = ms or 60000 })
    return (r.status == "exited") and r.code or -1, r.stdout or "", r.stderr or ""
end
local function subj(line) return line .. " subject=[" .. SUBJECT .. "]" end
local function finish(line, rc) verdict.emit(subj(line), rc) end
local function cannot_run(why)
    out.line(subj("unsupported:" .. NAME .. ":" .. why))
    verdict.emit(subj("skip:" .. NAME .. ":" .. why), 0)
end

-- ROOT is the checkout (git's answer, not this file's location), and it must be
-- one before anything derived from it is trusted. A refusal, never a skip: a
-- script that does not know where it is cannot be trusted about anything else.
local ROOT = fixture.repo_root()
if run({ "test", "-f", ROOT .. "/build.sh" }) ~= 0 or run({ "test", "-d", ROOT .. "/crates" }) ~= 0 then
    finish("refused:" .. NAME .. ":root-is-not-a-tillandsias-checkout-" .. ROOT, 1)
end

-- Arm 0: the source guard, which needs no VM and no macOS.
local HEADLESS = ROOT .. "/crates/tillandsias-headless/src/main.rs"
if fs.exists(HEADLESS) then
    local src = fs.read(HEADLESS) or ""
    if not text.contains(src, '"--security-opt=label=disable".into()') then
        finish("violation:" .. NAME .. ":inference-run-args-lost-label-disable", 1)
    end
end

-- Off darwin the source half above is all that was answered; say so.
local _, uname = run({ "uname", "-s" })
if text.trim(uname) ~= "Darwin" then cannot_run("not-darwin-source-arm-only") end

local TRAY = env.get("TILLANDSIAS_TRAY_BIN") or ""
if TRAY == "" then TRAY = ROOT .. "/dist/Tillandsias.app/Contents/MacOS/tillandsias-tray" end
local tray_ok = run({ "test", "-x", TRAY }) == 0
if tray_ok then
    local _, v = run({ TRAY, "--version" })
    local line = text.lines(v)[1] or ""
    SUBJECT = (line ~= "") and line or ("unreadable(" .. TRAY .. ")")
else
    SUBJECT = "absent(" .. TRAY .. ")"
end
-- A bare target/release binary has no virtualization entitlement and cannot
-- start a VM at all; name that instead of a confusing "boot loader is invalid".
if not tray_ok then cannot_run("no-app-bundle-run-scripts/build-macos-tray.sh") end

local HOST_CACHE = (env.get("HOME") or "") .. "/Library/Caches/tillandsias/models"
-- (outside the checkout, so `test`/`ls`, not fs.*: the runner confines fs to the repo)
if run({ "test", "-d", HOST_CACHE }) == 0 then
    local _, listing = run({ "ls", "-A", HOST_CACHE })
    if text.trim(listing) ~= "" then cannot_run("cache-not-empty-precondition-unmet") end
end

-- Both live arms run the SAME command against the SAME mount; the only
-- difference is the flag this fixture claims is load-bearing. This text runs
-- in the GUEST (the tray's --exec-guest), never on this host.
local GUEST = [=[
M=/root/.cache/tillandsias/models
# 1087-h2z9: the concrete version tag, never a floating one; sha256- tags skipped.
IMG="$(podman images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null \
       | awk -F: '$0 ~ /tillandsias-inference/ && $NF != "latest" && $NF !~ /^sha256-/ { print; exit }')"
# verbatim from build_inference_run_args, minus the parts that need the enclave
PFLAGS="--cap-drop=ALL --security-opt=no-new-privileges --security-opt=label=disable --userns=keep-id --pids-limit=1024"
MUTATED="--cap-drop=ALL --security-opt=no-new-privileges --userns=keep-id --pids-limit=1024"

[ -n "$IMG" ] && podman image exists "$IMG" || { echo "ARM0:no-version-tagged-inference-image"; exit 0; }
mountpoint -q "$M" || { echo "ARM0:model-cache-not-mounted"; exit 0; }

probe() {
  # The product shape: TWO levels, then a FILE.
  rm -rf "$M/.tools-probe"
  podman run --rm $1 -v "$M:/home/ollama/.ollama/models:rw" --entrypoint sh "$IMG" -c \
    "mkdir -p /home/ollama/.ollama/models/.tools-probe/ollama && touch /home/ollama/.ollama/models/.tools-probe/ollama/payload" \
    >/dev/null 2>&1 && echo pass || echo fail
  rm -rf "$M/.tools-probe"
}

echo "ARM1:$(probe "$PFLAGS")"
echo "ARM2:$(probe "$MUTATED")"
]=]
local _, o, e = run({ TRAY, "--exec-guest", GUEST }, 900000)
local arms = {}
for _, l in ipairs(text.lines(o .. "\n" .. e)) do
    local k, v = (l:gsub("\r", "")):match("^ARM(%d):(.*)$")
    if k and arms[k] == nil then arms[k] = v end
end

if arms["0"] and arms["0"] ~= "" then cannot_run(arms["0"]) end
if not arms["1"] or arms["1"] == "" or not arms["2"] or arms["2"] == "" then
    finish("violation:" .. NAME .. ":no-arm-output-guest-unreachable", 1)
end
if arms["1"] ~= "pass" then
    finish("violation:" .. NAME .. ":product-flags-cannot-create-the-engine-payload-dir", 1)
end
if arms["2"] ~= "fail" then
    -- The control did not red: arm 1's green means nothing on its own.
    finish("violation:" .. NAME .. ":mutation-arm-passed-fixture-does-not-discriminate", 1)
end
finish("ok:" .. NAME .. ":3", 0)

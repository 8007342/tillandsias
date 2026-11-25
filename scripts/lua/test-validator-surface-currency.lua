-- @env PATH TMPDIR TEMP TMP SystemRoot
-- @trace order:1287-h6qn, order:1925-ided, order:1925-xbpv, order:2367-d5gx
--
-- test-validator-surface-currency.lua — the validator surface is a CONTENT probe. Pinned: a hash that
-- moves when nothing changed (the rebase case), and one that fails to move when something did, which
-- lies toward healthy. Arms 2-4 run on a SCRATCH COPY reached through TILLANDSIAS_SURFACE_ROOT: a
-- touched live Cargo.lock refuses every later push in the same gate. Ported from the .sh.
--
-- Usage: tillandsias-plan script run scripts/lua/test-validator-surface-currency.lua
-- Verdict: ok:validator-surface-currency:<n> arms | violation:...:<n>-failed | skip:...:no-binary|no-subcommand

local fixture = require "common.fixture"
local T = fixture.new("validator-surface-currency")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:skip("no-binary") end
local MANIFEST, PROBE = "crates/tillandsias-plan/validator-surface.manifest", "crates/tillandsias-plan/Cargo.toml"
if not fs.exists(MANIFEST) then T:refuse("manifest-missing", MANIFEST) end

local function plan(args, root, extra)
    local argv = { PLAN }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local e = { TILLANDSIAS_SURFACE_ROOT = root }
    for k, v in pairs(extra or {}) do e[k] = v end
    local r = proc.run{ argv = argv, cwd = ROOT, timeout_ms = 60000, env = e,
        env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" } }
    return r.code, text.trim(r.stdout or ""), (r.stdout or "") .. (r.stderr or "")
end
if plan{ "validator-surface-hash" } ~= 0 then T:skip("no-subcommand") end

local files = { MANIFEST, "Cargo.lock" }
local listed = {}
for f in (fs.read(MANIFEST):gsub("\r\n", "\n") .. "\n"):gmatch("file (%S+)\n") do
    files[#files + 1], listed[#listed + 1] = f, f
end
if #listed == 0 then T:refuse("manifest-names-no-file") end
local function mtimes()
    local argv = { SH, "-s", "--" }
    for _, f in ipairs(files) do argv[#argv + 1] = f end
    argv.cwd, argv.stdin = ROOT, 'for f in "$@"; do stat -c "%n %y" "$f" 2>/dev/null || stat -f "%N %Fm" "$f" || exit 1; done\n'
    return T:must(argv).stdout
end
local live_before = mtimes()

local rc, _, all = plan{ "validator-surface-hash", "--check" }
T:arm("1 the binary agrees with the checkout it was built from", rc == 0, all)
local _, live = plan{ "validator-surface-hash", "--current" }
if live == "" then T:refuse("no-live-hash") end

local S = T:scratch("surface")
fs.mkdir(S.rel .. "/.git")
local copy = { SH, "-s", "--", S.abs, cwd = ROOT,
    stdin = 'd="$1"; shift\nfor f in "$@"; do mkdir -p "$d/$(dirname "$f")" && cp -p "$f" "$d/$f" || exit 1; done\n' }
for _, f in ipairs(files) do copy[#copy + 1] = f end
T:must(copy)
local function current()
    local _, h = plan({ "validator-surface-hash", "--current" }, S.abs)
    return h
end
local base = current()
T:arm("1 the scratch copy is the same surface", base == live, base .. " vs " .. live)

T:must{ SH, "-s", "--", listed[1], cwd = S.abs, stdin = 'touch "$1" Cargo.lock\n' }
T:arm("2 an mtime-only touch does not move the hash", current() == base, current())

local probe = fs.read(S.rel .. "/" .. PROBE)
fs.write(S.rel .. "/" .. PROBE, probe .. "\n# 1287-h6qn mutation arm\n")
T:arm("3 a real content edit moves it", current() ~= base and current() ~= "", current())
rc, _, all = plan({ "validator-surface-hash", "--check" }, S.abs)
T:arm("3 --check refuses while the surface differs", rc ~= 0, all)
rc, _, all = plan({ "next-order" }, S.abs)
T:arm("3 next-order refuses as a stale plan binary", rc ~= 0 and text.contains(all, "stale-plan-binary"), all)
fs.write(S.rel .. "/" .. PROBE, probe)
T:arm("3 CONTROL the original bytes restore the hash", current() == base, current())

fs.write(S.rel .. "/README.md", "readme\n")
fs.write(S.rel .. "/" .. MANIFEST, fs.read(S.rel .. "/" .. MANIFEST) .. "file README.md\n")
T:arm("4 widening the manifest moves it: the list is read from one place", current() ~= base and current() ~= "", current())

-- 5 the cannot-ask case is an INSTALLED binary, with no checkout above it, so it runs from a temp dir
-- outside the checkout. The control leaves the build-checkout fallback on and must reach a ledger.
local r = T:run{ SH, "-s", "--", PLAN, PLAN:match("%.exe$") or "", env_unset = { "TILLANDSIAS_*", "CARGO_TARGET_DIR" }, stdin = [[
d="$(mktemp -d)" || exit 9
trap 'rm -rf "$d"' EXIT
cp "$1" "$d/tillandsias-plan$2" && cd "$d" || exit 9
for v in 0 1; do
    o="$(TILLANDSIAS_SURFACE_NO_BUILD_CHECKOUT=$v "./tillandsias-plan$2" validator-surface-hash --check 2>&1)"; rc=$?
    echo "check$v rc=$rc ${o%%
*}"
done
echo "embedded=$("./tillandsias-plan$2" validator-surface-hash 2>/dev/null)"
]] }
if r.code ~= 0 then T:refuse("outside-copy-failed", tostring(r.stderr)) end
local o = r.stdout:gsub("\r", "")
T:arm("5 CONTROL with the fallback on the copy reaches a ledger", o:find("check0 rc=", 1, true) ~= nil
    and not o:find("check0 rc=%d+ unknown:validator%-surface"), o)
T:arm("5 with no checkout it answers unknown, never fresh", o:find("check1 rc=[1-9]%d* unknown:validator%-surface") ~= nil, o)
T:arm("5 the embedded hash travels with the binary", o:find("embedded=%x%x%x%x%x%x%x%x") ~= nil, o)

T:arm("6 the live surface files keep their mtimes", mtimes() == live_before, mtimes())
T:finish()

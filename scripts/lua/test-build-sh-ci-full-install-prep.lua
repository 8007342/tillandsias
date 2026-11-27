-- @env PATH HOME
-- @trace spec:dev-build, order:2066-obsv, order:2367-wtse
--
-- test-build-sh-ci-full-install-prep.lua — build.sh --ci-full prepares its inputs before the gate,
-- writes its reports under target/, and bumps no tracked version. Ported from the .sh of the same
-- name (2367-wtse). STATIC over build.sh and its helpers, except the dashboard, which is rendered
-- into scratch.
--
--   1 the shell parses          2 the prep exists, bumps no version, and runs before the gate
--   3 one local-ci entry        4 the counter honours the skip, traces are regenerated
--   5 outputs go to target/     6 the Silverblue builder installs no Python
--   7 the dashboard renders where it is told and touches nothing tracked
--
-- Usage: tillandsias-plan script run scripts/lua/test-build-sh-ci-full-install-prep.lua
-- Verdict: ok:build-sh-ci-full-install-prep:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("build-sh-ci-full-install-prep")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local SRC = "\n" .. fs.read("build.sh"):gsub("\r", "")
local EVIDENCE, DASH = "scripts/generate-evidence-bundle.sh", "scripts/update-convergence-dashboard.sh"
for _, f in ipairs{ "build.sh", EVIDENCE, DASH } do
    local r = T:run{ SH, "-n", ROOT .. "/" .. f, cwd = ROOT }
    T:arm("1 " .. f .. " parses", r.code == 0, r.stderr or "")
end
local function has(s) return text.contains(SRC, s) end
local function count(s)
    local n, at = 0, 1
    while true do
        local a, z = SRC:find(s, at, true)
        if not a then return n end
        n, at = n + 1, z + 1
    end
end
local prep = SRC:match("\n(_prepare_ci_full_install_inputs%(%) {\n.-\n})")
T:arm("2a the prep function is there", prep ~= nil, "not found")
local bumps = {}
for l in ((prep or "") .. "\n"):gmatch("([^\n]*)\n") do
    if not l:match("^%s*#") and (text.contains(l, "_bump_build_version") or text.contains(l, "scripts/bump-version.sh")) then bumps[#bumps + 1] = l end
end
T:arm("2b it bumps no tracked version", prep ~= nil and #bumps == 0, table.concat(bumps, " | "))
local last, at = nil, 1
while true do
    local a, z = SRC:find("_prepare_ci_full_install_inputs", at, true)
    if not a then break end
    last, at = a, z + 1
end
local gate = SRC:find('_run_local_ci_gate "${CI_ARGS[@]}" "${CI_ARG_LIST[@]}"', 1, true)
T:arm("2c it runs before the local-ci gate", last ~= nil and gate ~= nil and last < gate, tostring(last) .. " " .. tostring(gate))
T:arm("3 every build-driven local CI run goes through one redirected helper", count('local -a command=(bash "$SCRIPT_DIR/scripts/local-ci.sh" "$@")') == 1, tostring(count("scripts/local-ci.sh\" \"$@\")")))
T:arm("4 the build counter honours its skip, guests are built, traces regenerated", has("TILLANDSIAS_SKIP_VERSION_BUMP") and has("scripts/build-guest-binaries.sh") and has("scripts/generate-traces.sh"), "one is gone")
local lost = {}
for _, s in ipairs{ 'MD_OUT="$SCRIPT_DIR/target/convergence/centicolon-dashboard.md"', 'JSON_OUT="$SCRIPT_DIR/target/convergence/centicolon-dashboard.json"', 'SUMMARY_OUT="$SCRIPT_DIR/target/convergence/summary.md"',
    'DASHBOARD_FILE="$SCRIPT_DIR/target/convergence/centicolon-dashboard.json"', 'TILLANDSIAS_STATUS_CHECK_BIN="$INSTALL_BIN"', '"$INSTALL_BIN" --init' } do
    if not has(s) then lost[#lost + 1] = s end
end
T:arm("5a build.sh redirects its outputs to target/ and runs the installed binary", #lost == 0, table.concat(lost, " | "))
T:arm("5b the evidence bundle defaults there too", text.contains(fs.read(EVIDENCE), 'DASHBOARD_FILE="${DASHBOARD_FILE:-$PROJECT_ROOT/target/convergence/centicolon-dashboard.json}"'), "default moved")
T:arm("6 the Silverblue builder installs no Python", not text.contains(fs.read("scripts/with-tillandsias-builder.sh"), "python" .. "3"), "found")
local TRACKED = { "docs/convergence/centicolon-dashboard.md", "docs/convergence/centicolon-dashboard.json" }
local function clean() return not fs.exists(TRACKED[1]) and not fs.exists(TRACKED[2]) end
local was, d = clean(), T:scratch()
local r = proc.run{ argv = { SH, ROOT .. "/" .. DASH }, cwd = ROOT, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000, stdin = "",
    env = { PATH = env.get("PATH"), HOME = env.get("HOME"), SOURCE = "/dev/null", MD_OUT = d.abs .. "/d.md", JSON_OUT = d.abs .. "/d.json", SUMMARY_OUT = d.abs .. "/s.md", TERMINAL_PREVIEW = "0" } }
local ok = fs.exists(d.rel .. "/d.json") and pcall(json.parse, fs.read(d.rel .. "/d.json"))
T:arm("7a the dashboard renders where it is told, as JSON too", r.code == 0 and ok and fs.exists(d.rel .. "/d.md") and fs.read(d.rel .. "/d.md") ~= "", "rc=" .. tostring(r.code) .. " " .. (r.stderr or ""):sub(1, 300))
T:arm("7b and nothing is written under docs/convergence", was and clean(), "a tracked dashboard exists")
T:finish()

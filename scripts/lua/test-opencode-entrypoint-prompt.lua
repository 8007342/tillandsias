-- @env PATH
-- @trace spec:forge-opencode-onboarding, order:429, order:767-nkkq, order:2369-8vq3
--
-- test-opencode-entrypoint-prompt.lua — which argv images/default/entrypoint-forge-opencode.sh hands the
-- harness. HERMETIC: the runner's environment is scrubbed, so a lane's own TILLANDSIAS_OPENCODE_PROMPT
-- cannot flip a case (it once did). The common lib and the supervisor are image content, so both are
-- redirected at stubs. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-opencode-entrypoint-prompt.lua
-- Verdict: ok:opencode-entrypoint-prompt:<n> arms | violation:opencode-entrypoint-prompt:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("opencode-entrypoint-prompt")
local SH = fixture.posix_shell()
local SUBJECT = "images/default/entrypoint-forge-opencode.sh"
if not fs.exists(SUBJECT) then T:refuse("subject-missing") end
local src = fs.read(SUBJECT):gsub("\r\n", "\n")
local W = T:scratch()

local function redirect(s, from, to)
    if not s:find(from, 1, true) then T:refuse("redirect-anchor-missing", from) end
    return (s:gsub((from:gsub("%p", "%%%0")), (to:gsub("%%", "%%%%"))))
end
local function plant(name, body)
    body = redirect(body, "source /usr/local/lib/tillandsias/lib-common.sh", 'source "$FIXTURE_DIR/lib-common.sh"')
    fs.write(W.rel .. "/" .. name, redirect(body, "/usr/local/bin/harness-supervisor", '"$FIXTURE_DIR"/supervisor-stub'))
end
plant("entry.sh", src)
-- $1 is the harness NAME; the command starts at $2, as in the real supervisor.
fs.write(W.rel .. "/supervisor-stub", '#!/usr/bin/env bash\nshift\nexec "$@"\n')
fs.write(W.rel .. "/opencode-fake", '#!/usr/bin/env bash\n{ for a in "$@"; do printf "[%s]" "$a"; done; printf "\\n"; } >> "$FIXTURE_DIR/calls"\nexit "${OPENCODE_FAKE_EXIT:-0}"\n')
fs.write(W.rel .. "/openspec-fake", "#!/usr/bin/env bash\nexit 0\n")
local lib = { 'OC_BIN="$FIXTURE_DIR/opencode-fake"', 'OS_BIN="$FIXTURE_DIR/openspec-fake"', 'PROJECT_DIR="$FIXTURE_DIR/project"', "curl() { return 1; }" }
for _, f in ipairs{ "trace_lifecycle", "populate_hot_paths", "clone_project_from_mirror", "require_opencode", "require_openspec",
    "apply_opencode_config_overlay", "prepare_opencode_vault_auth", "opencode_actual_auth_ok", "ensure_forge_prebuilt_tools",
    "start_flaky_installs", "ensure_forge_harnesses", "inject_startup_context", "export_ssh_env", "export_project_env",
    "configure_git_identity", "show_banner", "find_project_dir" } do lib[#lib + 1] = f .. "() { :; }" end
fs.write(W.rel .. "/lib-common.sh", table.concat(lib, "\n") .. "\n")
fs.mkdir(W.rel .. "/project")

local RUN = 'cd "$1" || exit 96; export FIXTURE_DIR="$(pwd)" HOME="$(pwd)"; rm -f calls\n'
    .. 'chmod +x supervisor-stub opencode-fake openspec-fake\n"$BASH" "./$2" </dev/null\n'
local function launch(env_, entry)
    local e = { PATH = env.get("PATH") }
    for k, v in pairs(env_) do e[k] = v end
    local r = proc.run{ argv = { SH, "-s", "--", W.abs, entry or "entry.sh" }, stdin = RUN, env = e, timeout_ms = 60000,
        env_unset = { "TILLANDSIAS_*", "OPENCODE_*" } }
    local calls = fs.exists(W.rel .. "/calls") and fs.read(W.rel .. "/calls"):gsub("\r", "") or ""
    return calls, r.code, "rc=" .. tostring(r.code) .. " calls=" .. calls .. " " .. (r.stderr or ""):sub(1, 300)
end

local P = "Use the /forge-continuous-enhancement skill"
local calls, rc, got = launch{ TILLANDSIAS_OPENCODE_PROMPT = P }
T:arm("1 a prompt runs in OpenCode's run mode", calls == "[run][--auto][" .. P .. "]\n" and rc == 0, got)
calls, rc, got = launch{ TILLANDSIAS_OPENCODE_PROMPT = "exit probe", OPENCODE_FAKE_EXIT = "37" }
T:arm("2 and its exit code is the lane's", rc == 37 and calls == "[run][--auto][exit probe]\n", got)
calls, rc, got = launch{ TILLANDSIAS_OPENCODE_PROMPT = "structured probe", TILLANDSIAS_AGENT_RESULT_FORMAT = "json" }
T:arm("3 structured output is asked for only when wanted", calls == "[run][--auto][--format][json][structured probe]\n", got)
calls, rc, got = launch{}
T:arm("4 no prompt is OpenCode with no arguments", calls == "\n" and rc == 0, got)

-- MUTATION
local function mutant(name, from, to) plant(name, redirect(src, from, to)) end
mutant("noauto.sh", "--auto", "--ask")
calls, rc, got = launch({ TILLANDSIAS_OPENCODE_PROMPT = P }, "noauto.sh")
T:arm("5 MUTATION a run without --auto fails arm 1", calls ~= "" and not calls:find("[--auto]", 1, true), got)
mutant("nofmt.sh", "TILLANDSIAS_AGENT_RESULT_FORMAT", "TILLANDSIAS_NO_SUCH_FORMAT")
calls, rc, got = launch({ TILLANDSIAS_OPENCODE_PROMPT = P, TILLANDSIAS_AGENT_RESULT_FORMAT = "json" }, "nofmt.sh")
T:arm("5 MUTATION a lane that ignores the format fails arm 3", calls == "[run][--auto][" .. P .. "]\n", got)

T:finish()

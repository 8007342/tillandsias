-- @env PATH
-- @trace spec:meta-orchestration, order:1441-myz3, order:2379-p5dq
--
-- test-openspec-pin.lua — the project's openspec CLI pin: scripts/openspec-pin.sh (the coordinator's side,
-- 1-6) and ensure_openspec_pinned / ensure_forge_harnesses in images/default/lib-common.sh (the forge's,
-- 7-9), then every entrypoint (10). npm and the CLI are stubs, so no registry is asked. 7 and 8 carry the
-- weight: a pinned project runs exactly its pin, and the background refresh does not move it to @latest.
-- Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-openspec-pin.lua
-- Verdict: ok:openspec-pin:<n> arms | violation:...:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("openspec-pin")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local PIN_SH, LIB = "scripts/openspec-pin.sh", "images/default/lib-common.sh"
local pin_src, lib = fs.read(PIN_SH):gsub("\r\n", "\n"), "\n" .. fs.read(LIB):gsub("\r\n", "\n")
local W = T:scratch()
fs.mkdir(W.rel .. "/stubs")
-- The stub CLI: `update` rewrites each generated skill to its own version and records its config dir.
fs.write(W.rel .. "/stubs/openspec.tmpl", [[
#!/usr/bin/env bash
case "${1:-}" in
    --version) echo "__VERSION__" ;;
    update)
        printf '%s\n' "${XDG_CONFIG_HOME:-unset}" >>"$STUB_LOG.xdg"
        for f in .claude/skills/openspec-*/SKILL.md .github/skills/openspec-*/SKILL.md; do
            [ -f "$f" ] || continue
            printf -- '---\nname: x\ngeneratedBy: "%s"\n---\n' "__VERSION__" >"$f"
        done
        [ -z "${STUB_ORPHAN:-}" ] || echo "Left 1 files in .codex/ that differ from the copy in .agents/. Nothing was overwritten."
        [ -z "${STUB_STRAY:-}" ] || echo stray >stray.txt ;;
esac
exit 0
]])
fs.write(W.rel .. "/stubs/npm", [[
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case "${1:-}" in
    view) [ -z "${STUB_OFFLINE:-}" ] || exit 1; echo "$STUB_LATEST" ;;
    install)
        shift; prefix=""; global=0; spec=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --prefix) prefix="$2"; shift 2 ;;
                -g) global=1; shift ;;
                --*) shift ;;
                *) spec="$1"; shift ;;
            esac
        done
        v="${spec##*@}"; [ "$v" = latest ] && v="$STUB_LATEST"
        if [ "$global" = 1 ]; then bin="$NPM_CONFIG_PREFIX/bin"; else bin="$prefix/node_modules/.bin"; fi
        case "$spec" in
            @fission-ai/openspec@*) name=openspec ;;
            *) name="stub-$(printf '%s' "${spec%@*}" | tr -c 'a-z0-9' '-')" ;;
        esac
        mkdir -p "$bin" && sed "s/__VERSION__/$v/" "$STUB_TEMPLATE" >"$bin/$name" && chmod +x "$bin/$name" ;;
esac
exit 0
]])
-- The header of every shell here: its scratch paths, the stubs and a HOME, all under $1.
local HEAD = [[
cd "$1" || exit 96; W="$PWD"; chmod +x stubs/npm; mkdir -p home/.cache/tillandsias-project
export HOME="$W/home" STUB_LOG="$W/npm.log" STUB_TEMPLATE="$W/stubs/openspec.tmpl" STUB_LATEST="${STUB_LATEST:-2.0.0}"
export OPENSPEC_PIN_NPM="$W/stubs/npm" OPENSPEC_PIN_CACHE="$W/pin-cache" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
gitc() { git -c user.email=t@e.invalid -c user.name=t -c core.autocrlf=false "$@"; }
skill() { mkdir -p "$1/openspec-explore"; printf -- '---\nname: x\ngeneratedBy: "%s"\n---\n' "$2" >"$1/openspec-explore/SKILL.md"; }
make_repo() { # make_repo <dir> [pin]: generated skills committed from 1.0.0
    mkdir -p "$1/openspec"; skill "$1/.claude/skills" 1.0.0; skill "$1/.github/skills" 1.0.0
    [ -z "${2:-}" ] || printf '%s\n' "$2" >"$1/openspec/cli-version"
    git init -q "$1" && (cd "$1" && git config core.autocrlf false && gitc add -A && gitc commit -qm init) || exit 95
}
]]
local function shell(body, e)
    e = e or {}
    e.PATH = env.get("PATH")
    local r = T:run{ SH, "-s", "--", W.abs, ROOT, stdin = HEAD .. body .. "\n", env = e, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 120000 }
    return (r.stdout or ""):gsub("\r", ""), (r.stderr or ""):gsub("\r", ""), r.code
end
local function repo(name, pin)
    local _, err, code = shell("make_repo " .. name .. " " .. (pin or ""))
    if code ~= 0 then T:refuse("repo-setup", err) end
    return name
end
-- openspec-pin.sh in a repo: its verdict and exit code, as "verdict rc", then its stderr.
local function pin(dir, args, e, script)
    local o, err, code = shell('cd "' .. dir .. '" && exec "$BASH" "' .. (script or (ROOT .. "/" .. PIN_SH)) .. '" ' .. args, e)
    return text.trim(o) .. " " .. tostring(code), err
end
local function is(name, got, want, err) return T:arm(name, got == want, got .. " " .. (err or "")) end

local U, R = repo("unpinned"), repo("pinned", "1.0.0")
local v, err = pin(U, "pin")
is("1 no pin is named absent", v, "absent:openspec-pin 4", err)
is("1 drift says the same", (pin(U, "drift")), "absent:openspec-pin 4")
is("1 a pin is read", (pin(R, "pin")), "1.0.0 0")
is("2 check: a newer release is due", (pin(R, "check")), "due:openspec-bump:1.0.0->2.0.0 5")
is("2 check: current", (pin(R, "check", { STUB_LATEST = "1.0.0" })), "ok:openspec-pin-current:1.0.0 0")
is("2 check: a registry that cannot be reached is unknown", (pin(R, "check", { STUB_OFFLINE = "1" })), "unknown:openspec-latest:registry-unreachable 2")
local N = repo("numeric", "1.9.0")
is("2 check: versions compare as numbers", (pin(N, "check", { STUB_LATEST = "1.10.0" })), "due:openspec-bump:1.9.0->1.10.0 5")
is("3 drift: the generated skills match", (pin(R, "drift")), "ok:openspec-generated-matches-pin:1.0.0:2 0")
shell("cd pinned && skill .github/skills 0.9.0 && gitc commit -qam skew")
v, err = pin(R, "drift")
is("3 drift: a skewed skill", v, "drift:openspec-generated:1.0.0:1 3", err)
T:arm("3 is named", text.contains(err, ".github/skills/openspec-explore/SKILL.md generatedBy=0.9.0"), err)

local B = repo("bump", "1.0.0")
fs.write(W.rel .. "/bump/scratch.txt", "dirt\n")
is("4 bump refuses a dirty tree", (pin(B, "bump")), "refused:openspec-bump:dirty-tree 1")
shell("rm -f bump/scratch.txt")
v, err = pin(B, "bump")
is("4 bump regenerates at the new pin", v, "bumped:openspec:1.0.0->2.0.0:3-paths 0", err)
T:arm("4 it wrote the pin and the skills match it", text.trim(fs.read(W.rel .. "/bump/openspec/cli-version")) == "2.0.0"
    and pin(B, "drift") == "ok:openspec-generated-matches-pin:2.0.0:2 0", fs.read(W.rel .. "/bump/openspec/cli-version"))
local o = shell('x="$(cat npm.log.xdg)"; case "$x" in ""|unset|"$HOME"/.config*) echo machine ;; *) if [ -e "$x" ]; then echo kept; else echo isolated; fi ;; esac\n'
    .. "[ -x pin-cache/2.0.0/node_modules/.bin/openspec ] && echo cached; git -C bump rev-list --count HEAD")
is("4 with its own config, cleaned up, a version-keyed install, and no commit", text.trim(o):gsub("\n", " "), "isolated cached 1")
local x = repo("orphan", "1.0.0")
v, err = pin(x, "bump", { STUB_ORPHAN = "1" })
is("5 a copy the CLI left behind stops the bump for review", v, "review:openspec-bump:1.0.0->2.0.0:drift-or-superseded-copies 6", err)
T:arm("5 and is named", text.contains(err, "superseded copy left by the CLI: .codex (superseded by .agents)"), err)
x = repo("stray", "1.0.0")
v, err = pin(x, "bump", { STUB_STRAY = "1" })
is("6 a write outside the generated surface stops the bump", v, "review:openspec-bump:1.0.0->2.0.0:paths-outside-generated-surface 6", err)
T:arm("6 and is named", text.contains(err, "stray.txt"), err)

-- The forge side: only the functions under test, from the shipped library or a mutant of them.
local function cut(name)
    local a = lib:find("\n" .. name .. "() {\n", 1, true)
    local b = a and select(2, lib:find("\n}\n", a, true))
    if not b then T:refuse("function-missing", name) end
    return lib:sub(a + 1, b)
end
local FUNCS = cut("openspec_pin_marker") .. cut("ensure_openspec_pinned") .. cut("ensure_forge_harnesses")
local FORGE = [[
trace_lifecycle() { :; }; harness_record_last_good() { :; }; harness_probe() { :; }; harness_last_good_file() { echo "$W/last-good-$1"; }
export HOME="$W/$FORGE_HOME"; mkdir -p "$HOME/.cache/tillandsias-project"
export NPM_CONFIG_PREFIX="$HOME/global" TILLANDSIAS_HARNESS_FALLBACK_DIR="$W/no-fallback"; PATH="$W/stubs:$PATH"
OS_BIN="$NPM_CONFIG_PREFIX/bin/openspec"; version() { echo "$1=$("$OS_BIN" --version)"; }
installs() { echo "$1=$(grep -c "^install .*$2" "$STUB_LOG")"; }; fresh() { : >"$STUB_LOG"; }
]]
local function forge(home, lines, funcs)
    local s, e2 = shell("FORGE_HOME=" .. home .. "\n" .. FORGE .. (funcs or FUNCS) .. lines)
    s = " " .. s:gsub("%s+", " ")
    return function(kv) return s:find(" " .. kv .. " ", 1, true) ~= nil end, s .. " " .. e2:sub(1, 200)
end
repo("forge-pinned", "1.0.0"); repo("forge-unpinned"); repo("forge-bad", "latest")
local PINNED = 'npm install -g --no-audit @fission-ai/openspec@latest\nversion before\nensure_openspec_pinned "$W/forge-pinned"\nversion after\n'
    .. 'echo "marker=$(cat "$(openspec_pin_marker)")"\n[ -e "$HOME/.cache/tillandsias-project/npm-update.lock" ] && echo lock-left\n'
local REFRESH = 'fresh; ( ensure_forge_harnesses ) >/dev/null 2>&1; installs openspec @fission-ai/openspec@latest; installs codex @openai/codex@latest; version refreshed\n'
local has, got = forge("h7", PINNED .. 'fresh; ensure_openspec_pinned "$W/forge-pinned"; installs warm .\n')
T:arm("7 a pinned project gets exactly its pin, not the @latest already installed", has("before=2.0.0") and has("after=1.0.0"), got)
T:arm("7 its marker is written, its lock released", has("marker=1.0.0") and not has("lock-left"), got)
T:arm("7 a warm launch installs nothing", has("warm=0"), got)
has, got = forge("h8", PINNED .. REFRESH)
T:arm("8 the background refresh leaves a pinned openspec alone", has("openspec=0") and has("refreshed=1.0.0"), got)
T:arm("8 CONTROL and still refreshes the others", has("codex=1"), got)
has, got = forge("h8u", PINNED .. 'rm -f "$(openspec_pin_marker)"\n' .. REFRESH)
T:arm("8 CONTROL an unpinned project still gets @latest", has("openspec=1") and has("refreshed=2.0.0"), got)
has, got = forge("h9", 'fresh; ensure_openspec_pinned "$W/forge-unpinned"; ensure_openspec_pinned "$W/forge-bad"; installs any .\n[ -e "$(openspec_pin_marker)" ] && echo marked\n')
T:arm("9 no pin, or one that is not a version, installs nothing and marks nothing", has("any=0") and not has("marked"), got)

for _, ep in ipairs{ "entrypoint-forge-claude.sh", "entrypoint-forge-opencode.sh", "entrypoint-forge-opencode-web.sh", "entrypoint-terminal.sh" } do
    local s = fs.read("images/default/" .. ep)
    local p, i = s:find('ensure_openspec_pinned "$PROJECT_DIR"', 1, true), s:find('openspec_init_if_absent "$PROJECT_DIR"', 1, true)
    T:arm("10 " .. ep .. " pins before it inits", p ~= nil and i ~= nil and p < i, tostring(p) .. "/" .. tostring(i))
end

-- MUTATION
local function swap(s, from, to)
    local a, b = s:find(from, 1, true)
    if not a then T:refuse("mutation-anchor-missing", from) end
    return s:sub(1, a - 1) .. to .. s:sub(b + 1)
end
fs.write(W.rel .. "/text-compare.sh", swap(pin_src, "sort -t. -k1,1n -k2,2n -k3,3n", "LC_ALL=C sort"))
is("11 MUTATION a pin compared as text fails arm 2", (pin(N, "check", { STUB_LATEST = "1.10.0" }, W.abs .. "/text-compare.sh")), "ok:openspec-pin-current:1.9.0 0")
has, got = forge("h11", PINNED .. REFRESH, swap(FUNCS, 'if [ "$bin" = openspec ] && [ -s "$(openspec_pin_marker)" ]; then', "if false; then"))
T:arm("11 MUTATION a refresh that does not know the pin fails arm 8", has("openspec=1") and has("refreshed=2.0.0"), got)
has, got = forge("h12", PINNED, swap(FUNCS, '"@fission-ai/openspec@$pin"', '"@fission-ai/openspec@latest"'))
T:arm("11 MUTATION an install that ignores the pin fails arm 7", has("after=2.0.0"), got)

T:finish()

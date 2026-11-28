-- @env PATH HOME TOOLBOX_PATH container
-- @trace order:799-tb7q, order:956-llei, order:2387-b6v2
--
-- test-tool-dispatch-lib.lua — scripts/lib/tool-dispatch.sh resolves a host tool to its bare name,
-- falls back to the documented toolbox invocation, and names a tooling gap when neither has it;
-- its callers use it, the self-contained scripts do not source it, and the walk-up source header
-- resolves at depth. Ported from the .sh of the same name (2387-b6v2). The lib is bash; bash sources it.
--
-- Usage: tillandsias-plan script run scripts/lua/test-tool-dispatch-lib.lua
-- Verdict: ok:tool-dispatch-lib:<n> arms | violation:...

local fixture = require "common.fixture"
-- Git's own bash on native Windows, never WSL's (2246-fkea).
local BASH = fixture.posix_shell()
local T = fixture.new("tool-dispatch-lib")
local ROOT = fixture.repo_root()
local LIB = ROOT .. "/scripts/lib/tool-dispatch.sh"
local w = T:scratch()
-- Source the lib and call one of its functions; stdout and stderr apart.
local function lib(path, fn, ...)
    local argv = { BASH, "-s", "--", LIB, fn, ... }
    -- A nested `toolbox run` (the fallback, from inside a toolbox) needs TOOLBOX_PATH and container.
    local r = proc.run{ argv = argv, stdin = '. "$1" || exit 9\nshift; "$@"\n', env = { PATH = path or env.get("PATH"), HOME = env.get("HOME"), TOOLBOX_PATH = env.get("TOOLBOX_PATH"), container = env.get("container") }, timeout_ms = 30000 }
    if r.code == 9 then T:refuse("cannot-source-the-lib", LIB) end
    return text.trim(r.stdout or ""), r.stderr or "", r.code
end
local function src(f) return fs.read(f) end
local function lines(s) local l = {}; for x in ((s or "") .. "\n"):gmatch("([^\n]*)\n") do l[#l + 1] = x end; return l end
local function comment(x) return x:match("^%s*#") ~= nil end
-- Uncommented lines of f matching any Lua pattern in pats.
local function hits(f, pats)
    local n = {}
    for i, x in ipairs(lines(src(f))) do
        if not comment(x) then for _, p in ipairs(pats) do if x:find(p) then n[#n + 1] = f .. ":" .. i; break end end end
    end
    return n
end

if fixture.which("jq") then
    local got = lib(nil, "resolve_tool", "jq")
    T:arm("host tool present -> bare name (no toolbox round trip)", got == "jq", "resolved '" .. got .. "' when a host jq exists")
else out.line("skip: no host jq: cannot exercise the host arm here") end
local got, _, rc = lib(nil, "resolve_tool", "definitely-not-a-real-tool-xyz")
T:arm("a tool that exists nowhere resolves to nothing, non-zero", rc ~= 0 and got == "", "rc=" .. tostring(rc) .. " [" .. got .. "]")
local _, err = lib(nil, "require_tool", "definitely-not-a-real-tool-xyz")
T:arm("the diagnosis names BOTH host and toolbox", err:find("host.*toolbox") ~= nil or err:find("toolbox.*host") ~= nil, err)
T:arm("names it a tooling gap, not a fault in the inspected thing", text.contains(err, "TOOLING gap"), err)

-- A PATH holding every /usr/bin tool but jq.
local mask = w.abs .. "/nojq"
T:must{ BASH, "-s", "--", mask, stdin = 'mkdir -p "$1"; for t in /usr/bin/*; do b=${t##*/}; [ "$b" = jq ] || ln -sf "$t" "$1/$b" 2>/dev/null; done; :\n' }
local function on_mask(tool) return T:run{ BASH, "-s", "--", mask, tool, stdin = 'PATH="$1" command -v "$2" >/dev/null 2>&1\n' }.code == 0 end
if on_mask("jq") then
    T:arm("PRECONDITION: jq is unreachable on the masked PATH", false, "jq still reachable — the fallback arm would test nothing")
elseif not on_mask("toolbox") then
    out.line("skip: no toolbox on this host: the fallback arm is not applicable")
else
    got = lib(mask, "resolve_tool", "jq")
    T:arm("host tool absent -> the documented toolbox invocation", got == "toolbox run --container tillandsias-builder jq", "'" .. got .. "'")
end

local bare_jq = {}
for _, f in ipairs{ "scripts/cycle-metrics.sh", "scripts/select-work-batch.sh", "scripts/local-ci.sh", "scripts/check-stranded-in-progress.sh",
                    "scripts/check-mcp-expert-health.sh", "scripts/generate-dashboard.sh", "scripts/manage-cache.sh", "scripts/host-capability-probe.sh" } do
    if #hits(f, { "| jq ", "^%s*jq ", "%$%(jq " }) > 0 then bare_jq[#bare_jq + 1] = f end
end
T:arm("the converted callers route jq through the dispatch", #bare_jq == 0, table.concat(bare_jq, " ") .. " still call jq bare")
local SOURCES = { "^%s*%.%s+.*lib/tool%-dispatch%.sh", "^%s*source%s+.*lib/tool%-dispatch%.sh" }
local self_contained = {}
for _, f in ipairs{ "scripts/install-macos.sh", "scripts/with-tillandsias-builder.sh", "scripts/with-wsl2-builder.sh" } do
    if fs.exists(f) and #hits(f, SOURCES) > 0 then self_contained[#self_contained + 1] = f end
end
T:arm("curl-piped installer and toolbox bootstrap wrappers stay self-contained", #self_contained == 0, table.concat(self_contained, " ") .. " SOURCES the shared lib")

-- $JQ inside a heredoc body: the generated script's scope has no such variable. The awk is the
-- .sh's, run once over every tracked script (FNR resets the terminator per file).
local AWK = [[FNR == 1 { term = "" }
term == "" {
    if (match($0, /<<-?[ \t]*"?'?[A-Za-z_][A-Za-z0-9_]*"?'?/)) { t = substr($0, RSTART, RLENGTH); gsub(/[<\-\t "']/, "", t); term = t }
    next
}
{ s = $0; gsub(/^[ \t]+|[ \t]+$/, "", s); if (s == term) { term = ""; next }; if (index($0, needle) > 0) print FILENAME ":" FNR }
]]
local files = { "awk", "-v", "needle=\"$JQ\"", AWK }
for f in (T:run{ "git", "-C", ROOT, "ls-files", "scripts/*.sh" }.stdout or ""):gmatch("[^\n]+") do files[#files + 1] = f end
local hd = proc.run{ argv = files, cwd = ROOT, timeout_ms = 120000 }
T:arm("no $JQ inside any heredoc — generated scripts keep bare jq", hd.code == 0 and text.trim(hd.stdout or "") == "", "$JQ appears inside a heredoc: " .. tostring(hd.status) .. " " .. (hd.stdout or "") .. (hd.stderr or hd.why or ""))

local ssl = {}
for _, f in ipairs{ "scripts/diagnose-proxy.sh", "scripts/run-forge-project.sh", "scripts/orchestrate-enclave.sh" } do
    if not text.contains(src(f), "resolve_tool openssl") then ssl[#ssl + 1] = f .. " does not resolve openssl through the dispatch" end
    if #hits(f, { "^%s*openssl ", "| openssl ", "%$%(openssl " }) > 0 then ssl[#ssl + 1] = f .. " still calls openssl bare" end
end
T:arm("the converted openssl callers resolve it through the dispatch", #ssl == 0, table.concat(ssl, "; "))
local certs = {}
for _, f in ipairs{ "scripts/diagnose-proxy.sh", "scripts/run-forge-project.sh", "scripts/orchestrate-enclave.sh" } do
    local cd = src(f):match('CERTS_DIR="?[^"\n]*"?') or ""
    if not (text.contains(cd, "mktemp") or text.contains(cd, "/tmp/") or text.contains(cd, "TILLANDSIAS_CA_DIR")) then certs[#certs + 1] = f .. ": " .. cd end
end
T:arm("every converted openssl caller writes under a MEASURED shared root (/tmp or the CA dir)", #certs == 0, table.concat(certs, "; "))

-- The walk-up header resolves the lib one level down; the old fixed-depth one does not.
local d = w.rel .. "/depthrepo"
fs.mkdir(d .. "/scripts/lib"); fs.mkdir(d .. "/scripts/sub")
fs.write(d .. "/scripts/lib/tool-dispatch.sh", src("scripts/lib/tool-dispatch.sh"))
fs.write(d .. "/scripts/sub/caller.sh", [[#!/usr/bin/env bash
set -euo pipefail
_td_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
while [ -n "$_td_dir" ] && [ "$_td_dir" != "/" ] && [ ! -f "$_td_dir/lib/tool-dispatch.sh" ]; do
    _td_dir="$(dirname "$_td_dir")"
done
if [ -f "$_td_dir/lib/tool-dispatch.sh" ]; then
    . "$_td_dir/lib/tool-dispatch.sh" 2>/dev/null || true
fi
command -v resolve_tool >/dev/null 2>&1 && echo RESOLVER-PRESENT || echo RESOLVER-ABSENT
]])
fs.write(d .. "/scripts/sub/old-caller.sh", [[#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/tool-dispatch.sh" 2>/dev/null || true
command -v resolve_tool >/dev/null 2>&1 && echo RESOLVER-PRESENT || echo RESOLVER-ABSENT
]])
local DA = w.abs .. "/depthrepo/scripts/sub/"
T:arm("a caller one level down resolves the lib (walk-up header)", text.trim(T:run{ BASH, DA .. "caller.sh" }.stdout or "") == "RESOLVER-PRESENT", "conversions at depth are silent no-ops")
T:arm("MUTATION: the old fixed-depth header silently fails at depth", text.trim(T:run{ BASH, DA .. "old-caller.sh" }.stdout or "") ~= "RESOLVER-PRESENT", "the old header resolved at depth; the walk-up arm is not testing what it claims")
local fixed = T:run{ "grep", "-rnF", 'dirname "${BASH_SOURCE[0]}")/lib/tool-dispatch.sh', ROOT .. "/scripts" }
local back = {}
for l in (fixed.stdout or ""):gmatch("[^\n]+") do
    -- This port and the .sh it replaced quote the old header as a planted subject.
    if not l:match("^[^:]*:%d+:%s*#") and not l:find("/scripts/lua/test%-tool%-dispatch%-lib%.lua:") and not l:find("/scripts/test%-tool%-dispatch%-lib%.sh:") then back[#back + 1] = l end
end
T:arm("no caller carries the fixed-depth source path", #back == 0, #back .. " site(s): " .. table.concat(back, " "):sub(1, 300))

local shipped = {}
for _, f in ipairs{ "scripts/tray-diagnose.sh", "scripts/diagnose-macos-provision.sh" } do
    if #hits(f, SOURCES) > 0 then shipped[#shipped + 1] = f .. " SOURCES the shared lib" end
    if not text.contains(src(f), "toolbox run --container tillandsias-builder jq") then shipped[#shipped + 1] = f .. " lost its inline dispatch" end
end
T:arm("shipped diagnostics keep self-contained inline dispatch (deliberate, guarded)", #shipped == 0, table.concat(shipped, "; "))
local fallback = {}
for _, f in ipairs{ "scripts/cycle-metrics.sh", "scripts/select-work-batch.sh", "scripts/local-ci.sh" } do
    if not text.contains(src(f), 'JQ="jq"') then fallback[#fallback + 1] = f end
end
T:arm("a missing lib degrades callers to the previous behaviour, not to a crash", #fallback == 0, table.concat(fallback, " ") .. " has no literal-jq fallback")
T:finish()

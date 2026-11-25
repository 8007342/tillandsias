-- @env PATH HOME
-- @trace spec:git-mirror-service, order:770-ifeg, order:2373-8vq6
--
-- test-pre-receive-yaml-gate.lua — the mirror's pre-receive hook refuses ledger YAML that does not
-- parse, and its branch, salvage and workflow rules act only when configured. Ported from the .sh
-- of the same name (2373-8vq6). Scratch mirrors with the shipped hook and the real tillandsias-policy.
--
--   1 invalid YAML is refused    2 valid is accepted    3 one bad ref refuses a two-ref push
--   4 a new branch is judged from its base, not on a broken file it inherits
--   5 grammar: silent unconfigured, warn-only outside it, silent inside it
--   6 salvage: refused unconfigured, accepted when exempt, and only there
--   7 workflows: allowed, refused, deletable, and silent unconfigured
--
-- Usage: tillandsias-plan script run scripts/lua/test-pre-receive-yaml-gate.lua
-- Verdict: ok:pre-receive-yaml-gate:<n> arms | violation:... | skip:...:no-policy-binary

local fixture = require "common.fixture"
local T = fixture.new("pre-receive-yaml-gate")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
if fixture.which("cargo") then
    local r = proc.run{ argv = { "cargo", "build", "-q", "-p", "tillandsias-policy" }, cwd = ROOT, timeout_ms = 280000 }
    local o = (r.stdout or "") .. (r.stderr or "")
    -- A bare host has cargo and no linker: it uses what a toolbox built, if anything.
    if r.code ~= 0 and not text.contains(o, "linker `cc` not found") then T:refuse("policy-build-failed", o:sub(-600)) end
end
local found = proc.run{ argv = { SH, "-s", "--", ROOT }, cwd = ROOT, timeout_ms = 60000, stdin = '. "$1/scripts/plan-binary-probe.sh"\nresolve_target_binary tillandsias-policy debug "$1" 2>/dev/null\n' }
local POLICY = text.trim(found.stdout or "")
if found.code ~= 0 or POLICY == "" then T:skip("no-policy-binary") end
if not fixture.is_abs(POLICY) then POLICY = ROOT .. "/" .. POLICY:gsub("^%./", "") end
local w = T:scratch()
fs.mkdir(w.rel .. "/bin")
T:must{ "ln", "-s", POLICY, w.abs .. "/bin/tillandsias-policy" }
local PRE = [==[
set -u
W="$1"; R="$2"; PATH="$W/bin:$PATH"; export PATH; G="git -c init.defaultBranch=main"
mirror() { $G init -q --bare "$W/$1"; mkdir -p "$W/$1/hooks"; $G -C "$W/$1" config core.hooksPath "$W/$1/hooks"
    cp "$R/images/git/pre-receive-hook.sh" "$W/$1/hooks/pre-receive"; cp "$R/images/git/relay-refs.sh" "$W/$1/hooks/tillandsias-relay-refs"
    chmod +x "$W/$1/hooks/pre-receive" "$W/$1/hooks/tillandsias-relay-refs"; }
client() { $G init -q "$W/$1"; $G -C "$W/$1" config core.hooksPath ""; $G -C "$W/$1" remote add origin "$W/$2"; mkdir -p "$W/$1/plan"; }
put() { mkdir -p "$(dirname "$W/$1/$2")"; cat >"$W/$1/$2"; }
good() { printf 'plan:\n  version: v1\n  name: %s\n' "${2:-test}" | put "$1" plan/index.yaml; }
bad() { printf 'plan:\n  version: v1\n  broken yaml: [[[\n' | put "$1" "${2:-plan/index.yaml}"; }
save() { $G -C "$W/$1" add -A; $G -C "$W/$1" commit -qm "$2"; }
push() { c="$1"; shift; rc=0; $G -C "$W/$c" push origin "$@" 2>&1 || rc=$?; echo "rc=$rc"; }
wf() { printf 'name: w\non: [push]\njobs:\n  c:\n    runs-on: ubuntu-latest\n    steps: [{run: "echo"}]\n' | put "$1" ".github/workflows/$2"; }
]==]
local function sh(body, more)
    local e = { PATH = env.get("PATH"), HOME = w.abs, GIT_CONFIG_NOSYSTEM = "1", LANGUAGE = "en", GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@example.invalid", GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@example.invalid" }
    for k, v in pairs(more or {}) do e[k] = v end
    local r = proc.run{ argv = { SH, "-s", "--", w.abs, ROOT }, cwd = w.abs, stdin = PRE .. body, env = e, env_unset = { "TILLANDSIAS_*", "GIT_*" }, timeout_ms = 60000 }
    local o = "\n" .. (r.stdout or ""):gsub("\r", "") .. (r.stderr or "")
    local last
    for rc in o:gmatch("\nrc=(%d+)") do last = rc end
    return { ok = last == "0", refused = last ~= nil and last ~= "0", out = o, why = "rc=" .. tostring(last) .. o:sub(1, 600) }
end
local x = sh "mirror m; client c m; bad c; save c broken; push c HEAD:main"
T:arm("1 invalid ledger YAML is refused, naming the file", x.refused and text.contains(x.out, "plan/index.yaml"), x.why)
x = sh "good c; save c valid; push c HEAD:main"
T:arm("2 valid YAML is accepted", x.ok, x.why)
x = sh 'client c2 m; good c2; save c2 valid; push c2 HEAD:refs/heads/valid-branch; $G -C "$W/c2" branch valid-branch; $G -C "$W/c2" checkout -q -b broken-branch; bad c2; save c2 broken; push c2 valid-branch broken-branch'
T:arm("3 one broken ref refuses a two-ref push", x.refused and text.contains(x.out, "plan/index.yaml"), x.why)
x = sh [==[
mirror m4; client c4 m4; good c4 parent; save c4 seed; push c4 HEAD:main
bad c4 plan/legacy.yaml; save c4 legacy
# The legacy file predates the gate, and the mirror tracks upstream as a relay leaves it.
mv "$W/m4/hooks" "$W/m4/hooks.off"; mkdir "$W/m4/hooks"; push c4 HEAD:main; rmdir "$W/m4/hooks"; mv "$W/m4/hooks.off" "$W/m4/hooks"; $G -C "$W/m4" update-ref refs/remotes/origin/main refs/heads/main
$G -C "$W/c4" checkout -q -b feature/new-branch; good c4 new; save c4 new; push c4 feature/new-branch
]==]
T:arm("4 a new branch is judged from its base, not on an inherited broken file", x.ok and select(2, x.out:gsub("\nrc=0", "")) == 3, x.why)
local REGEX = "^refs/heads/(main|gh-pages|(linux|windows|osx)-next|release/[A-Za-z0-9._/-]+|agent/[a-z0-9][a-z0-9-]{0,31}/[a-z0-9][a-z0-9._-]{0,47}/20[0-9]{6}-[a-z0-9][a-z0-9-]{0,47})$"
x = sh "push c HEAD:refs/heads/wip-freeform-noenv"
T:arm("5a with no grammar a new branch is accepted silently", x.ok and not text.contains(x.out, "WARNING: new branch"), x.why)
x = sh("push c HEAD:refs/heads/wip-out-of-grammar", { TILLANDSIAS_BRANCH_CREATION_REGEX = REGEX, TILLANDSIAS_BRANCH_GRAMMAR_HINT = "main | agent/<host>/<base>/<yyyymmdd>-<slug>" })
T:arm("5b outside it: accepted with a warning that says warn-only", x.ok and text.contains(x.out, "WARNING: new branch") and text.contains(x.out, "warn-only"), x.why)
x = sh("push c HEAD:refs/heads/agent/testhost/linux-next/20260728-mode-a-1", { TILLANDSIAS_BRANCH_CREATION_REGEX = REGEX })
T:arm("5c inside it: silent", x.ok and not text.contains(x.out, "WARNING: new branch"), x.why)
local EX = { TILLANDSIAS_YAML_GATE_EXEMPT_REFS = "refs/heads/salvage/*" }
x = sh '$G -C "$W/c" checkout -q -b salvage-src; bad c; save c salvage; push c HEAD:refs/heads/salvage/testhost/20260728-triage-a'
T:arm("6a a broken salvage is refused with no exemption", x.refused, x.why)
x = sh("push c HEAD:refs/heads/salvage/testhost/20260728-triage-a", EX)
T:arm("6b accepted under the exemption", x.ok, x.why)
x = sh("push c HEAD:refs/heads/not-salvage", EX)
T:arm("6c which covers nothing else", x.refused, x.why)
local CI = { TILLANDSIAS_CI_WORKFLOW_ALLOWLIST = "release.yml" }
x = sh('$G -C "$W/c" checkout -q -b wf-src; good c; wf c release.yml; save c allowed; push c HEAD:refs/heads/wf-allowed', CI)
T:arm("7a an allowed workflow is accepted", x.ok, x.why)
x = sh("wf c ci.yml; save c unsanctioned; push c HEAD:refs/heads/wf-rejected", CI)
T:arm("7b an unsanctioned one is refused, by name", x.refused and text.contains(x.out, "ci.yml"), x.why)
x = sh('$G -C "$W/c" rm -q .github/workflows/ci.yml; save c removed; push c HEAD:refs/heads/wf-deletion', CI)
T:arm("7c deleting it is accepted", x.ok, x.why)
x = sh '$G -C "$W/c" checkout -q -b wf-neutral; wf c ci.yml; save c end-user; push c HEAD:refs/heads/wf-unconfigured'
T:arm("7d with no allowlist the gate is silent", x.ok, x.why)
T:finish()

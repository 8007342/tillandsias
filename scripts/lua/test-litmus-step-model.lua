-- @env PATH
-- @trace order:901-jtvi, order:2369-8vq3
--
-- test-litmus-step-model.lua — the litmus step model (mf_run, mf_stage, mf_holds*, mf_lacks*, mf_first) in
-- scripts/litmus-stdlib.sh. Every arm is a property the PIPED idiom cannot hold: a failing producer is the
-- verdict, an intentional non-zero is expressible, first-N does not kill the producer, stderr is kept.
-- The model is bash, so each arm is a bash snippet. Ported from the .sh of the same name.
--
-- Usage: tillandsias-plan script run scripts/lua/test-litmus-step-model.lua
-- Verdict: ok:litmus-step-model:<n> arms | violation:litmus-step-model:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("litmus-step-model")
local SH, ROOT = fixture.posix_shell(), fixture.repo_root()
local LIB = "scripts/litmus-stdlib.sh"
if not fs.exists(LIB) then T:refuse("subject-missing") end
local W = T:scratch()
local src = fs.read(LIB):gsub("\r\n", "\n")

-- 1096-p3tn: the timing log is this fixture's own.
local function sh(body, lib)
    local r = proc.run{ argv = { SH, "-s", "--", lib or (ROOT .. "/" .. LIB) }, cwd = ROOT, timeout_ms = 60000, stdin = '. "$1" || exit 96\n' .. body,
        env_unset = { "TILLANDSIAS_*" }, env = { PATH = env.get("PATH"), TILLANDSIAS_TIMING_LOG = W.abs .. "/timing-fixture.jsonl" } }
    if r.code == 96 then T:refuse("stdlib-does-not-source", tostring(r.stderr)) end
    return r.code, "rc=" .. tostring(r.code) .. " " .. (r.stdout or "") .. (r.stderr or "")
end
local function arm(name, want, body, lib)
    local rc, o = sh(body, lib)
    T:arm(name, rc == want, o)
end
local FAILING = [[mf_stage producer 0 SRC -- sh -c 'echo "cargo build"; exit 7']]

arm("1 PREMISE without pipefail the piped form masks exit 7", 0, [[set +o pipefail; sh -c 'echo "cargo build"; exit 7' | grep -q "cargo build"]])
arm("1 a failing producer is the verdict", 1, FAILING .. " && exit 0; exit 1")
arm("2 CONTROL a passing producer passes", 0, [[mf_stage producer 0 OK1 -- sh -c 'echo "cargo build"' && mf_holds OK1 'cargo build']])
arm("3 an intentional non-zero is expressible", 0, [[mf_stage usage 2 U -- sh -c 'echo "usage: capability"; exit 2' && mf_holds U 'capability']])
arm("4 first-N reads a finished buffer; the producer lives", 0,
    [[mf_stage long 0 BIG -- sh -c 'i=1; while [ $i -le 5000 ]; do echo "line $i"; i=$((i+1)); done' && [ "$(mf_first BIG 2)" = "line 1
line 2" ] ]])
arm("5 stderr is captured", 0, [[mf_run E -- sh -c 'echo "to-stderr" >&2'; mf_holds E 'to-stderr']])
local code = ("\n" .. src):gsub("\n%s*#[^\n]*", "\n")
T:arm("6 the model does not use PIPESTATUS, which zsh leaves empty", not text.contains(code, "PIPESTATUS"), "used")
-- 7 the flag is part of the assertion: 'a+b' means opposite things in BRE and ERE.
arm("7 mf_holds is BRE and mf_holds_ere is ERE", 0, [[V='a+b'; mf_holds V 'a+b' && mf_lacks_ere V 'a+b']])
arm("7 and they disagree the other way too", 0, [[V=aab; mf_holds_ere V 'a+b' && mf_lacks V 'a+b']])
arm("7 a literal brace survives the BRE consumer", 0, [[V='fail:enclave-service-dead:service={name}:state={state}'; mf_holds V 'service={name}']])
arm("7 mf_holds_literal is fixed-string", 0, [[V=a.c; mf_holds_literal V 'a.c' && mf_lacks_literal V 'abc']])
arm("7 mf_holds_line is whole-line", 0, [[V=exact; mf_holds_line V exact && mf_lacks_line V exac]])

-- MUTATION: later definitions win, so the mutants override one function.
local function mutant(name, body)
    fs.write(W.rel .. "/" .. name .. ".sh", src .. "\n" .. body .. "\n")
    return W.abs .. "/" .. name .. ".sh"
end
arm("8 MUTATION a stage that ignores its producer fails arm 1", 0, FAILING .. " && exit 0; exit 1",
    mutant("stage", 'mf_stage() { shift 4; "$@" >/dev/null 2>&1; return 0; }'))
arm("8 MUTATION an ERE mf_holds fails arm 7", 1, [[V='a+b'; mf_holds V 'a+b' && mf_lacks_ere V 'a+b' && exit 0; exit 1]],
    mutant("ere", 'mf_holds() { mf_holds_ere "$@"; }'))

T:finish()

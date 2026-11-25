-- @env PATH HOME
-- @trace order:1136-n8sh, order:977-448j, order:885-92iu, order:2314-ktxt
--
-- test-closure-guards-name-the-way-out.lua — a packet whose DELIVERABLE IS A NEW TEST is
-- refused from both sides, and each refusal must name the other and the sanctioned exit.
-- Ported from the .sh of the same name (2314-ktxt); same checks. The bind is intended; what
-- was missing was that the refusals did not say so. A filer who read only guard 2 would
-- delete the pin and land back in guard 1; one who read only guard 1 would leave it dangling
-- (1068-cxmf).
--
-- Both arms EXECUTE the real guard on a probe packet and read what it prints. Guard 1 reads
-- the git index, so it runs in a scratch repo (the .sh used a worktree of the checkout).
--
-- Usage: tillandsias-plan script run scripts/lua/test-closure-guards-name-the-way-out.lua
-- Verdict: ok:closure-guards-name-the-way-out:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("closure-guards-name-the-way-out")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
-- REFUSE, never skip: a missing binary is how guard 2 stops being checked while reading green.
if PLAN == "" then T:refuse("no-plan-binary", "cargo build -p tillandsias-plan") end
local EXIT_FORM = "unpinnable-until-the-guard-exists"

local d = T:git_repo()
fs.mkdir(d.rel .. "/scripts"); fs.mkdir(d.rel .. "/plan/index.d")
for _, f in ipairs{ "check-scorable-obligation-added.sh", "plan-binary-probe.sh" } do fs.write(d.rel .. "/scripts/" .. f, fs.read("scripts/" .. f)) end
local stamp = text.trim(T:must{ "date", "-u", "+%Y%m%dt%H%M%Sz" }.stdout)
local frag = "plan/index.d/" .. stamp .. "-9999-zzzz-closure-guard-probe.yaml"
-- No obligation of any kind: the shape a new-test packet starts out in.
fs.write(d.rel .. "/" .. frag, "packets:\n  - packet_id: probe-a-packet-whose-deliverable-is-a-new-test\n    order: 9999-zzzz\n"
    .. "    status: ready\n    title: probe row for the 1136-n8sh fixture, with no obligation on purpose\n")
T:must{ "git", "-C", d.abs, "add", frag }
local e = { PATH = env.get("PATH"), HOME = env.get("HOME"), TILLANDSIAS_PLAN_BIN = PLAN }
local r = T:run{ SH, d.abs .. "/scripts/check-scorable-obligation-added.sh", "HEAD", cwd = d.abs, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
local g1 = (r.stdout or "") .. (r.stderr or "")
T:arm("1 guard 1 refuses a packet with no obligation", r.code == 1 and text.contains(g1, "scorable-obligation-missing"), tostring(r.code) .. " " .. g1)
T:arm("2 guard 1 names the sanctioned exit", text.contains(g1, EXIT_FORM), g1)
T:arm("3 guard 1 names its counterpart 885-92iu", text.contains(g1, "885-92iu"), g1)

-- The pin token is ASSEMBLED: check-litmus-pin-claims.sh reads the whole form in a source as
-- this file claiming a test of that name.
local pin = "lit" .. "mus" .. ":a-test-this-packet-has-not-written-yet"
fs.write(d.rel .. "/pin.yaml", "packets:\n  - packet_id: probe-a-packet-that-pins-its-own-future-test\n    order: 9999-zzzz\n"
    .. "    status: ready\n    verifiable_closure: \"" .. pin .. "\"\n")
r = T:run{ PLAN, "declared-closures-check", d.abs .. "/pin.yaml", cwd = ROOT, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
local g2 = (r.stdout or "") .. (r.stderr or "")
T:arm("4 guard 2 refuses a pin nothing defines and names the row", r.code == 1 and text.contains(g2, "violation:declared-closure-unresolvable:1")
    and text.contains(g2, "declared-closure-unresolvable: "), tostring(r.code) .. " " .. g2)
T:arm("5 guard 2 names the sanctioned exit", text.contains(g2, EXIT_FORM), g2)
T:arm("6 guard 2 names its counterpart 977-448j", text.contains(g2, "977-448j"), g2)
T:arm("7 guard 2 names the dangling-pin defect 1068-cxmf", text.contains(g2, "1068-cxmf"), g2)
T:finish()

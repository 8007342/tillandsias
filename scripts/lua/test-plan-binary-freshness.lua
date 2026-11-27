-- @trace order:851-cduu, order:1129-4su6, order:1287-h6qn, order:2212-2m8s
-- inputs: scripts/hooks/pre-push-local-gate.sh scripts/plan-binary-probe.sh scripts/gate-stamp.sh scripts/common.sh scripts/check-issue-citation-convention.sh lib/lua/common/ crates/tillandsias-plan/ Cargo.lock plan/index.yaml scripts/lua/check-fragment-status-loss.lua scripts/with-wsl2-builder.sh
--
-- test-plan-binary-freshness.lua — PORTED from test-plan-binary-freshness.sh
-- (2212-2m8s), same cases, same lines. Point-of-use instrument freshness.
--
-- resolve_plan_binary proves the artifact RUNS, not that it matches the
-- checkout; a stale instrument does not fail, it answers wrong. Cases A–E pin
-- ensure_fresh_plan_binary's contract:
--   rc 0 + path — current (or rebuilt-in-locus) binary
--   rc 1 silent — no runnable binary at all
--   rc 2 silent — stale and NOT refreshable here
--   override    — TILLANDSIAS_PLAN_BIN passes through on existence alone
-- The function under test is bash (scripts/plan-binary-probe.sh), so each case
-- sources it from a helper FILE, in the fake checkout, exactly as the .sh's
-- subshell did; stubs, mtimes and assertions are here.
--
-- Then the pre-push plan-only lane (1129-4su6) must REFUSE a stale validator
-- (refuse, never rebuild inside a hook), name staleness, the newer file and a
-- typeable remedy; a CURRENT binary is not refused (control); and the content
-- contract (1287-h6qn): a binary that vouches for its surface is accepted, a
-- real difference is refused naming both hashes, and a binary that cannot
-- ANSWER falls back to the mtime ladder.
--
-- HERMETIC: fake trees under target/plan-scratch with their own origin, never
-- the real checkout's HEAD or target/ (2196-rdec: clean by construction).
-- mtimes are set with POSIX `touch -t`, and the control arm's "now" with a
-- plain `touch` (a literal stamp there is a fixture with an expiry date).
--
-- 1680-yf9z: the resolver prints $PWD, which bash normalises. The helper is
-- handed the fake checkout with a DELIBERATELY doubled slash and the arms
-- expect the normalised path, so a regression is red on every platform.
--
-- Verdict: ok:plan-binary-freshness:<n> | violation:plan-binary-freshness:<f>

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local pass, fail = 0, 0
local function ck(desc, want, got)
    if want == got then out.line("  ok   " .. desc); pass = pass + 1
    else out.line("  FAIL " .. desc .. " (expected " .. want .. ", got " .. got .. ")"); fail = fail + 1 end
end
local function has(s, p) return (s or ""):find(p, 1, true) ~= nil end

local stamp = tostring(time.now_ms())
local relT = "target/plan-scratch/plan-binary-freshness-" .. stamp
local TMPD = root .. "/" .. relT
local DOUBLED = root .. "/target/plan-scratch//plan-binary-freshness-" .. stamp
local relL = "target/plan-scratch/lane-stale-" .. stamp
local LW = root .. "/" .. relL
local function cleanup()
    proc.run{ argv = { "find", TMPD, "-delete" }, timeout_ms = 60000 }
    proc.run{ argv = { "find", LW, "-delete" }, timeout_ms = 60000 }
end
local function touch_t(t, ...)
    local a = { "touch", "-t", t }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    proc.run{ argv = a }
end
local function chmodx(p) proc.run{ argv = { "chmod", "+x", p } } end

-- A fake checkout: the instrument's vintage source set, a runnable stub
-- "binary", and a bin dir whose `cargo` each case controls.
proc.run{ argv = { "mkdir", "-p", TMPD .. "/crates/tillandsias-plan/src", TMPD .. "/target/release", TMPD .. "/bin" } }
fs.write(relT .. "/crates/tillandsias-plan/src/main.rs", "fn main() {}\n")
fs.write(relT .. "/Cargo.lock", "# lock\n")
local BIN = TMPD .. "/target/release/tillandsias-plan"
fs.write(relT .. "/target/release/tillandsias-plan",
    '#!/usr/bin/env bash\n[ "${1:-}" = "capabilities" ] && { echo compact; exit 0; }\nexit 0\n')
chmodx(BIN)

local function set_mtimes(bin_t, src_t)
    touch_t(bin_t, BIN)
    touch_t(src_t, TMPD .. "/crates/tillandsias-plan/src/main.rs", TMPD .. "/crates/tillandsias-plan", TMPD .. "/Cargo.lock")
end

-- The helpers: the .sh's subshells, as FILES. $1 the checkout to cd into
-- (doubled slash), $2 the normalised one (for PATH), $3 the real root.
fs.write("target/plan-scratch/freshness-case-" .. stamp .. ".sh", [[
cd "$1" || exit 99
unset CARGO_TARGET_DIR TILLANDSIAS_PLAN_BIN
PATH="$2/bin:$PATH"
. "$3/scripts/plan-binary-probe.sh"
out="$(ensure_fresh_plan_binary)"; rc=$?
printf '%s\nrc=%d\n' "$out" "$rc"
]])
fs.write("target/plan-scratch/freshness-override-" .. stamp .. ".sh", [[
cd "$1" || exit 99
unset CARGO_TARGET_DIR
export TILLANDSIAS_PLAN_BIN="$2/target/release/tillandsias-plan"
. "$3/scripts/plan-binary-probe.sh"
o="$(ensure_fresh_plan_binary)"; rc=$?
printf '%s\nrc=%d\n' "$o" "$rc"
]])
local CASE_SH = root .. "/target/plan-scratch/freshness-case-" .. stamp .. ".sh"
local OVR_SH = root .. "/target/plan-scratch/freshness-override-" .. stamp .. ".sh"

-- `printf '%s' "$out" | head -1` / `tail -1` over the captured output.
local function first_last(s)
    local ls = text.lines((s or ""):gsub("\n+$", ""))
    return ls[1] or "", ls[#ls] or ""
end
local function run_case(mode)
    if mode == "none" then
        proc.run{ argv = { "find", TMPD .. "/bin", "-maxdepth", "1", "-name", "cargo", "-delete" } }
    elseif mode == "fail" then
        fs.write(relT .. "/bin/cargo", "#!/usr/bin/env bash\nexit 1\n"); chmodx(TMPD .. "/bin/cargo")
    elseif mode == "touch" then
        fs.write(relT .. "/bin/cargo", "#!/usr/bin/env bash\ntouch target/release/tillandsias-plan\nexit 0\n")
        chmodx(TMPD .. "/bin/cargo")
    end
    -- SHADOW ANY PATH-INSTALLED tillandsias-plan with one that fails its probe.
    fs.write(relT .. "/bin/tillandsias-plan", "#!/usr/bin/env bash\nexit 127\n"); chmodx(TMPD .. "/bin/tillandsias-plan")
    return first_last(proc.run{ argv = { "bash", CASE_SH, DOUBLED, TMPD, root }, timeout_ms = 120000 }.stdout)
end

-- ── case A: binary newer than every source → fresh, no cargo consulted ──────
set_mtimes("202601020000", "202601010000")
local h, t = run_case("none")
ck("fresh binary resolves", "rc=0", t)
ck("fresh binary prints its path", BIN, h)

-- ── case B: source newer, rebuild fails → rc 2, silent ──────────────────────
set_mtimes("202601020000", "202601030000")
h, t = run_case("fail")
ck("stale + failed rebuild returns 2", "rc=2", t)
ck("stale + failed rebuild is silent", "", h)

-- ── case C: source newer, rebuild heals → rc 0, path printed ────────────────
set_mtimes("202601020000", "202601030000")
h, t = run_case("touch")
ck("stale + rebuild-in-locus heals", "rc=0", t)
ck("healed binary prints its path", BIN, h)

-- ── case D: no binary at all, rebuild fails → rc 1 (resolve contract) ───────
proc.run{ argv = { "mv", BIN, TMPD .. "/stashed-binary" } }
h, t = run_case("fail")
ck("no binary returns 1", "rc=1", t)
proc.run{ argv = { "mv", TMPD .. "/stashed-binary", BIN } }

-- ── case E: explicit override passes through on existence alone ─────────────
set_mtimes("202601020000", "202601030000")   -- stale by mtime, on purpose
h, t = first_last(proc.run{ argv = { "bash", OVR_SH, DOUBLED, TMPD, root }, timeout_ms = 120000 }.stdout)
ck("override honoured despite staleness", "rc=0", t)
ck("override path passes through", BIN, h)

-- ── ORDER 1129-4su6: THE PRE-PUSH LANE MUST REFUSE A STALE VALIDATOR ────────
local WC = LW .. "/wc"
local function LG(args)
    local a = { "git", "-C", WC, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs(args) do a[#a + 1] = x end
    return proc.run{ argv = a, timeout_ms = 60000 }
end
proc.run{ argv = { "mkdir", "-p", LW } }
proc.run{ argv = { "git", "init", "-q", "--bare", LW .. "/bare.git" } }
proc.run{ argv = { "git", "init", "-q", "-b", "linux-next", WC } }
LG({ "remote", "add", "origin", LW .. "/bare.git" })
LG({ "config", "core.hooksPath", ".git/hooks" })
proc.run{ argv = { "mkdir", "-p", WC .. "/scripts/hooks", WC .. "/plan/index.d", WC .. "/crates/tillandsias-plan/src",
    WC .. "/target/release", WC .. "/scripts/lua" } }
proc.run{ argv = { "cp", "scripts/hooks/pre-push-local-gate.sh", WC .. "/scripts/hooks/" } }
for _, f in ipairs({ "plan-binary-probe.sh", "gate-stamp.sh", "common.sh", "check-issue-citation-convention.sh" }) do
    if fs.exists("scripts/" .. f) then proc.run{ argv = { "cp", "scripts/" .. f, WC .. "/scripts/" } } end
end
-- ORDER 1570-mxcg: the status-loss guard is Lua; the lane runs it from scripts/lua/.
if fs.exists("scripts/lua/check-fragment-status-loss.lua") then
    proc.run{ argv = { "cp", "scripts/lua/check-fragment-status-loss.lua", WC .. "/scripts/lua/" } }
end
proc.run{ argv = { "find", WC .. "/scripts", "-name", "*.sh", "-exec", "chmod", "+x", "{}", "+" } }
fs.write(relL .. "/wc/plan/index.yaml", "packets: []\n")
fs.write(relL .. "/wc/crates/tillandsias-plan/src/main.rs", "fn main() {}\n")
fs.write(relL .. "/wc/Cargo.lock", "# lock\n")
local LBIN = WC .. "/target/release/tillandsias-plan"
local function write_stub(vsh) -- what `validator-surface-hash` does (nil: no arm)
    fs.write(relL .. "/wc/target/release/tillandsias-plan", '#!/usr/bin/env bash\ncase "${1:-}" in\n'
        .. "    capabilities) echo compact; exit 0 ;;\n    check) exit 0 ;;\n    validate-yaml) exit 0 ;;\n"
        .. "    yaml-type) echo '!!map'; exit 0 ;;\n"
        .. (vsh and ("    validator-surface-hash) " .. vsh .. " ;;\n") or "") .. "esac\nexit 0\n")
    chmodx(LBIN)
end
write_stub(nil)
LG({ "add", "-A" }); LG({ "commit", "-q", "-m", "base" })
proc.run{ argv = { "git", "push", "-q", "-u", "origin", "linux-next" }, cwd = WC }

local function lane_push()
    local head = text.trim(LG({ "rev-parse", "HEAD" }).stdout or "")
    local up = text.trim(LG({ "rev-parse", "origin/linux-next" }).stdout or "")
    local r = proc.run{ argv = { "env", "-u", "TILLANDSIAS_PLAN_BIN", "-u", "CARGO_TARGET_DIR",
            "bash", "scripts/hooks/pre-push-local-gate.sh", "origin", LW .. "/bare.git" },
        cwd = WC, stdin = "refs/heads/linux-next " .. head .. " refs/heads/linux-next " .. up .. "\n",
        timeout_ms = 300000 }
    return (r.stdout or "") .. (r.stderr or ""), r.code
end

fs.write(relL .. "/wc/plan/index.d/20260912t000000z-stale-arm.yaml", "packets: []\n")
LG({ "add", "-A" }); LG({ "commit", "-q", "-m", "a fragment push" })

-- CASE: sources NEWER than the binary -> the validator is stale -> REFUSE.
touch_t("202609041215", LBIN)
touch_t("202609111933", WC .. "/crates/tillandsias-plan/src/main.rs")
local o, rc = lane_push()
ck("lane REFUSES a fragment push validated by a stale binary", "1", tostring(rc))
ck("the refusal names STALENESS as the cause", "yes", has(o, "is STALE") and "yes" or "no")
ck("the refusal carries a remedy the operator can type", "yes",
    has(o, "cargo build --release -p tillandsias-plan") and "yes" or "no")
-- `*"newer:"*Cargo.lock*|*"newer:"*main.rs*`: a newer: line naming a real source.
local nw = o:find("newer:", 1, true)
local names_newer = nw and (o:find("Cargo.lock", nw, true) or o:find("main.rs", nw, true))
ck("the refusal names the newer file that makes it stale", "yes", names_newer and "yes" or "no")
ck("the lane did NOT rebuild inside the hook", "yes", (has(o, "Compiling") or has(o, "Finished")) and "no" or "yes")

-- esme's configuration: the wsl2 redirect DERIVATION, unit-checked here.
local decl = ""
for _, l in ipairs(text.lines(fs.read("scripts/with-wsl2-builder.sh") or "")) do
    local m = l:match('export CARGO_TARGET_DIR=\\"([^"]*)\\"')
    if m and decl == "" then decl = m end
end
local tailv = "/$REPO_BASENAME"
ck("the wsl2 redirect declaration is still readable and still ends in $REPO_BASENAME", "yes",
    (decl ~= "" and decl:sub(-#tailv) == tailv) and "yes" or "no")

-- NEGATIVE CONTROL: a CURRENT binary (plain touch: now) is not refused as stale.
proc.run{ argv = { "touch", LBIN } }
o = lane_push()
ck("CONTROL: a CURRENT binary is not refused as stale", "yes", has(o, "is STALE") and "no" or "yes")

-- ── ORDER 1287-h6qn: THE CONTENT CONTRACT ──────────────────────────────────
local function plant_mtime_stale()
    touch_t("202609041215", LBIN)
    touch_t("202609111933", WC .. "/crates/tillandsias-plan/src/main.rs")
end
-- ARM 1 — an mtime-stale binary that vouches for its content is ACCEPTED.
write_stub("echo 'ok:validator-surface:deadbeefdeadbeef'; exit 0"); plant_mtime_stale()
o, rc = lane_push()
ck("CONTENT: an mtime-stale binary that vouches for its content is ACCEPTED", "yes", has(o, "is STALE") and "no" or "yes")
-- ARM 2 — a real difference is refused, naming BOTH hashes.
write_stub("echo 'stale:validator-surface built-from=1111111111111111 checkout=2222222222222222' >&2; exit 3"); plant_mtime_stale()
o, rc = lane_push()
ck("CONTENT: a binary whose surface really differs is REFUSED", "1", tostring(rc))
local bf = o:find("built-from=1111111111111111", 1, true)
ck("CONTENT: the refusal names BOTH hashes", "yes",
    (bf and o:find("checkout=2222222222222222", bf, true)) and "yes" or "no")
-- ARM 3 — NEGATIVE CONTROL: a binary that cannot ANSWER falls to the ladder.
write_stub("exit 0"); plant_mtime_stale()
o, rc = lane_push()
ck("CONTENT: a binary that cannot ANSWER falls back to the ladder and is refused", "1", tostring(rc))
ck("CONTENT: the fallback refusal still names staleness", "yes", has(o, "is STALE") and "yes" or "no")

proc.run{ argv = { "find", root .. "/target/plan-scratch", "-maxdepth", "1", "-name", "freshness-*-" .. stamp .. ".sh", "-delete" } }
cleanup()
out.line("plan-binary-freshness: " .. pass .. " passed, " .. fail .. " failed")
if fail == 0 then verdict.ok("plan-binary-freshness:" .. pass) end
verdict.emit("violation:plan-binary-freshness:" .. fail, 1)

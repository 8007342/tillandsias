-- @trace order:1459-mqvd, order:2232-k8jc
-- @env CARGO_TARGET_DIR
--
-- test-litmus-self-match.lua — a litmus step must not pkill/pgrep -f a
-- hard-coded pattern that its own `bash -c` shell carries in argv.
-- Ported from test-litmus-self-match.sh (2232-k8jc).
--
-- The runner executes each step's `command:` under `bash -c "<command>"`, so
-- the pattern text of `pkill -f tillandsias` is part of that shell's command
-- line, and the pkill can match and kill the step executing it (1266-75tr).
-- The fix idiom is a one-character class, `pkill -f 'tillandsia[s]'`: the
-- regex matches the process, never its own literal spelling.
--
-- The decision is made by `tillandsias-litmus-rust litmus-self-match`, which
-- parses the YAML and the bash (tree-sitter), not by grep. This fixture only
-- resolves the binary, runs the arms, and applies DECLARED.
--
--   1 HAZARD     a scratch litmus with an unbracketed pkill -f is REFUSED
--   2 IDIOM      (negative control) the same step with a bracketed pattern passes
--   3 TREE       every openspec/litmus-tests/*.yaml passes, minus DECLARED
--
-- Verdict: ok:litmus-self-match:<n> arms | violation:litmus-self-match-fixture:<n> failed

local root = text.trim(proc.run{ argv = { "pwd", "-P" } }.stdout or "")
local failn, pass = 0, 0
local function ok(m) out.line("ok:   " .. m); pass = pass + 1 end
local function bad(m) out.line("FAIL: " .. m); failn = failn + 1 end

-- Known instances, each owned by a row, as "<file>:<note>" entries. Remove an
-- entry when its row lands. 1266-75tr landed in land86 (the second of the
-- pair), which removed its two entries here as agreed between its author and
-- 1459-mqvd's.
local DECLARED = {}

-- A blocking guard never skips for want of a binary: build it if absent.
local ctd = env.get("CARGO_TARGET_DIR") or ""
local target = (ctd ~= "" and ctd) or (root .. "/target")
local BIN = ""
for _, cand in ipairs({ root .. "/target/release/tillandsias-litmus-rust", target .. "/release/tillandsias-litmus-rust" }) do
    local u = proc.run{ argv = { cand }, timeout_ms = 30000 }
    if u.code and ((u.stdout or "") .. (u.stderr or "")):find("litmus-self-match", 1, true) then BIN = cand; break end
end
if BIN == "" then
    local b = proc.run{ argv = { "cargo", "build", "-q", "--release", "-p", "tillandsias-litmus-rust" },
        cwd = root, env = (ctd ~= "" and { CARGO_TARGET_DIR = ctd } or nil), timeout_ms = 1800000 }
    if b.code ~= 0 then
        log.raw(b.stderr or "")
        verdict.emit("blocked:litmus-self-match:build-failed", 2)
    end
    BIN = target .. "/release/tillandsias-litmus-rust"
end

local rel = "target/plan-scratch/litmus-self-match-" .. tostring(time.now_ms())
proc.run{ argv = { "mkdir", "-p", root .. "/" .. rel } }
local function cleanup() proc.run{ argv = { "find", root .. "/" .. rel, "-delete" }, timeout_ms = 60000 } end
local pat = "tillandsia" .. "s"
fs.write(rel .. "/hazard.yaml", "steps:\n  - name: stop\n    command: \"pkill -f " .. pat .. " 2>/dev/null; echo DONE\"\n")
fs.write(rel .. "/idiom.yaml", "steps:\n  - name: stop\n    command: \"pkill -f 'tillandsia[s]' 2>/dev/null; echo DONE\"\n")

local function selfmatch(files)
    local argv = { BIN, "litmus-self-match" }
    for _, f in ipairs(files) do argv[#argv + 1] = f end
    local r = proc.run{ argv = argv, cwd = root, timeout_ms = 300000 }
    return r.code, (r.stdout or "") .. (r.stderr or "")
end

local rc1, out1 = selfmatch({ root .. "/" .. rel .. "/hazard.yaml" })
if rc1 ~= 0 and out1:find("violation:litmus-self-match:1", 1, true) then
    ok("ARM1 an unbracketed pkill -f in a step command is refused")
else bad("ARM1 rc=" .. tostring(rc1) .. " out='" .. out1 .. "'") end

local rc2, out2 = selfmatch({ root .. "/" .. rel .. "/idiom.yaml" })
local first2 = false
for _, l in ipairs(text.lines(out2)) do
    if l:sub(1, #"ok:litmus-self-match:scanned=1:commands=1") == "ok:litmus-self-match:scanned=1:commands=1" then first2 = true end
end
if rc2 == 0 and first2 then
    ok("ARM2 the bracketed spelling passes: the idiom is the fix, not a finding")
else bad("ARM2 rc=" .. tostring(rc2) .. " out='" .. out2 .. "'") end

local declared_files = {}
for _, d in ipairs(DECLARED) do declared_files[d:match("^([^:]+):") or d] = true end
local files = {}
for _, f in ipairs(fs.list("openspec/litmus-tests")) do
    local p = "openspec/litmus-tests/" .. f
    if f:match("%.yaml$") and not declared_files[p] then files[#files + 1] = p end
end
table.sort(files)
local rc3, out3 = selfmatch(files)
if rc3 == 0 then
    ok("ARM3 the litmus tree is clean outside DECLARED: " .. (text.lines(out3)[1] or ""))
else
    log.raw(out3)
    bad("ARM3 a litmus step can kill its own shell; bracket one character of the pattern, e.g. 'name[s]'")
end
-- A DECLARED entry that no longer fires is stale: say so, so it gets removed.
for _, d in ipairs(DECLARED) do
    local f = d:match("^([^:]+):") or d
    if not fs.exists(f) then bad("DECLARED names a missing file: " .. f)
    elseif selfmatch({ f }) == 0 then bad("DECLARED entry " .. d .. " no longer fires: remove it") end
end

cleanup()
if failn == 0 then verdict.ok("litmus-self-match:" .. pass .. " arms") end
verdict.emit("violation:litmus-self-match-fixture:" .. failn .. " failed", 1)

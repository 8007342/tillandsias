-- @trace spec:approval-record, order:1879-5jkt
-- @env TILLANDSIAS_HEADLESS_BIN
--
-- test-approval-broker.lua: `tillandsias approval request` turns a request for
-- a costly action into a signed, action-bound approval record, and
-- `tillandsias approval verify` admits it once (1879-5jkt, design D1-D4 of
-- openspec/changes/os-verified-approval-gates).
--
-- A test ed25519 key stands in for the hardware key. polkit's pkcheck is a
-- stub on PATH that allows (the software path's user check); one arm stubs it
-- to deny. Everything lives in a scratch dir: its own state dir
-- (TILLANDSIAS_APPROVAL_STATE_DIR), allowed_signers
-- (TILLANDSIAS_APPROVAL_ALLOWED_SIGNERS) and a scratch git repo for the note.
--
-- Arms:
--   1 REQUEST   request exits 0 and names a record file.
--   2 VERIFY    stock `ssh-keygen -Y verify -n tillandsias-approval@v1`
--               accepts the statement against the allowed signers.
--   3 BINDING   changing any one field (target, to, expires, nonce) makes
--               ssh-keygen refuse it. Each mutation is asserted to have
--               changed the statement before its verdict is read.
--   4 ONCE      a verify for a different `to` is refused without spending
--               the nonce; `approval verify` then admits the record, and refuses the same
--               nonce a second time.
--   5 NOTE      the note on the `to` commit under refs/notes/tillandsias/
--               approvals carries the statement, and its first line has no
--               run of 7+ hex characters.
--   6 PII       the statement's host field is not this host's name, and a
--               request whose detail carries a home path or an email is
--               refused before anything is signed.
--   7 DENIED    with pkcheck denying, no signature and no record are made.
--   8 UNENROLLED with no allowed_signers, request refuses before asking or
--               signing, and verify refuses.
--
-- PRE-FIX: the headless binary has no `approval` subcommand.
-- The binary is TILLANDSIAS_HEADLESS_BIN, else target/debug/tillandsias.
-- Verdict: ok:approval-broker:<arms>; refused:approval-broker:<failed>;
-- skip:approval-broker:no-headless-binary; could-not-run:approval-broker:...
-- Usage: tillandsias-plan script run scripts/lua/test-approval-broker.lua

local NAME = "approval-broker"
local NS = "tillandsias-approval@v1"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
local BIN = env.get("TILLANDSIAS_HEADLESS_BIN")
if not BIN or BIN == "" then BIN = ROOT .. "/target/debug/tillandsias" end
if proc.run({ argv = { "test", "-x", BIN }, timeout_ms = 10000 }).code ~= 0 then
    verdict.skip(NAME, "no-headless-binary", "no headless binary at " .. BIN .. " (cargo build -p tillandsias-headless, or set TILLANDSIAS_HEADLESS_BIN)")
end
if proc.run({ argv = { "ssh-keygen", "-Y", "check-novalidate", "-h" }, timeout_ms = 10000 }).status ~= "exited" then
    verdict.could_not_run(NAME, "ssh-keygen is not on PATH")
end

local REL = "target/plan-scratch/approval-broker-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
fs.mkdir(REL .. "/state")
fs.mkdir(REL .. "/repo")
fs.mkdir(REL .. "/allow")
fs.mkdir(REL .. "/deny")
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return (s or ""):find(sub, 1, true) ~= nil end
local function finish()
    proc.run({ argv = { "rm", "-rf", S } })
    if failed == 0 then verdict.emit("ok:" .. NAME .. ":" .. passed, 0) end
    verdict.emit("refused:" .. NAME .. ":" .. failed, 1)
end

-- The stand-in key and the allowed signers.
local kg = proc.run({ argv = { "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", S .. "/key" }, timeout_ms = 30000 })
if kg.code ~= 0 then verdict.could_not_run(NAME, "ssh-keygen could not make a test key: " .. (kg.stderr or "")) end
local pub = text.trim(fs.read(REL .. "/key.pub") or "")
fs.write(REL .. "/allowed_signers", "operator namespaces=\"" .. NS .. "\" " .. pub .. "\n")

-- pkcheck stubs: one allows, one denies.
fs.write(REL .. "/allow/pkcheck", "#!/bin/sh\nexit 0\n")
fs.write(REL .. "/deny/pkcheck", "#!/bin/sh\necho 'Not authorized.' >&2\nexit 1\n")
proc.run({ argv = { "chmod", "+x", S .. "/allow/pkcheck", S .. "/deny/pkcheck" } })

-- A scratch repo with the from and to commits.
local REPO = S .. "/repo"
local function git(args)
    local argv = { "git", "-C", REPO, "-c", "user.name=fixture", "-c", "user.email=fixture@local", "-c", "commit.gpgsign=false" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 30000 })
    return r.code == 0, text.trim(r.stdout or ""), r
end
git({ "init", "-q", "-b", "linux-next" })
fs.write(REL .. "/repo/a.txt", "a\n")
git({ "add", "-A" }); git({ "commit", "-qm", "A" })
local _, FROM = git({ "rev-parse", "HEAD" })
fs.write(REL .. "/repo/b.txt", "b\n")
git({ "add", "-A" }); git({ "commit", "-qm", "B" })
local _, TO = git({ "rev-parse", "HEAD" })

local SYS_PATH = "/usr/local/bin:/usr/bin:/bin"
local function broker(args, stub)
    local argv = { BIN, "approval" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000, env = {
        PATH = S .. "/" .. (stub or "allow") .. ":" .. SYS_PATH,
        TILLANDSIAS_APPROVAL_STATE_DIR = S .. "/state",
        TILLANDSIAS_APPROVAL_ALLOWED_SIGNERS = S .. "/allowed_signers",
    } })
    return (r.status == "exited" and r.code or -1), (r.stdout or ""), (r.stderr or "")
end
local function request(detail, stub)
    return broker({ "request", "--action", "merge-into-integration", "--project", "8007342/tillandsias",
        "--target", "refs/heads/linux-next", "--from", FROM, "--to", TO,
        "--detail", detail, "--key", S .. "/key", "--repo", REPO }, stub)
end

-- 1 REQUEST
local rc, o, e = request("Merge work/1879-5jkt into linux-next")
local record = o:match("ok:approval%-request:(%S+)")
if rc == 0 and record and fs.exists(record:sub(#ROOT + 2)) then
    ok("request exits 0 and names its record (" .. record:match("[^/]+$") .. ")")
else
    bad("request (rc=" .. rc .. "): " .. (o .. e):sub(1, 300))
    finish()
end
local body = fs.read(record:sub(#ROOT + 2))
local statement = body:match("(tillandsias%-approval v1\n.-\n)%-%-%-%-%-BEGIN SSH SIGNATURE")
local sig = body:match("(%-%-%-%-%-BEGIN SSH SIGNATURE%-%-%-%-%-\n.-%-%-%-%-%-END SSH SIGNATURE%-%-%-%-%-\n)")
if not statement or not sig then
    bad("the record holds no statement and signature block: " .. body:sub(1, 300))
    finish()
end
fs.write(REL .. "/statement.sig", sig)

local function sshverify(text_)
    local r = proc.run({ argv = { "ssh-keygen", "-Y", "verify", "-n", NS, "-I", "operator",
        "-f", S .. "/allowed_signers", "-s", S .. "/statement.sig" }, stdin = text_, timeout_ms = 30000 })
    return r.code, text.trim((r.stdout or "") .. (r.stderr or ""))
end

-- 2 VERIFY
local vrc, vo = sshverify(statement)
if vrc == 0 then ok("ssh-keygen -Y verify -n " .. NS .. " accepts the statement (" .. vo .. ")")
else bad("ssh-keygen refused the broker's own statement (rc=" .. vrc .. "): " .. vo) end

-- 3 BINDING: one field at a time.
local function mutate(field)
    local line = statement:match("\n(" .. field .. ": [^\n]*)\n")
    if not line then return nil end
    local val = line:sub(#field + 3)
    local alt = val:sub(1, -2) .. (val:sub(-1) == "0" and "1" or "0")
    if field == "target" then alt = "refs/heads/main" end
    local m = statement:gsub("\n" .. field .. ": [^\n]*\n", "\n" .. field .. ": " .. alt .. "\n", 1)
    return m
end
for _, f in ipairs({ "target", "to", "expires", "nonce" }) do
    local m = mutate(f)
    if not m or m == statement then
        bad("binding premise: no '" .. f .. ":' line to change in the statement")
    else
        local mrc = sshverify(m)
        if mrc ~= 0 then ok("changing " .. f .. " makes ssh-keygen refuse it (rc=" .. mrc .. ")")
        else bad("ssh-keygen accepted the statement with " .. f .. " changed") end
    end
end

-- 4 ONCE. First a verify naming a different `to` is refused, and that refusal
-- must not spend the nonce: the real verify after it still admits.
local rm_, om, em = broker({ "verify", record, "--target", "refs/heads/linux-next", "--to", FROM })
if rm_ ~= 0 and has(om, "refused:approval-verify:mismatch:to") then ok("a verify for a different commit is refused (mismatch:to)")
else bad("mismatched verify (rc=" .. rm_ .. "): " .. (om .. em):sub(1, 300)) end
local r1, o1, e1 = broker({ "verify", record, "--target", "refs/heads/linux-next", "--to", TO })
local r2, o2, e2 = broker({ "verify", record, "--target", "refs/heads/linux-next", "--to", TO })
if r1 == 0 and has(o1, "ok:approval-verify:") then ok("approval verify admits the record once")
else bad("first verify (rc=" .. r1 .. "): " .. (o1 .. e1):sub(1, 300)) end
if r2 ~= 0 and has(o2 .. e2, "refused:approval-verify:nonce-used") then ok("a second use of the same nonce is refused")
else bad("second verify (rc=" .. r2 .. "): " .. (o2 .. e2):sub(1, 300)) end

-- 5 NOTE
local nok, note = git({ "notes", "--ref=tillandsias/approvals", "show", TO })
local first = (note or ""):match("^[^\n]*") or ""
if nok and has(note, statement) and first ~= "" and not first:find("%x%x%x%x%x%x%x") then
    ok("the note on the to commit carries the statement; its first line has no hex run: " .. first)
else
    bad("note on " .. TO:sub(1, 9) .. " (ok=" .. tostring(nok) .. "): first line '" .. first .. "'")
end

-- 6 PII
local hn = text.trim(proc.run({ argv = { "uname", "-n" } }).stdout or "")
local host = statement:match("\nhost: ([^\n]*)\n") or ""
if host ~= "" and hn ~= "" and not has(host, hn) then ok("the host field is an opaque enrolment id, not the host name (" .. host .. ")")
else bad("host field '" .. host .. "' (uname -n '" .. hn .. "')") end
for _, d in ipairs({ "Merge /home/someone/project into linux-next", "Merge for someone@example.org" }) do
    local before = #fs.walk(REL .. "/state")
    local prc, po, pe = request(d)
    local after = #fs.walk(REL .. "/state")
    if prc ~= 0 and has(po .. pe, "refused:approval-request:personal-data") and after == before then
        ok("a detail carrying personal data is refused before signing: " .. d)
    else
        bad("detail '" .. d .. "' (rc=" .. prc .. ", state files " .. before .. "->" .. after .. "): " .. (po .. pe):sub(1, 200))
    end
end

-- 7 DENIED
local before = #fs.walk(REL .. "/state")
local drc, dout, derr = request("Merge work/1879-5jkt into linux-next", "deny")
local after = #fs.walk(REL .. "/state")
if drc ~= 0 and has(dout .. derr, "refused:approval-request:user-check-denied") and after == before
    and not has(dout, "BEGIN SSH SIGNATURE") then
    ok("with pkcheck denying, nothing is signed and no record is written")
else
    bad("pkcheck deny (rc=" .. drc .. ", state files " .. before .. "->" .. after .. "): " .. (dout .. derr):sub(1, 200))
end

-- 8 NOT ENROLLED: with no allowed_signers, request asks nothing and signs
-- nothing, and verify admits nothing.
local function unenrolled(args)
    local argv = { BIN, "approval" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local r = proc.run({ argv = argv, timeout_ms = 60000, env = {
        PATH = S .. "/allow:" .. SYS_PATH,
        TILLANDSIAS_APPROVAL_STATE_DIR = S .. "/state",
        TILLANDSIAS_APPROVAL_ALLOWED_SIGNERS = S .. "/no-such-allowed-signers",
    } })
    return (r.status == "exited" and r.code or -1), (r.stdout or "") .. (r.stderr or "")
end
before = #fs.walk(REL .. "/state")
local nrc, no = unenrolled({ "request", "--action", "merge-into-integration", "--project", "8007342/tillandsias",
    "--target", "refs/heads/linux-next", "--from", FROM, "--to", TO,
    "--detail", "Merge work/1879-5jkt into linux-next", "--key", S .. "/key" })
after = #fs.walk(REL .. "/state")
if nrc ~= 0 and has(no, "refused:approval-request:not-enrolled") and after == before then
    ok("with no allowed_signers, request refuses (not-enrolled) and writes nothing")
else bad("unenrolled request (rc=" .. nrc .. ", state files " .. before .. "->" .. after .. "): " .. no:sub(1, 200)) end
local vrc2, vo2 = unenrolled({ "verify", record })
if vrc2 ~= 0 and has(vo2, "refused:approval-verify:not-enrolled") then
    ok("with no allowed_signers, verify refuses (not-enrolled)")
else bad("unenrolled verify (rc=" .. vrc2 .. "): " .. vo2:sub(1, 200)) end

finish()

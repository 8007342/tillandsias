-- @trace spec:approval-record, spec:approval-attestation, order:1879-5jkt, order:1880-9wpd
-- @env TILLANDSIAS_HEADLESS_BIN TILLANDSIAS_SK_STUB
--
-- test-approval-broker.lua: a Linux host enrols a FIDO2 security key as its
-- approval key (1880-9wpd), and `tillandsias approval request` turns a request
-- for a costly action into a signed, action-bound approval record that
-- `tillandsias approval verify` admits once (1879-5jkt). Design D1-D4 of
-- openspec/changes/os-verified-approval-gates.
--
-- OPERATOR RULING 2026-11-11: Linux approval keys are FIDO2 only, with no
-- software fallback. Until the operator has a key, Linux approvals are signed
-- on the Mac with Touch ID. So a plain key is refused, and a host with no
-- authenticator is told to sign on the Mac.
--
-- The authenticator is a stand-in: examples/sk_stub.rs, an OpenSSH sk-api
-- provider loaded by ssh-keygen through TILLANDSIAS_APPROVAL_SK_PROVIDER.
-- TILLANDSIAS_SK_STUB_MODE=absent makes it a host with no key plugged in;
-- =decline makes it refuse to sign (PIN or touch refused).
--
-- Arms:
--   E1 NO KEY      with no authenticator, enrol refuses (no-security-key),
--                  names Mac signing, and writes no key and no signer line.
--   E2 ENROL       enrol writes one allowed_signers line: principal operator,
--                  the approval namespace, an sk-ssh-ed25519 key, the
--                  comment tillandsias-approval/<slug>, no host name.
--   E3 AGAIN       enrolling again keeps the key and the single line.
--   1 REQUEST      request (no --key: the project's enrolled key) names a
--                  record, and the statement says hardware-pin.
--   2 VERIFY       stock `ssh-keygen -Y verify` accepts the statement.
--   3 BINDING      changing target, to, expires or nonce breaks it.
--   4 ONCE         a verify for a different `to` is refused without spending
--                  the nonce; verify admits once and refuses the nonce again.
--   5 NOTE         the note on the `to` commit carries the statement; its
--                  first line has no run of 7+ hex characters.
--   6 PII          host is an opaque id, not this host's name; a detail with
--                  a home path or an email is refused before signing.
--   7 DECLINED     an authenticator that refuses to sign leaves no record.
--   8 PLAIN KEY    a plain ed25519 key is refused (not-a-security-key), even
--                  when its line is in allowed_signers, and names Mac signing.
--   9 UNENROLLED   a project with no enrolled key is refused (no-security-key).
--  10 NOT VERIFIED a signature by an sk key enrolled WITHOUT verify-required
--                  passes stock ssh-keygen but verify refuses it
--                  (not-user-verified): allowed_signers cannot require it.
--  11 NO SIGNERS   with no allowed_signers, request and verify refuse.
--
-- PRE-FIX (1880-9wpd): there is no `approval enrol`, and request takes a
-- plain key through polkit.
-- The binary is TILLANDSIAS_HEADLESS_BIN, else target/debug/tillandsias; the
-- stand-in is TILLANDSIAS_SK_STUB, else target/debug/examples/libsk_stub.so.
-- Verdict: ok:approval-broker:<arms>; refused:approval-broker:<failed>;
-- skip:approval-broker:no-headless-binary|no-sk-stub; could-not-run:...
-- Usage: tillandsias-plan script run scripts/lua/test-approval-broker.lua

local NAME = "approval-broker"
local NS = "tillandsias-approval@v1"
local SLUG = "8007342/tillandsias"
local top = proc.run({ argv = { "git", "rev-parse", "--show-toplevel" }, timeout_ms = 30000 })
local ROOT = text.trim(top.stdout or "")
if top.code ~= 0 or ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end
local BIN = env.get("TILLANDSIAS_HEADLESS_BIN")
if not BIN or BIN == "" then BIN = ROOT .. "/target/debug/tillandsias" end
if proc.run({ argv = { "test", "-x", BIN }, timeout_ms = 10000 }).code ~= 0 then
    verdict.skip(NAME, "no-headless-binary", "no headless binary at " .. BIN .. " (cargo build -p tillandsias-headless --features tray, or set TILLANDSIAS_HEADLESS_BIN)")
end
local SO = env.get("TILLANDSIAS_SK_STUB")
if not SO or SO == "" then SO = ROOT .. "/target/debug/examples/libsk_stub.so" end
if proc.run({ argv = { "test", "-f", SO }, timeout_ms = 10000 }).code ~= 0 then
    verdict.skip(NAME, "no-sk-stub", "no stand-in authenticator at " .. SO .. " (cargo build -p tillandsias-headless --example sk_stub, or set TILLANDSIAS_SK_STUB)")
end
if proc.run({ argv = { "ssh-keygen", "-Y", "check-novalidate", "-h" }, timeout_ms = 10000 }).status ~= "exited" then
    verdict.could_not_run(NAME, "ssh-keygen is not on PATH")
end

local REL = "target/plan-scratch/approval-broker-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local S = ROOT .. "/" .. REL
fs.mkdir(REL .. "/state")
fs.mkdir(REL .. "/repo")
local SIGNERS = S .. "/state/allowed_signers"
local passed, failed = 0, 0
local function ok(m) out.line("ok: " .. m); passed = passed + 1 end
local function bad(m) out.line("FAIL: " .. m); failed = failed + 1 end
local function has(s, sub) return (s or ""):find(sub, 1, true) ~= nil end
local function finish()
    proc.run({ argv = { "rm", "-rf", S } })
    if failed == 0 then verdict.emit("ok:" .. NAME .. ":" .. passed, 0) end
    verdict.emit("refused:" .. NAME .. ":" .. failed, 1)
end
local function nfiles() return #fs.walk(REL .. "/state") end
local function signer_lines()
    if not fs.exists(REL .. "/state/allowed_signers") then return {} end
    local t = {}
    for _, l in ipairs(text.lines(fs.read(REL .. "/state/allowed_signers") or "")) do
        if l ~= "" then t[#t + 1] = l end
    end
    return t
end

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

local function broker(args, opts)
    opts = opts or {}
    local argv = { BIN, "approval" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local e = {
        TILLANDSIAS_APPROVAL_STATE_DIR = S .. "/state",
        TILLANDSIAS_APPROVAL_ALLOWED_SIGNERS = opts.signers or SIGNERS,
        TILLANDSIAS_APPROVAL_SK_PROVIDER = SO,
    }
    if opts.mode then e.TILLANDSIAS_SK_STUB_MODE = opts.mode end
    local r = proc.run({ argv = argv, timeout_ms = 60000, env = e })
    return (r.status == "exited" and r.code or -1), (r.stdout or ""), (r.stderr or "")
end
local function request(detail, opts)
    opts = opts or {}
    local a = { "request", "--action", "merge-into-integration", "--project", opts.project or SLUG,
        "--target", "refs/heads/linux-next", "--from", FROM, "--to", TO, "--detail", detail, "--repo", REPO }
    if opts.key then a[#a + 1] = "--key"; a[#a + 1] = opts.key end
    return broker(a, opts)
end
local MAC = "--approval-sign"

-- E1 NO KEY
local erc, eo, ee = broker({ "enrol", "--project", SLUG }, { mode = "absent" })
if erc ~= 0 and has(eo, "refused:approval-enrol:no-security-key") and has(ee, MAC) and #signer_lines() == 0 and nfiles() == 0 then
    ok("with no authenticator, enrol refuses (no-security-key), points at Mac signing, writes nothing")
else
    bad("enrol with no authenticator (rc=" .. erc .. ", signer lines " .. #signer_lines() .. ", state files " .. nfiles() .. "): " .. (eo .. ee):sub(1, 300))
end

-- E2 ENROL
local hn = text.trim(proc.run({ argv = { "uname", "-n" } }).stdout or "")
erc, eo, ee = broker({ "enrol", "--project", SLUG })
local lines = signer_lines()
local line = lines[1] or ""
local prefix = "operator namespaces=\"" .. NS .. "\" sk-ssh-ed25519@openssh.com "
if erc == 0 and has(eo, "ok:approval-enrol:") and #lines == 1 and line:sub(1, #prefix) == prefix
    and line:sub(-#("tillandsias-approval/" .. SLUG)) == "tillandsias-approval/" .. SLUG
    and (hn == "" or not has(line, hn)) then
    ok("enrol writes one sk-ssh-ed25519 signer line for operator, named by the slug only")
else
    bad("enrol (rc=" .. erc .. ", " .. #lines .. " line(s)): '" .. line .. "' " .. (eo .. ee):sub(1, 300))
end

-- E3 AGAIN
local before_line = line
erc, eo, ee = broker({ "enrol", "--project", SLUG })
lines = signer_lines()
if erc == 0 and #lines == 1 and lines[1] == before_line then ok("enrolling again keeps the key and the single signer line")
else bad("second enrol (rc=" .. erc .. ", " .. #lines .. " line(s)): " .. (eo .. ee):sub(1, 300)) end

-- 1 REQUEST
local rc, o, e = request("Merge work/1880-9wpd into linux-next")
local record = o:match("ok:approval%-request:(%S+)")
if not (rc == 0 and record and fs.exists(record:sub(#ROOT + 2))) then
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
if has(statement, "\nstrength: hardware-pin\n") then ok("request signs with the enrolled security key; the statement says hardware-pin")
else bad("statement strength: " .. (statement:match("\nstrength: [^\n]*") or "none")) end
fs.write(REL .. "/statement.sig", sig)

local function sshverify(text_, sigfile, signers)
    local r = proc.run({ argv = { "ssh-keygen", "-Y", "verify", "-n", NS, "-I", "operator",
        "-f", signers or SIGNERS, "-s", sigfile or (S .. "/statement.sig") }, stdin = text_, timeout_ms = 30000 })
    return r.code, text.trim((r.stdout or "") .. (r.stderr or ""))
end

-- 2 VERIFY
local vrc, vo = sshverify(statement)
if vrc == 0 then ok("ssh-keygen -Y verify -n " .. NS .. " accepts the statement (" .. vo .. ")")
else bad("ssh-keygen refused the broker's own statement (rc=" .. vrc .. "): " .. vo) end

-- 3 BINDING
local function mutate(field)
    local l = statement:match("\n(" .. field .. ": [^\n]*)\n")
    if not l then return nil end
    local val = l:sub(#field + 3)
    local alt = val:sub(1, -2) .. (val:sub(-1) == "0" and "1" or "0")
    if field == "target" then alt = "refs/heads/main" end
    return (statement:gsub("\n" .. field .. ": [^\n]*\n", "\n" .. field .. ": " .. alt .. "\n", 1))
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

-- 4 ONCE
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
local host = statement:match("\nhost: ([^\n]*)\n") or ""
if host ~= "" and hn ~= "" and not has(host, hn) then ok("the host field is an opaque enrolment id, not the host name (" .. host .. ")")
else bad("host field '" .. host .. "' (uname -n '" .. hn .. "')") end
for _, d in ipairs({ "Merge /home/someone/project into linux-next", "Merge for someone@example.org" }) do
    local before = nfiles()
    local prc, po, pe = request(d)
    if prc ~= 0 and has(po .. pe, "refused:approval-request:personal-data") and nfiles() == before then
        ok("a detail carrying personal data is refused before signing: " .. d)
    else
        bad("detail '" .. d .. "' (rc=" .. prc .. ", state files " .. before .. "->" .. nfiles() .. "): " .. (po .. pe):sub(1, 200))
    end
end

-- 7 DECLINED
local before = nfiles()
local drc, dout, derr = request("Merge work/1880-9wpd into linux-next", { mode = "decline" })
if drc ~= 0 and has(dout, "refused:approval-request:sign-failed") and nfiles() == before and not has(dout, "BEGIN SSH SIGNATURE") then
    ok("an authenticator that refuses to sign leaves no signature and no record")
else
    bad("declined signing (rc=" .. drc .. ", state files " .. before .. "->" .. nfiles() .. "): " .. (dout .. derr):sub(1, 200))
end

-- 8 PLAIN KEY: refused even when its line is enrolled.
proc.run({ argv = { "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "", "-f", S .. "/plain" }, timeout_ms = 30000 })
local plainpub = text.trim(fs.read(REL .. "/plain.pub") or "")
fs.write(REL .. "/signers-with-plain", (fs.read(REL .. "/state/allowed_signers") or "") .. "operator namespaces=\"" .. NS .. "\" " .. plainpub .. "\n")
before = nfiles()
local prc, po, pe = request("Merge work/1880-9wpd into linux-next", { key = S .. "/plain", signers = S .. "/signers-with-plain" })
if prc ~= 0 and has(po, "refused:approval-request:not-a-security-key") and has(pe, MAC) and nfiles() == before then
    ok("a plain ed25519 key is refused (not-a-security-key) and points at Mac signing")
else
    bad("plain key (rc=" .. prc .. ", state files " .. before .. "->" .. nfiles() .. "): " .. (po .. pe):sub(1, 300))
end

-- 9 UNENROLLED PROJECT
before = nfiles()
local urc, uo, ue = request("Merge work/1880-9wpd into linux-next", { project = "8007342/other" })
if urc ~= 0 and has(uo, "refused:approval-request:no-security-key") and has(ue, MAC) and nfiles() == before then
    ok("a project with no enrolled key is refused (no-security-key) and points at Mac signing")
else
    bad("unenrolled project (rc=" .. urc .. "): " .. (uo .. ue):sub(1, 300))
end

-- 10 NOT USER-VERIFIED: an sk key enrolled without verify-required signs
-- with user presence only. Stock ssh-keygen accepts it (allowed_signers has
-- no option to require verification); the broker must refuse it.
proc.run({ argv = { "ssh-keygen", "-q", "-t", "ed25519-sk", "-O", "application=ssh:tillandsias-approval", "-N", "", "-C", "",
    "-w", SO, "-f", S .. "/nouv" }, timeout_ms = 30000 })
local nouvpub = text.trim(fs.read(REL .. "/nouv.pub") or "")
local nouv_signers = S .. "/signers-nouv"
fs.write(REL .. "/signers-nouv", "operator namespaces=\"" .. NS .. "\" " .. nouvpub .. "\n")
local fresh = statement:gsub("\nnonce: [^\n]*\n", "\nnonce: " .. string.rep("ab", 16) .. "\n", 1)
fs.write(REL .. "/nouv-statement", fresh)
proc.run({ argv = { "ssh-keygen", "-q", "-Y", "sign", "-n", NS, "-w", SO, "-f", S .. "/nouv", S .. "/nouv-statement" }, timeout_ms = 30000 })
local nsig = fs.read(REL .. "/nouv-statement.sig") or ""
local sk_ok = sshverify(fresh, S .. "/nouv-statement.sig", nouv_signers)
fs.write(REL .. "/nouv.approval", "The operator approved merging into linux-next.\n\n" .. fresh .. nsig)
local nrc, no_, ne = broker({ "verify", S .. "/nouv.approval" }, { signers = nouv_signers })
if nouvpub == "" or nsig == "" or sk_ok ~= 0 then
    bad("premise: the presence-only sk key did not sign a statement stock ssh-keygen accepts (pub=" .. #nouvpub .. ", sig=" .. #nsig .. ", verify rc=" .. sk_ok .. ")")
elseif nrc ~= 0 and has(no_, "refused:approval-verify:not-user-verified") then
    ok("stock ssh-keygen accepts a presence-only sk signature; approval verify refuses it (not-user-verified)")
else
    bad("presence-only signature (rc=" .. nrc .. "): " .. (no_ .. ne):sub(1, 300))
end

-- 11 NO SIGNERS
before = nfiles()
local frc, fo, fe = request("Merge work/1880-9wpd into linux-next", { signers = S .. "/no-such-allowed-signers" })
if frc ~= 0 and has(fo, "refused:approval-request:not-enrolled") and nfiles() == before then
    ok("with no allowed_signers, request refuses (not-enrolled) and writes nothing")
else bad("request with no signers (rc=" .. frc .. "): " .. (fo .. fe):sub(1, 200)) end
local vrc2, vo2, ve2 = broker({ "verify", record }, { signers = S .. "/no-such-allowed-signers" })
if vrc2 ~= 0 and has(vo2, "refused:approval-verify:not-enrolled") then ok("with no allowed_signers, verify refuses (not-enrolled)")
else bad("verify with no signers (rc=" .. vrc2 .. "): " .. (vo2 .. ve2):sub(1, 200)) end

finish()

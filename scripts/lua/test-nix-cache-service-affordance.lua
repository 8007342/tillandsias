-- @trace order:1247-nx5c, order:1247-amcu, order:801-kqme, spec:nix-cache-service
--
-- test-nix-cache-service-affordance.lua — every blocked:nix-cache:* verdict of
-- scripts/nix-cache-service.sh says WHY on stderr and what CLEARS it, beside
-- its unchanged stdout token (main.rs reads only the last stdout line), and
-- each arm then EXECUTES the remedy and requires the script to move past that
-- verdict (1247-amcu criterion 5).
--
--   tillandsias-plan script run scripts/lua/test-nix-cache-service-affordance.lua
--   ... -- --subject <path>   judge another copy (the pre-fix script, for the
--                             negative control)
--
-- HERMETIC, unlike scripts/test-nix-cache-service.sh (which needs real nix,
-- podman and a CA): the subject runs from a scratch copy under
-- target/plan-scratch whose scripts/nix-toolbox.sh is a stub answering the
-- toolbox rung, with stub podman, curl and sleep first on PATH. Every path the script
-- writes (state dir, chroot store, CA dir, HOME) is under the scratch dir, so
-- no real podman object, nix store, stack CA or ~/.local/share/tillandsias is
-- touched. The CA this mints is a throwaway made for the arm that needs one.
--
--   1 pubkey before keygen     -> remedy keygen, then pubkey answers
--   2 keygen fails on the rung -> why names nix-store and the rung, not the CA
--   3 state dir unwritable     -> remedy a writable TILLANDSIAS_NIX_CACHE_STATE
--   4 no enclave network       -> remedy: the network exists; moves past it
--   5 no stack CA              -> remedy: a CA in the CA dir; moves past no-ca
--   6 harmonia unresolved / not executable -> remedy: a built harmonia; prepare ok
--   7 podman run fails         -> why quotes podman's error; once it runs, the
--                                 verdict moves on to unhealthy, which says why
--
-- Terminal line: ok:nix-cache-affordance:<n> / refused:nix-cache-affordance:<failed>

local SUBJECT = "scripts/nix-cache-service.sh"
for i = 1, #arg do if arg[i] == "--subject" then SUBJECT = arg[i + 1] end end

local ROOT = text.trim(proc.run({ argv = { "git", "rev-parse", "--show-toplevel" } }).stdout or "")
if ROOT == "" then verdict.could_not_run("nix-cache-affordance", "not inside a git checkout") end
local REL = "target/plan-scratch/nix-cache-affordance-" .. tostring(math.random(100000, 999999)) .. tostring(math.random(100000, 999999))
local SB = ROOT .. "/" .. REL

for _, d in ipairs({ "", "/scripts", "/bin", "/fx", "/home", "/store/nix/store", "/ca", "/state" }) do fs.mkdir(REL .. d) end
fs.write(REL .. "/scripts/nix-cache-service.sh", fs.read(SUBJECT))
fs.write(REL .. "/scripts/lib-ca-path.sh", fs.read("scripts/lib-ca-path.sh"))

-- The toolbox rung, answered from flag files under fx/.
fs.write(REL .. "/scripts/nix-toolbox.sh", [[#!/usr/bin/env bash
case "$1" in
    capability) echo "ok:nix-capability:toolbox"; exit 0 ;;
    run)
        shift; [ "${1:-}" = "--" ] && shift
        case "$1" in
            nix-store)
                [ -e "$FX/keygen-fails" ] && { echo "error: stub nix-store refused" >&2; exit 1; }
                sk=""; pk=""; for a in "$@"; do sk="$pk"; pk="$a"; done
                printf 'stub-secret\n' > "$sk" && printf 'tillandsias-nix-cache-1:c3R1Yg==\n' > "$pk"
                exit $? ;;
            nix)
                [ -s "$FX/harmonia-path" ] && cat "$FX/harmonia-path"
                exit 0 ;;
        esac ;;
esac
exit 1
]])
fs.write(REL .. "/bin/podman", [[#!/usr/bin/env bash
case "$1" in
    network) [ "$2" = exists ] && [ -e "$FX/enclave" ]; exit $? ;;
    container) exit 1 ;;
    inspect) echo false; exit 0 ;;
    rm) exit 0 ;;
    run)
        [ -e "$FX/run-ok" ] && exit 0
        echo "Error: stub podman: fedora-minimal:44: image not known" >&2
        exit 125 ;;
esac
exit 1
]])
fs.write(REL .. "/bin/curl", "#!/usr/bin/env bash\nexit 7\n")
-- The unhealthy probe loop sleeps 40 x 0.25s between curls; a stub sleep keeps
-- the arm (and the instant litmus that runs it) to well under a second.
fs.write(REL .. "/bin/sleep", "#!/usr/bin/env bash\nexit 0\n")
proc.run({ argv = { "chmod", "+x", SB .. "/scripts/nix-toolbox.sh", SB .. "/bin/podman", SB .. "/bin/curl", SB .. "/bin/sleep" } })

local BASE_ENV = {
    PATH = SB .. "/bin:/usr/bin:/bin",
    HOME = SB .. "/home",
    FX = SB .. "/fx",
    TILLANDSIAS_CA_DIR = SB .. "/ca",
    TILLANDSIAS_NIX_CACHE_STATE = SB .. "/state",
    TILLANDSIAS_NIX_CHROOT_STORE = SB .. "/store",
    TILLANDSIAS_ENCLAVE_NET = "fx-enclave",
}
local function svc(sub, over)
    local e = {}
    for k, v in pairs(BASE_ENV) do e[k] = v end
    for k, v in pairs(over or {}) do e[k] = v end
    local r = proc.run({ argv = { "bash", SB .. "/scripts/nix-cache-service.sh", sub }, env = e, timeout_ms = 60000 })
    return text.trim(r.stdout or ""), r.stderr or "", (r.status == "exited") and r.code or -1
end
local function touch(name) fs.write(REL .. "/fx/" .. name, "1\n") end
local function unflag(name) proc.run({ argv = { "rm", "-f", SB .. "/fx/" .. name } }) end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then out.line("ok:   " .. name); passed = passed + 1
    else out.line("FAIL: " .. name .. " — " .. (detail or "")); failed = failed + 1 end
end
local function afford(err, why, remedy)
    return text.contains(err, "  why: ") and text.contains(err, "  remedy: ")
        and text.contains(err, why) and text.contains(err, remedy)
end
local function show(o, e) return "stdout=[" .. o .. "] stderr=[" .. e .. "]" end

-- 1. pubkey before keygen.
local o, e, rc = svc("pubkey")
check("1 pubkey before keygen says why and names keygen",
    o == "blocked:nix-cache:no-ca" and rc == 1 and afford(e, "no public key at", "remedy: scripts/nix-cache-service.sh keygen"), show(o, e))
o, e, rc = svc("keygen")
check("1 the remedy (keygen) mints the keypair", rc == 0 and o:sub(1, #"ok:nix-cache-key:generated:") == "ok:nix-cache-key:generated:", show(o, e))
o, e, rc = svc("pubkey")
check("1 pubkey then answers", rc == 0 and o == "tillandsias-nix-cache-1:c3R1Yg==", show(o, e))

-- 2. keygen failing on the rung: the why names nix-store and the rung, not the CA.
proc.run({ argv = { "rm", "-f", SB .. "/state/cache-priv.key", SB .. "/state/cache-pub.key" } })
touch("keygen-fails")
o, e, rc = svc("keygen")
check("2 a failed keygen names nix-store on the toolbox rung, not the CA",
    o == "blocked:nix-cache:no-ca" and rc == 1
    and afford(e, "--generate-binary-cache-key failed on the toolbox rung", "nix-toolbox.sh run -- nix-store --store " .. SB .. "/store --generate-binary-cache-key")
    and text.contains(e, "the stack CA is not the cause"), show(o, e))
unflag("keygen-fails")

-- 3. An unwritable state dir (a regular file in its place).
fs.write(REL .. "/not-a-dir", "x\n")
o, e, rc = svc("keygen", { TILLANDSIAS_NIX_CACHE_STATE = SB .. "/not-a-dir" })
check("3 an unwritable state dir is named as the cause",
    o == "blocked:nix-cache:no-ca" and rc == 1 and afford(e, SB .. "/not-a-dir is not a directory", "TILLANDSIAS_NIX_CACHE_STATE"), show(o, e))
o, e, rc = svc("keygen")
check("3 the remedy (a writable state dir) clears it", rc == 0 and text.contains(o, "ok:nix-cache-key:generated:"), show(o, e))

-- 4. No enclave network.
o, e, rc = svc("prepare")
check("4 no enclave says why and names the tray",
    o == "blocked:nix-cache:no-enclave" and rc == 1 and afford(e, "podman network fx-enclave does not exist", "launch the tray once"), show(o, e))
touch("enclave")
o, e, rc = svc("prepare")
check("4 with the network present, prepare moves past no-enclave", o ~= "blocked:nix-cache:no-enclave", show(o, e))

-- 5. No stack CA (the CA dir is empty): the why names the intermediate.
check("5 a missing stack CA is named as the cause of no-ca",
    o == "blocked:nix-cache:no-ca" and afford(e, "has no intermediate.crt and intermediate.key", "it mints the stack CA into " .. SB .. "/ca"), show(o, e))
local ca = proc.run({ argv = { "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
    "-keyout", SB .. "/ca/intermediate.key", "-out", SB .. "/ca/intermediate.crt", "-days", "2", "-subj", "/CN=fixture-ca" },
    env = { PATH = "/usr/bin:/bin" }, timeout_ms = 60000 })
if ca.status ~= "exited" or ca.code ~= 0 then
    proc.run({ argv = { "rm", "-rf", SB } })
    verdict.could_not_run("nix-cache-affordance", "openssl could not mint the fixture CA: " .. (ca.stderr or ""))
end
o, e, rc = svc("prepare")
check("5 with a CA, prepare moves past no-ca", o ~= "blocked:nix-cache:no-ca", show(o, e))

-- 6. harmonia unresolved, then resolved but not executable, then built.
check("6 an unresolved harmonia says why and names the build",
    o == "blocked:nix-cache:no-harmonia" and afford(e, "answered no store path on the toolbox rung", "nix --extra-experimental-features 'nix-command flakes' build --store " .. SB .. "/store --no-link --print-out-paths nixpkgs#harmonia"), show(o, e))
fs.write(REL .. "/fx/harmonia-path", "/nix/store/abc-harmonia-3.2.0\n")
o, e, rc = svc("prepare")
check("6 a non-executable harmonia says why",
    o == "blocked:nix-cache:no-harmonia" and afford(e, "/nix/store/abc-harmonia-3.2.0/bin/harmonia-cache is not executable", "rebuild it to see why"), show(o, e))
fs.mkdir(REL .. "/store/nix/store/abc-harmonia-3.2.0/bin")
fs.write(REL .. "/store/nix/store/abc-harmonia-3.2.0/bin/harmonia-cache", "#!/bin/sh\nexit 0\n")
proc.run({ argv = { "chmod", "+x", SB .. "/store/nix/store/abc-harmonia-3.2.0/bin/harmonia-cache" } })
o, e, rc = svc("prepare")
check("6 with harmonia built, prepare answers ok", rc == 0 and o == "ok:nix-cache-prepare:entrypoint=/nix/store/abc-harmonia-3.2.0/bin/harmonia-cache", show(o, e))

-- 7. podman run fails: the why quotes podman's own error.
o, e, rc = svc("ensure")
check("7 a failed podman run quotes podman's error",
    o == "blocked:nix-cache:start-failed" and rc == 1 and afford(e, "image not known", "podman pull registry.fedoraproject.org/fedora-minimal:44"), show(o, e))
touch("run-ok")
o, e, rc = svc("ensure")
check("7 once it runs, the verdict moves on to unhealthy, which says why",
    o == "blocked:nix-cache:unhealthy" and afford(e, "did not answer StoreDir", "podman logs tillandsias-nix-cache"), show(o, e))

proc.run({ argv = { "rm", "-rf", SB } })
if failed == 0 then verdict.emit("ok:nix-cache-affordance:" .. passed, 0) end
verdict.emit("refused:nix-cache-affordance:" .. failed, 1)

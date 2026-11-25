-- @trace order:2018-cabd, order:1998-mvrs, order:2319-fmgy
-- @env PATH HOME XDG_RUNTIME_DIR
--
-- test-git-image-ca-bind-styles.lua — the BUILT git image serves a readable
-- CA at /etc/tillandsias/ca.crt under every bind style the launcher uses:
--   1 FILE-V      -v <crt>:/etc/tillandsias/ca.crt:ro   (remote_projects.rs: repo list, clone)
--   2 FILE-MOUNT  --mount type=bind,...,target=/etc/tillandsias/ca.crt,readonly=true
--   3 DIR         --mount type=bind,...,target=/etc/tillandsias/ca-trust,readonly=true
--                 (the mirror and its sidecars, MIRROR_CA_TRUST_MOUNT)
-- Each arm must read back the exact bytes bound. The image is built from
-- images/git/Containerfile as shipped, in a real container, not by reading the
-- Containerfile.
--   4 SHAPE       with nothing bound, ca.crt already resolves to a regular file in
--                 the image, so a single-file bind needs nothing from the runtime
-- CONTROL: the same build with the 2018-cabd mount-point lines removed (the
-- 1998-mvrs (b) shape: ca.crt a symlink to a missing ca-trust/intermediate.crt)
-- must FAIL arm 4, and must FAIL the file arms unless the runtime itself put
-- the bind at the symlink's target. crun 1.31 creates that missing target, so
-- there the pre-fix image reads the CA too (measured on macuahuitl and lenovinha, 2026-11-24); older
-- runtimes do not, which is the regression the operator hit on macuahuitl
-- ("vault-cli: CA bundle not readable at /etc/tillandsias/ca.crt"). A read that
-- is neither a failure nor such a mount is a control that proves nothing.
--
-- Verdict is stdout only; podman build progress stays on stderr.
-- Usage: tillandsias-plan script run scripts/lua/test-git-image-ca-bind-styles.lua

local NAME = "git-image-ca-bind-styles"
local ENV = {
    PATH = env.get("PATH") or "/usr/bin:/bin",
    HOME = env.get("HOME") or "",
    XDG_RUNTIME_DIR = env.get("XDG_RUNTIME_DIR") or "",
}
local function run(argv, ms)
    return proc.run({ argv = argv, env = ENV, timeout_ms = ms or 120000 })
end

local w = run({ "podman", "--version" }, 30000)
if w.status == "policy_denied" then verdict.could_not_run(NAME, "the runtime refused to run podman") end
if w.status ~= "exited" or w.code ~= 0 then verdict.skip(NAME, "podman is not installed") end

local top = run({ "git", "rev-parse", "--show-toplevel" }, 30000)
local ROOT = text.trim(top.stdout or "")
if ROOT == "" then verdict.could_not_run(NAME, "git rev-parse --show-toplevel did not answer") end

local CF = "images/git/Containerfile"
local src = fs.read(CF) or ""
local FIX = "RUN mkdir -p /etc/tillandsias/ca-trust \\\n"
    .. "    && touch /etc/tillandsias/ca-trust/intermediate.crt \\\n"
    .. "    && chmod 644 /etc/tillandsias/ca-trust/intermediate.crt \\\n"
    .. "    && ln -sf ca-trust/intermediate.crt /etc/tillandsias/ca.crt\n"
local OLD = "RUN mkdir -p /etc/tillandsias \\\n    && ln -sf ca-trust/intermediate.crt /etc/tillandsias/ca.crt\n"
local a = src:find(FIX, 1, true)
if not a then verdict.emit("violation:" .. NAME .. ":no-subject", 1, "the 2018-cabd mount-point block is not in " .. CF) end

local REL = "target/plan-scratch/cabd" .. tostring(math.random(100000, 999999))
local DIR = ROOT .. "/" .. REL
fs.mkdir(REL .. "/trust")
fs.write(REL .. "/Containerfile.control", src:sub(1, a - 1) .. OLD .. src:sub(a + #FIX))

local mint = run({ "openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
    "-nodes", "-keyout", DIR .. "/ca.key", "-out", DIR .. "/trust/intermediate.crt", "-days", "1",
    "-subj", "/O=Tillandsias/CN=litmus CA", "-addext", "basicConstraints=critical,CA:TRUE" }, 60000)
if mint.code ~= 0 then verdict.could_not_run(NAME, "openssl req failed") end
local CRT = DIR .. "/trust/intermediate.crt"
local want = text.trim((run({ "sha256sum", CRT }, 30000).stdout or ""):match("^(%x+)") or "")
if #want ~= 64 then verdict.could_not_run(NAME, "sha256sum of the minted CA failed") end
local TAG = "localhost/tillandsias-git:litmus-cabd"
local CTAG = "localhost/tillandsias-git:litmus-cabd-control"
local function build(tag, file)
    local r = run({ "podman", "build", "-q", "-t", tag, "-f", file, ROOT .. "/images/git" }, 1800000)
    if r.code ~= 0 then verdict.could_not_run(NAME, "podman build " .. tag .. " failed: " .. text.trim(r.stderr or ""):sub(-300)) end
end
build(TAG, ROOT .. "/" .. CF)
build(CTAG, DIR .. "/Containerfile.control")
-- SELinux: podman gives the scratch the label the launcher's state dir carries.
-- Not chcon behind selinuxenabled: inside the gate's toolbox that answers no while
-- the host that runs the containers enforces, and every bind read "unreadable".
run({ "podman", "run", "--rm", "--network=none", "-v", DIR .. ":/label:ro,z", "--entrypoint", "/bin/sh", TAG, "-c", ":" }, 120000)

local PROBE = "if test -r /etc/tillandsias/ca.crt; then sha256sum < /etc/tillandsias/ca.crt | cut -c1-64; else echo unreadable; fi"
local ARMS = {
    { "FILE-V", { "-v", CRT .. ":/etc/tillandsias/ca.crt:ro" } },
    { "FILE-MOUNT", { "--mount", "type=bind,source=" .. CRT .. ",target=/etc/tillandsias/ca.crt,readonly=true" } },
    { "DIR", { "--mount", "type=bind,source=" .. DIR .. "/trust,target=/etc/tillandsias/ca-trust,readonly=true" } },
}
local SHAPE = "if test -f /etc/tillandsias/ca.crt && test -L /etc/tillandsias/ca.crt; then echo regular-file; else echo no-target; fi"
local MOUNTED = "if grep -q ' /etc/tillandsias/ca-trust/intermediate.crt ' /proc/self/mountinfo; then echo followed; else echo not-followed; fi"
local function probe(image, bind, what)
    local argv = { "podman", "run", "--rm", "--network=none", "--entrypoint", "/bin/sh" }
    for _, x in ipairs(bind) do argv[#argv + 1] = x end
    argv[#argv + 1] = image
    argv[#argv + 1] = "-c"
    argv[#argv + 1] = what or PROBE
    local r = run(argv, 120000)
    local out = text.trim(r.stdout or "")
    if r.code ~= 0 and out == "" then out = "run-failed:" .. tostring(r.code) end
    return out
end

local failed = {}
for _, arm in ipairs(ARMS) do
    local got = probe(TAG, arm[2])
    if got == want then
        io.stderr:write("ok:   " .. arm[1] .. " reads the bound CA\n")
    else
        failed[#failed + 1] = arm[1]
        io.stderr:write("FAIL: " .. arm[1] .. " got [" .. got .. "]\n")
    end
end
local shape, cshape = probe(TAG, {}, SHAPE), probe(CTAG, {}, SHAPE)
if shape == "regular-file" then
    io.stderr:write("ok:   SHAPE the image itself carries the CA mount point\n")
else
    failed[#failed + 1] = "SHAPE"
    io.stderr:write("FAIL: SHAPE got [" .. shape .. "]\n")
end
-- CONTROL: the pre-fix image fails arm 4, and the single-file binds unless the
-- runtime created the missing target (then the mount says so).
local caught = 0
if cshape ~= "no-target" then
    failed[#failed + 1] = "CONTROL-SHAPE"
    io.stderr:write("FAIL: CONTROL SHAPE got [" .. cshape .. "] on the pre-fix image\n")
end
for _, arm in ipairs({ ARMS[1], ARMS[2] }) do
    local got = probe(CTAG, arm[2])
    if got ~= want then
        caught = caught + 1
    elseif probe(CTAG, arm[2], MOUNTED) == "followed" then
        caught = caught + 1
        io.stderr:write("note: CONTROL " .. arm[1] .. " this runtime creates a missing symlink target; arm 4 is what tells the images apart here\n")
    else io.stderr:write("FAIL: CONTROL " .. arm[1] .. " read the CA on the pre-fix image\n") end
end
if caught ~= 2 then failed[#failed + 1] = "CONTROL" end

run({ "podman", "rmi", "-f", CTAG, TAG }, 120000)
if #failed > 0 then verdict.emit("refused:" .. NAME .. ":" .. table.concat(failed, ","), 1) end
verdict.emit("ok:" .. NAME .. ":4 arms+control", 0)

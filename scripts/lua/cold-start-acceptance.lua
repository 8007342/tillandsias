-- @trace order:1625-9qyw, order:1663-6mns, spec:local-web-preview, spec:inference-engine-slots
-- @env XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
--
-- cold-start-acceptance.lua — the operator's cold-start scenario, end to end,
-- on a SEALED nested substrate (order 1625-9qyw):
--
--   fresh install of a pinned release → a forge on a public web project →
--   from INSIDE the forge, host-browser MCP publish_local {runtime: auto} →
--   a host-side HTTPS fetch of the returned URL through the router →
--   service_status; then a forced router-step failure and its recovery.
--
-- No operator step between the install and the fetch.
--
-- WHY NESTED. Vault keeps its unseal share in the host OS keychain under the
-- fixed service "tillandsias". A scratch install on the host would read the
-- operator's real share and a scratch Vault init would overwrite it. Inside a
-- container with NO D-Bus session the product takes its documented headless
-- path (keyring unavailable → fallback file in its own cache dir). That is
-- PROVEN, not assumed: the structural proof below fails closed, and the host
-- keychain items' metadata (Created/Modified/Attributes via
-- org.freedesktop.Secret.Item properties, never GetSecret) must be identical
-- before and after.
--
-- OPT-IN ONLY. It needs privileged podman-in-podman and a release download, so
-- it refuses to act without --privileged-podman-in-podman, and its litmus is
-- size e2e (never in the default gate).
--
-- Usage:
--   tillandsias-plan script run scripts/lua/cold-start-acceptance.lua --timeout 180m -- \
--       --privileged-podman-in-podman <release-tag> [--expect-prefix-failure] [--keep]
--       [--project-ref <commit>|latest]
--
-- THE FIXTURE MOVES ON PURPOSE (operator direction, 2026-10-13): macron.dev is
-- AI-driven, and peers' smokes add notes to it over time, so the driver tests
-- its LATEST by default. The forge gets upstream's default branch through the
-- git mirror. The driver RECORDS the commit the forge holds in the transcript
-- and in the verdict, so every PASS names what it was a PASS on. To reproduce a
-- specific run, --project-ref <sha> refuses to judge any other commit:
--   blocked:cold-start-acceptance:project-ref-mismatch:wanted=<x>:forge=<y>   exit 2
--
-- Substrate: the outer container's podman store lives under
-- target/work/cold-start-acceptance/<run>/ (gitignored, inside the checkout).
-- Its runroot and libpod tmp_dir live in a private $XDG_RUNTIME_DIR dir:
-- pasta's SELinux domain cannot open its pid file under a home-labelled
-- checkout. XDG_RUNTIME_DIR itself stays real because netavark starts
-- aardvark-dns via systemd-run --user. Every podman call carries the scratch
-- config, and guard() refuses to act unless podman reports the scratch store.
--
-- Deviations inside the outer container, each a stand-in for something a real
-- host provides:
--   1 openssl
--   2 an empty /run/user/1000 (logind)
--   3 stock-host namespaces for the nested podman (the podman/stable image
--     forces host UTS, which refuses --hostname)
--   4 a random /etc/machine-id
--   5 a healthcheck ticker in place of systemd's healthcheck timers, started
--     AFTER the install: the installer's `podman system reset` strands one
--     started before it
--
-- Verdicts (last stdout line):
--   ok:cold-start-acceptance:<tag>:served:<url>:http=200:lakanoa-shape=built-nested-served:router-failure=step-qualified:recovered:app-dir=<served|release-predates>:project=<sha>   exit 0
--   ok:cold-start-acceptance:<tag>:prefix-failure:<reason>                                          exit 0
--   refused:cold-start-acceptance:<what>                                                             exit 1
--   blocked:cold-start-acceptance:project-ref-mismatch:wanted=<x>:forge=<y>  (only with --project-ref)  exit 2
--   skip:cold-start-acceptance:opt-in-required                                                       exit 0

local OPT_IN = "--privileged-podman-in-podman"
local opted, tag, expect_prefix, keep, project_ref = false, nil, false, false, "latest"
local i = 1
while i <= #arg do
    local a = arg[i]
    if a == OPT_IN then opted = true
    elseif a == "--expect-prefix-failure" then expect_prefix = true
    elseif a == "--keep" then keep = true
    elseif a == "--project-ref" then i = i + 1; project_ref = arg[i] or ""
    elseif a:sub(1, 2) ~= "--" then tag = a end
    i = i + 1
end
if project_ref ~= "latest" and not project_ref:match("^%x+$") then
    verdict.emit("refused:cold-start-acceptance:usage — --project-ref takes a commit sha or latest", 1)
end
if not opted then
    verdict.emit("skip:cold-start-acceptance:opt-in-required — pass " .. OPT_IN .. " <release-tag>", 0)
end
if not tag or not tag:match("^v%d+%.%d+%.%d+%.%d+$") then
    verdict.emit("refused:cold-start-acceptance:usage — a release tag like v56.10.12.1 is required", 1)
end

local IMAGE = "quay.io/podman/stable:v5.8.7"
local NAME = "cold-start-outer"
local VOL = "cold-start-inner-storage"
local PROJECT_URL = "https://github.com/8007342/macron.dev"
local RELEASE_BASE = "https://github.com/8007342/tillandsias/releases/download/" .. tag

local function run(argv, opts)
    opts = opts or {}
    opts.argv = argv
    opts.timeout_ms = opts.timeout_ms or 120000
    return proc.run(opts)
end
local function must(r, what)
    if r.code ~= 0 then
        verdict.emit("refused:cold-start-acceptance:" .. what .. " rc=" .. tostring(r.code) ..
            " " .. text.trim((r.stderr or "") .. (r.stdout or "")):sub(1, 400), 1)
    end
    return r
end

local REPO = text.trim(must(run({ "git", "rev-parse", "--show-toplevel" }), "repo-root").stdout)
local XRD = env.get("XDG_RUNTIME_DIR") or ""
if XRD == "" then verdict.emit("refused:cold-start-acceptance:no-XDG_RUNTIME_DIR", 1) end
local RUN = tag .. "-" .. time.iso_utc():gsub("[^%dTZ]", "")
local W = REPO .. "/target/work/cold-start-acceptance/" .. RUN
local OUT = W .. "/evidence"
fs.mkdir(OUT)
local R = text.trim(must(run({ "mktemp", "-d", XRD .. "/cold-start-acceptance.XXXXXX" }), "mktemp").stdout)
fs.mkdir(W .. "/graph")
fs.mkdir(W .. "/netconf")
must(run({ "mkdir", "-p", R .. "/run", R .. "/tmp" }), "runtime-dirs")
fs.write(W .. "/storage.conf", table.concat({ "[storage]", 'driver = "overlay"',
    'graphroot = "' .. W .. '/graph"', 'runroot = "' .. R .. '/run"', "" }, "\n"))
fs.write(W .. "/containers.conf", table.concat({ "[engine]", 'cgroup_manager = "cgroupfs"',
    'events_logger = "file"', 'events_logfile_path = "' .. W .. '/events.log"',
    'tmp_dir = "' .. R .. '/tmp"', "[network]", 'network_config_dir = "' .. W .. '/netconf"', "" }, "\n"))
-- The scratch podman environment. No D-Bus address is passed: proc.run starts
-- from a cleared environment, so the outer podman sees only these.
local PENV = { CONTAINERS_STORAGE_CONF = W .. "/storage.conf", CONTAINERS_CONF = W .. "/containers.conf",
    REGISTRY_AUTH_FILE = W .. "/auth.json", XDG_RUNTIME_DIR = XRD }

local function log_line(s)
    log.raw(s)
    fs.write(OUT .. "/transcript.txt", ((fs.exists(OUT .. "/transcript.txt") and fs.read(OUT .. "/transcript.txt")) or "") .. s .. "\n")
end

local function guard()
    local r = run({ "podman", "info", "--format", "{{.Store.GraphRoot}} {{.Store.RunRoot}}" }, { env = PENV })
    if text.trim(r.stdout or "") ~= W .. "/graph " .. R .. "/run" then
        verdict.emit("refused:cold-start-acceptance:guard — podman store is '" .. text.trim(r.stdout or "") ..
            "', not the scratch store", 1)
    end
end
local function podman(args, opts)
    guard()
    opts = opts or {}
    opts.env = PENV
    local argv = { "podman" }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    return run(argv, opts)
end
-- A bash script run INSIDE the outer container (as podman unless as_root).
local function inside(script, opts)
    opts = opts or {}
    local user = opts.as_root and "root" or "podman"
    return podman({ "exec", "-i", "--user", user, "-e", "XDG_RUNTIME_DIR=/run/user/1000", "-w", "/",
        NAME, "bash", "-s" }, { stdin = "set -u\n" .. script, timeout_ms = opts.timeout_ms or 600000 })
end

-- Host keychain metadata, read-only: item paths, then Label/Created/Modified/
-- Locked/Attributes properties. Never GetSecret, never a value.
local function keychain_meta()
    local kenv = { XDG_RUNTIME_DIR = XRD, DBUS_SESSION_BUS_ADDRESS = env.get("DBUS_SESSION_BUS_ADDRESS") or "" }
    local s = run({ "gdbus", "call", "--session", "--dest", "org.freedesktop.secrets", "--object-path",
        "/org/freedesktop/secrets", "--method", "org.freedesktop.Secret.Service.SearchItems",
        "{'service': 'tillandsias'}" }, { env = kenv })
    local lines = { "search(service=tillandsias) rc=" .. tostring(s.code) }
    for p in (s.stdout or ""):gmatch("/org/freedesktop/secrets/collection/[%w_/]+") do
        for _, prop in ipairs({ "Label", "Created", "Modified", "Locked", "Attributes" }) do
            local g = run({ "gdbus", "call", "--session", "--dest", "org.freedesktop.secrets", "--object-path", p,
                "--method", "org.freedesktop.DBus.Properties.Get", "org.freedesktop.Secret.Item", prop }, { env = kenv })
            lines[#lines + 1] = p .. " " .. prop .. "=" .. text.trim(g.stdout or g.stderr or "")
        end
    end
    return table.concat(lines, "\n") .. "\n"
end

local function down()
    podman({ "rm", "-f", NAME })
    podman({ "volume", "rm", "-f", VOL })
    podman({ "rmi", "-a", "-f" }, { timeout_ms = 600000 })
    -- One unshare: lazy-unmount the scratch mounts, then remove the trees whose
    -- files belong to subordinate uids.
    podman({ "unshare", "bash", "-c", 'for d in "$1" "$2"; do grep -F "$d" /proc/self/mountinfo > "$1/mounts.$$" 2>/dev/null; ' ..
        'while read -r _ _ _ _ m _; do umount -l "$m"; done < "$1/mounts.$$"; done; rm -rf "$1/graph" "$2"',
        "_", W, R }, { timeout_ms = 600000 })
    -- Every podman invocation (the unshare above included) recreates an empty
    -- storage skeleton; with podman done, remove it without podman. find, not
    -- rm: proc.run's policy asks consent for an rm outside the repository.
    run({ "find", W .. "/graph", R, "-delete" })
    log_line("substrate removed: " .. W .. "/graph and " .. R .. " (evidence kept in " .. OUT .. ")")
end
local function fail(what)
    log_line("FAIL: " .. what)
    if not keep then down() end
    verdict.emit("refused:cold-start-acceptance:" .. what, 1)
end

-- ── 0. host keychain before ─────────────────────────────────────────────────
local KEY_BEFORE = keychain_meta()
fs.write(OUT .. "/keychain-before.txt", KEY_BEFORE)
log_line("run " .. RUN .. ": release " .. tag .. ", substrate " .. W .. " + " .. R)

-- ── 1. outer container (privileged, rootless on the host) ───────────────────
guard()
must(podman({ "pull", "-q", IMAGE }, { timeout_ms = 900000 }), "pull-outer-image")
podman({ "volume", "create", VOL })
-- FLAGS: --privileged lets netavark set ip_forward and use /dev/net/tun for the
-- nested bridge networks. No host path, socket, env or runtime dir goes in.
must(podman({ "run", "-d", "--name", NAME, "--privileged", "--user", "podman",
    "-v", VOL .. ":/home/podman/.local/share/containers", IMAGE, "sleep", "infinity" }), "outer-run")
log_line("outer: podman run -d --name " .. NAME .. " --privileged --user podman -v " .. VOL ..
    ":/home/podman/.local/share/containers " .. IMAGE .. " sleep infinity")

-- ── 2. deviations 1-4 ───────────────────────────────────────────────────────
must(inside([[
dnf -y -q install openssl >/dev/null
install -d -o podman -g podman -m 0700 /run/user/1000
od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > /etc/machine-id
cat > /home/podman/.config/containers/containers.conf <<'EOF'
# cold-start-acceptance deviation 3: stock-host namespaces (the image forces
# host UTS/IPC and binds /proc into every container). cgroups stay disabled:
# a nested container has no cgroup delegation.
[containers]
netns = "private"
userns = "host"
ipcns = "shareable"
utsns = "private"
cgroupns = "private"
cgroups = "disabled"
volumes = []
default_sysctls = []
[network]
pasta_options = ["--ipv4-only"]
EOF
chown podman:podman /home/podman/.config/containers/containers.conf
echo "deviations: $(rpm -q openssl) runtime-dir machine-id=$(wc -c < /etc/machine-id)B containers.conf"
]], { as_root = true }), "deviations")

-- ── 3. structural proof: no keychain reachable, by construction ─────────────
local proof = inside([[
echo "DBUS_SESSION_BUS_ADDRESS=${DBUS_SESSION_BUS_ADDRESS-<unset>}"
b=$(ls -d /run/user/*/bus /run/dbus/system_bus_socket 2>/dev/null); echo "bus sockets: ${b:-none}"
k=$(ls -d "$HOME/.local/share/keyrings" 2>/dev/null); echo "keyrings dir: ${k:-none}"
n=0; for c in /proc/[0-9]*/comm; do case "$(cat "$c" 2>/dev/null)" in *dbus*|*keyring*|*kwalletd*|*secret*) n=$((n+1));; esac; done
echo "session daemons: $n"
gdbus call --session --dest org.freedesktop.secrets --object-path /org/freedesktop/secrets --method org.freedesktop.DBus.Peer.Ping >/dev/null 2>&1; echo "probe gdbus --session rc=$?"
busctl --user list >/dev/null 2>&1; echo "probe busctl --user rc=$?"
]])
fs.write(OUT .. "/structural-proof.txt", proof.stdout or "")
for _, want in ipairs({ "DBUS_SESSION_BUS_ADDRESS=<unset>", "bus sockets: none", "keyrings dir: none",
    "session daemons: 0" }) do
    if not text.contains(proof.stdout or "", want) then fail("structural-proof:" .. want) end
end
for _, probe in ipairs({ "gdbus", "busctl" }) do
    if text.contains(proof.stdout or "", "probe " .. probe .. " --session rc=0")
        or text.contains(proof.stdout or "", "probe " .. probe .. " --user rc=0") then
        fail("structural-proof:" .. probe .. "-reached-a-bus")
    end
end
log_line("structural proof: no bus address, no bus socket, no keyrings, no session daemons, probes fail")

-- ── 4. fresh install, pinned, installer sha checked against SHA256SUMS ──────
local inst = inside([[
cd /home/podman
curl -fsSL -o install.sh ]] .. RELEASE_BASE .. [[/install.sh
curl -fsSL -o SHA256SUMS ]] .. RELEASE_BASE .. [[/SHA256SUMS
got=$(sha256sum install.sh | cut -d' ' -f1); want=$(grep ' install.sh$' SHA256SUMS | cut -d' ' -f1)
echo "installer sha256 $got (SHA256SUMS: $want)"
[ -n "$want" ] && [ "$got" = "$want" ] || { echo "INSTALLER-SHA-MISMATCH"; exit 3; }
TILLANDSIAS_RELEASE_BASE=]] .. RELEASE_BASE .. [[ bash install.sh > install.log 2>&1; echo "install rc=$?"
grep -E '^(SUCCESS|FAILED) ' install.log | tr '\n' ' '; echo
.local/bin/tillandsias --version
podman images --format '{{.Repository}}:{{.Tag}}' | grep -c . | sed 's/^/inner image refs: /'
podman images --format '{{.Repository}}:{{.Tag}}' | grep -E 'tillandsias-web' || true
]], { timeout_ms = 7200000 })
fs.write(OUT .. "/install.txt", inst.stdout or "")
if inst.code ~= 0 or not text.contains(inst.stdout or "", "install rc=0") then fail("install") end
log_line("install: " .. text.trim(inst.stdout or ""):gsub("\n", " | "))

-- ── 5. deviation 5: healthcheck ticker, AFTER the install ───────────────────
must(podman({ "exec", "-d", "--user", "podman", "-e", "XDG_RUNTIME_DIR=/run/user/1000", NAME, "bash", "-c",
    "while true; do for c in $(podman ps --format '{{.Names}}'); do podman healthcheck run \"$c\" >/dev/null 2>&1; done; sleep 5; done" }),
    "hc-ticker")

-- ── 6. the lane: a forge on the project, no tty ─────────────────────────────
local launch = inside([[
cd /home/podman
[ -d src/macron.dev/.git ] || git clone -q ]] .. PROJECT_URL .. [[ src/macron.dev
git -C src/macron.dev log -1 --format='project %H (%s)'
for attempt in 1 2; do
  nohup sh -c "sleep infinity | /home/podman/.local/bin/tillandsias --bash /home/podman/src/macron.dev --debug" > launch-$attempt.log 2>&1 &
  for i in $(seq 1 360); do
    f=$(podman ps --format '{{.Names}}' --filter 'name=macron.*-forge')
    [ -n "$f" ] && { echo "forge $f up on attempt $attempt after $((i*5))s"; exit 0; }
    grep -q '^Error:' launch-$attempt.log && break
    sleep 5
  done
  echo "attempt $attempt: no forge ($(grep -m1 '^Error:' launch-$attempt.log))"
  pkill -f 'tillandsias --bash' 2>/dev/null; sleep 5
done
exit 1
]], { timeout_ms = 3900000 })
fs.write(OUT .. "/launch.txt", launch.stdout or "")
if launch.code ~= 0 then fail("launch") end
log_line(text.trim(launch.stdout or ""):gsub("\n", " | "))

-- ── 6b. the forge's live source: at forge-up, hydrated, at publish ──────────
-- Order 1663-6mns (v56.10.13.1 run): the driver used to publish the moment the
-- forge's NAME appeared, while the forge entrypoint was still cloning the
-- project from the mirror into its RAM workspace. With a ~40 MB checkout
-- publish_local answered "source_not_found". Record the state the old driver
-- published into, including the forge's clone and HOT-budget log lines, then
-- wait for the checkout like an agent would, then record it again.
local function forge_source_state(label)
    local r = inside([[
f=$(podman ps --format '{{.Names}}' --filter 'name=macron.*-forge')
echo "== ]] .. label .. [[ $(date -u +%H:%M:%S)"
podman exec "$f" sh -c 'if cd /home/forge/src/macron.dev 2>/dev/null; then echo "head=$(git rev-parse --verify -q HEAD 2>/dev/null || echo none) tracked=$(git ls-files 2>/dev/null | wc -l) wrangler=$(test -f wrangler.jsonc && echo yes || echo no) public_index=$(test -f public/index.html && echo yes || echo no) du=$(du -sh . 2>/dev/null | cut -f1)"; else echo "no /home/forge/src/macron.dev yet"; fi; df -h /home/forge/src 2>/dev/null | tail -1'
echo "-- forge log (clone, mirror, budget):"
podman logs "$f" 2>&1 | grep -iE 'git-mirror|budget|clone|hot|FATAL|\[forge\]' | tail -40
]])
    return r.stdout or ""
end
local at_up = forge_source_state("at forge-up (where the pre-1663-pin driver published)")
local hydrate = inside([[
f=$(podman ps --format '{{.Names}}' --filter 'name=macron.*-forge')
for i in $(seq 1 120); do
  if podman exec "$f" sh -c 'test -f /home/forge/src/macron.dev/wrangler.jsonc && git -C /home/forge/src/macron.dev rev-parse --verify -q HEAD' >/dev/null 2>&1; then
    echo "source hydrated $((i*5 - 5))s after forge-up"; exit 0
  fi
  sleep 5
done
echo "source NOT hydrated 600s after forge-up"; exit 1
]], { timeout_ms = 700000 })
local at_publish = forge_source_state("at publish")
fs.write(OUT .. "/forge-source.txt", at_up .. "\n" .. (hydrate.stdout or "") .. "\n" .. at_publish)
log_line("forge source: " .. text.trim(hydrate.stdout or "") .. "; at forge-up: " ..
    (at_up:match("head=[^\n]*") or at_up:match("no /home/forge/src/macron.dev yet") or "?"))
if hydrate.code ~= 0 then fail("forge-source-not-hydrated (see forge-source.txt)") end
local forge_head = at_publish:match("head=(%x+)") or "none"
log_line("project: forge holds " .. forge_head .. " (wanted " .. project_ref .. ")")
if project_ref ~= "latest" and forge_head:sub(1, #project_ref) ~= project_ref then
    log_line("BLOCKED: project-ref-mismatch")
    if not keep then down() end
    verdict.emit("blocked:cold-start-acceptance:project-ref-mismatch:wanted=" .. project_ref .. ":forge=" .. forge_head, 2)
end

-- ── 7. MCP from inside the forge, then a host-side fetch ────────────────────
local function mcp(calls)
    local req = { '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"cold-start-acceptance","version":"1"}}}',
        '{"jsonrpc":"2.0","method":"notifications/initialized"}' }
    for i, c in ipairs(calls) do
        req[#req + 1] = '{"jsonrpc":"2.0","id":' .. (i + 1) .. ',"method":"tools/call","params":{"name":"' ..
            c[1] .. '","arguments":' .. c[2] .. '}}'
    end
    -- The server exits on stdin EOF, so hold stdin open until every reply is in.
    local r = inside([[
f=$(podman ps --format '{{.Names}}' --filter 'name=macron.*-forge')
cat > /tmp/mcp.req <<'EOF'
]] .. table.concat(req, "\n") .. [[

EOF
: > /tmp/mcp.resp
{ cat /tmp/mcp.req; for i in $(seq 1 900); do sleep 1; [ "$(grep -c '"id":' /tmp/mcp.resp)" -ge ]] .. (#calls + 1) .. [[ ] && break; done; } \
  | podman exec -i "$f" /home/forge/.config-overlay/mcp/host-browser.sh > /tmp/mcp.resp 2>/tmp/mcp.err
cat /tmp/mcp.resp
]], { timeout_ms = 1200000 })
    local byid = {}
    for _, line in ipairs(text.lines(r.stdout or "")) do
        local ok, msg = pcall(json.parse, line)
        if ok and type(msg) == "table" and msg.id then byid[msg.id] = msg end
    end
    return byid, r.stdout or ""
end
local function fetch(url)
    local r = inside([[
curl -sS -m 20 --cacert /home/podman/.local/state/tillandsias/ca/intermediate.crt -o /tmp/fetched.html \
  -w 'http=%{http_code} bytes=%{size_download} ssl_verify=%{ssl_verify_result}\n' ']] .. url .. [['
grep -o '<title>[^<]*</title>' /tmp/fetched.html
]])
    return text.trim(r.stdout or "")
end
-- A tools/call success payload. Since 1696-gz2y every success is an MCP
-- CallToolResult: the payload as JSON in content[1].text and as
-- structuredContent. Earlier releases (v56.10.14.1 and before) returned it
-- bare. Read all three, so the driver judges any release, not only the shape
-- it was written against.
local function payload(msg)
    local r = msg and msg.result
    if type(r) ~= "table" then return nil end
    if type(r.structuredContent) == "table" then return r.structuredContent end
    if type(r.content) == "table" and r.content[1] and type(r.content[1].text) == "string" then
        local ok, v = pcall(json.parse, r.content[1].text)
        if ok and type(v) == "table" then return v end
        return nil
    end
    return r
end
local function result_url(msg) local p = payload(msg); return p and p.url end

local res, raw = mcp({ { "publish_local", '{"category":"WEB","runtime":"auto"}' }, { "service_status", "{}" } })
fs.write(OUT .. "/publish-auto.ndjson", raw)
local url = result_url(res[2])

if expect_prefix then
    local reason = res[2] and res[2].error and res[2].error.message or "<no error>"
    log_line("pre-fix publish_local auto: " .. reason .. "; service_status state=" ..
        tostring(payload(res[3]) and payload(res[3]).state))
    if url then fail("prefix-unexpectedly-served:" .. url) end
    fs.write(OUT .. "/keychain-after.txt", keychain_meta())
    if fs.read(OUT .. "/keychain-after.txt") ~= KEY_BEFORE then fail("host-keychain-metadata-changed") end
    if not keep then down() end
    verdict.emit("ok:cold-start-acceptance:" .. tag .. ":prefix-failure:" .. reason, 0)
end

if not url then fail("publish-auto-no-url:" .. raw:sub(1, 300)) end
local runtime = payload(res[2]).runtime
local got = fetch(url)
log_line("publish_local auto: runtime=" .. tostring(runtime) .. " url=" .. url .. "; fetch: " .. got:gsub("\n", " "))
if not text.contains(got, "http=200") or not text.contains(got, "ssl_verify=0") or not text.contains(got, "<title>") then
    fail("fetch:" .. got)
end

-- ── 7b. a lakanoa-SHAPED project: nested assets plus a build step ──────────
-- Order 1663-6mns (operator failure on yoga, 2026-10-13; lakanoa itself is
-- private, so nothing of it is used). Its shape, written into the FORGE's
-- live worktree as an agent would: wrangler.jsonc names a NESTED assets
-- directory (arkanoid-web-game/public) produced by a build in a subdirectory
-- (npm ci && npm run build, cwd arkanoid-web-game). The build is
-- dependency-free, so npm ci needs no network. macron.dev's own root public/
-- stays in place: serving it would be the WRONG ROOT.
--   1. before the build: publish_local refuses, naming the directory and the
--      build command (it never serves the root or nothing as if fine);
--   2. after the build, run in the forge: it serves the BUILT index, whose
--      title is the marker, not macron.dev's.
local MARKER = "LAKANOA-SHAPE-BUILT"
must(inside([[
f=$(podman ps --format '{{.Names}}' --filter 'name=macron.*-forge')
podman exec -i "$f" sh -s <<'FORGE'
set -e
cd /home/forge/src/macron.dev
cat > wrangler.jsonc <<'J'
{"name":"lakanoa-shape","compatibility_date":"2026-10-01","assets":{"directory":"arkanoid-web-game/public"},"build":{"command":"npm ci && npm run build","cwd":"arkanoid-web-game"}}
J
mkdir -p arkanoid-web-game
cat > arkanoid-web-game/package.json <<'J'
{"name":"arkanoid-shape","version":"1.0.0","private":true,"scripts":{"build":"node build.js"}}
J
cat > arkanoid-web-game/package-lock.json <<'J'
{"name":"arkanoid-shape","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"arkanoid-shape","version":"1.0.0"}}}
J
cat > arkanoid-web-game/build.js <<'J'
const fs = require('fs');
fs.mkdirSync('public', { recursive: true });
fs.writeFileSync('public/index.html', '<!doctype html><title>LAKANOA-SHAPE-BUILT</title><p>built in arkanoid-web-game</p>\n');
J
echo "lakanoa-shaped fixture written: $(ls arkanoid-web-game | tr '\n' ' ')"
FORGE
]]), "lakanoa-shape-fixture")
mcp({ { "service_stop", '{"category":"WEB"}' } })
local lres, lraw = mcp({ { "publish_local", '{"category":"WEB","runtime":"auto"}' } })
fs.write(OUT .. "/publish-lakanoa-shape-unbuilt.ndjson", lraw)
local lreason = lres[2] and lres[2].error and lres[2].error.message or ""
local lurl = result_url(lres[2])
log_line("lakanoa-shape before build: url=" .. tostring(lurl) .. " reason=" .. lreason)
if lurl or not text.contains(lreason, "arkanoid-web-game/public")
    or not text.contains(lreason, "npm ci && npm run build") then
    fail("lakanoa-shape-unbuilt-not-refused-with-the-build-command:" .. lraw:sub(1, 300))
end
local built = must(inside([[
f=$(podman ps --format '{{.Names}}' --filter 'name=macron.*-forge')
podman exec "$f" sh -c 'cd /home/forge/src/macron.dev/arkanoid-web-game && npm ci && npm run build' 2>&1 | tail -3
podman exec "$f" sh -c 'ls -l /home/forge/src/macron.dev/arkanoid-web-game/public/index.html'
]], { timeout_ms = 300000 }), "lakanoa-shape-build")
log_line("lakanoa-shape build in the forge: " .. text.trim(built.stdout or ""):gsub("\n", " | "))
local bres, braw = mcp({ { "publish_local", '{"category":"WEB","runtime":"auto"}' } })
fs.write(OUT .. "/publish-lakanoa-shape-built.ndjson", braw)
local burl = result_url(bres[2])
local bgot = burl and fetch(burl) or ""
log_line("lakanoa-shape after build: url=" .. tostring(burl) .. " fetch: " .. bgot:gsub("\n", " "))
if not burl or not text.contains(bgot, "http=200") or not text.contains(bgot, "<title>" .. MARKER .. "</title>") then
    fail("lakanoa-shape-built-not-served:" .. (bgot ~= "" and bgot or braw:sub(1, 300)))
end

-- ── 7c. a SUBDIRECTORY app published with app_dir (order 1667-6rtp) ───────
-- A monorepo shape: site-app/ has its own wrangler.jsonc and public/, beside
-- the root config 7b left. publish_local {app_dir: "site-app"} must serve
-- site-app/public (its marker title), never the root's app. An escaping
-- app_dir is refused by name, and service_reload republishes the same app.
-- A release older than 1667 IGNORES app_dir, so it answers the escape probe
-- with a URL instead of invalid_app_dir. The arm then records
-- app-dir=release-predates and moves on, never a false pass.
local APP_MARKER = "APP-DIR-SHAPE"
must(inside([[
f=$(podman ps --format '{{.Names}}' --filter 'name=macron.*-forge')
podman exec -i "$f" sh -s <<'FORGE'
set -e
cd /home/forge/src/macron.dev
mkdir -p site-app/public
cat > site-app/wrangler.jsonc <<'J'
{"name":"app-dir-shape","compatibility_date":"2026-10-01","assets":{"directory":"./public"}}
J
printf '<!doctype html><title>APP-DIR-SHAPE</title><p>served from site-app/public</p>\n' > site-app/public/index.html
echo "app-dir fixture written: $(ls site-app site-app/public | tr '\n' ' ')"
FORGE
]]), "app-dir-fixture")
mcp({ { "service_stop", '{"category":"WEB"}' } })
local eres, eraw = mcp({ { "publish_local", '{"category":"WEB","runtime":"auto","app_dir":"../escape"}' } })
fs.write(OUT .. "/publish-app-dir-escape.ndjson", eraw)
local ereason = eres[2] and eres[2].error and eres[2].error.message or ""
local app_dir_result
if result_url(eres[2]) then
    log_line("app-dir: release predates app_dir (the escape probe was published, not refused); arm skipped")
    mcp({ { "service_stop", '{"category":"WEB"}' } })
    app_dir_result = "release-predates"
else
    log_line("app-dir escape: " .. ereason)
    if not text.contains(ereason, "invalid_app_dir:") then fail("app-dir-escape-not-refused-by-name:" .. eraw:sub(1, 300)) end
    local ares, araw = mcp({ { "publish_local", '{"category":"WEB","runtime":"auto","app_dir":"site-app"}' } })
    fs.write(OUT .. "/publish-app-dir.ndjson", araw)
    local aurl = result_url(ares[2])
    local agot = aurl and fetch(aurl) or ""
    log_line("app-dir site-app: url=" .. tostring(aurl) .. " fetch: " .. agot:gsub("\n", " "))
    if not aurl or not text.contains(agot, "http=200") or not text.contains(agot, "<title>" .. APP_MARKER .. "</title>") then
        fail("app-dir-not-served:" .. (agot ~= "" and agot or araw:sub(1, 300)))
    end
    local _, reload_raw = mcp({ { "service_reload", '{"category":"WEB"}' } })
    fs.write(OUT .. "/reload-app-dir.ndjson", reload_raw)
    local again = fetch(aurl)
    log_line("app-dir after service_reload: " .. again:gsub("\n", " "))
    if not text.contains(again, "<title>" .. APP_MARKER .. "</title>") then
        fail("app-dir-lost-on-reload:" .. (again ~= "" and again or reload_raw:sub(1, 300)))
    end
    app_dir_result = "served"
end

-- ── 8. forced router-step failure (another app holds the router's port) ─────
mcp({ { "service_stop", '{"category":"WEB"}' } })
must(inside([[
podman rm -f tillandsias-router >/dev/null
podman run -d --name port-holder -p 127.0.0.1:18443:80 docker.io/library/alpine:3.20 sleep 3600 >/dev/null
podman ps --format '{{.Names}} {{.Ports}}' | grep port-holder
]]), "port-holder")
local fres, fraw = mcp({ { "publish_local", '{"category":"WEB","runtime":"auto"}' }, { "service_status", "{}" } })
fs.write(OUT .. "/publish-router-failure.ndjson", fraw)
local freason = fres[2] and fres[2].error and fres[2].error.message or ""
local lf = payload(fres[3]) and payload(fres[3]).last_failure
log_line("forced failure: " .. freason .. "; last_failure step=" .. tostring(lf and lf.step) ..
    " class=" .. tostring(lf and lf.class) .. " remedy=" .. tostring(lf and lf.remedy))
if not text.contains(freason, "podman failed at step router") or not lf or lf.step ~= "router" then
    fail("router-failure-not-step-qualified:" .. fraw:sub(1, 300))
end

-- ── 9. recovery once the cause is gone ──────────────────────────────────────
inside("podman rm -f port-holder >/dev/null; podman rmi -f docker.io/library/alpine:3.20 >/dev/null 2>&1; true")
local rres, rraw = mcp({ { "publish_local", '{"category":"WEB","runtime":"auto"}' }, { "service_status", "{}" } })
fs.write(OUT .. "/publish-recovered.ndjson", rraw)
local rurl = result_url(rres[2])
local rgot = rurl and fetch(rurl) or ""
local rlf = payload(rres[3]) and payload(rres[3]).last_failure
log_line("recovered: url=" .. tostring(rurl) .. " fetch: " .. rgot:gsub("\n", " ") .. " last_failure=" .. tostring(rlf ~= nil))
if not rurl or not text.contains(rgot, "http=200") or rlf ~= nil then fail("no-recovery") end

-- ── 10. host keychain after ─────────────────────────────────────────────────
local KEY_AFTER = keychain_meta()
fs.write(OUT .. "/keychain-after.txt", KEY_AFTER)
if KEY_AFTER ~= KEY_BEFORE then fail("host-keychain-metadata-changed") end
log_line("host keychain: service=tillandsias item metadata identical before and after")

inside("pkill -f 'tillandsias --bash' 2>/dev/null; true")
if not keep then down() end
verdict.emit("ok:cold-start-acceptance:" .. tag .. ":served:" .. url .. ":http=200:lakanoa-shape=built-nested-served:router-failure=step-qualified:recovered:app-dir=" .. app_dir_result .. ":project=" .. forge_head, 0)

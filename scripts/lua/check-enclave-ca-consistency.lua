-- @env TILLANDSIAS_CA_DIR HOME
-- @trace order:975-rsgm, order:998-qrwu, spec:proxy-container
--
-- check-enclave-ca-consistency.lua — is the enclave CA bundle present, and does
-- the proxy's private key still match the certificate it will be served?
-- Ported from check-enclave-ca-consistency.sh. The CA directory comes from the
-- ONE declaration (images/default/ca-path.txt, the scripts/lib-ca-path.sh rule),
-- never a literal.
--
-- THE FAILURE THIS NAMES (yoga, 2026-09-03, five cycles reporting only
-- fail:enclave-service-start-failed): the CA bundle vanished, the documented
-- remedy re-materialised it with a NEW keypair, but the proxy reads its KEY from
-- the podman secret tillandsias-ca-key, refreshed on the launch path only. A proxy
-- brought up any other way kept the OLD key and died with
-- "X509_check_private_key() failed" / "No valid signing certificate configured",
-- which reads as a proxy bug. The remedy changed the failure's signature without
-- fixing it; this reports the CONDITION instead.
--
-- Grammar (one verdict line on stdout; detail on stderr):
--   ^(ok:enclave-ca-consistent|violation:enclave-ca-absent:bundle|violation:enclave-ca-desync:key-secret|skip:[a-z0-9-]+)$
-- The .sh said absent:enclave-ca-bundle / desync:enclave-ca-key-secret; the
-- script runner emits only house prefixes, so the port says violation: with the
-- condition named, exit 1. scripts/cycle-preflight.sh maps both back to its
-- +ca-absent / +ca-desync report.
--
-- The .sh compared openssl md5 digests of the two moduli; comparing the modulus
-- strings is the same equality with no hashing, and the secret's key reaches
-- openssl on stdin (proc.run stdin), never through a temp file.
local SECRET = "tillandsias-ca-key"

local function run(argv, stdin)
    local spec = { argv = argv, timeout_ms = 30000 }
    if stdin then spec.stdin = stdin end
    local r = proc.run(spec)
    return r.status == "exited" and r.code == 0, text.trim(r.stdout or "")
end

local ca_dir = env.get("TILLANDSIAS_CA_DIR") or ""
if ca_dir == "" then
    local manifest = "images/default/ca-path.txt"
    local ok, body = pcall(fs.read, manifest)
    if not ok or not body then
        log.raw("blocked:ca-path:manifest-unreadable:" .. manifest)
        verdict.emit("skip:ca-path-manifest-unreadable", 0)
    end
    local tmpl
    for _, line in ipairs(text.lines(body)) do
        local t = text.trim(line)
        if t ~= "" and t:sub(1, 1) ~= "#" then tmpl = t:gsub("%s", ""); break end
    end
    if not tmpl then verdict.emit("skip:ca-path-manifest-empty", 0) end
    ca_dir = tmpl:gsub("%${HOME}", function() return env.get("HOME") or "" end) .. "/ca"
end
local cert = ca_dir .. "/intermediate.crt"

if not run({ "podman", "--version" }) then verdict.emit("skip:no-podman", 0) end
if not run({ "openssl", "version" }) then verdict.emit("skip:no-openssl", 0) end

-- Nothing to be consistent WITH if the enclave was never provisioned here.
if not run({ "podman", "secret", "inspect", SECRET }) then verdict.emit("skip:no-enclave-ca-secret", 0) end

if not run({ "test", "-r", cert }) then
    log.raw("  " .. cert .. " is missing. A proxy CREATED at or after 998-3z6g binds it by that")
    log.raw("  path (podman records the bind SOURCE at container creation), so it cannot start until the")
    log.raw("  bundle exists; an older container may still bind the previous /tmp path — run")
    log.raw("  tillandsias-plan script run scripts/lua/check-ca-bind-migration.lua to see which containers bind which path, and recreate")
    log.raw("  (never restart) the stale ones.")
    log.raw("  The bundle is materialized by the enclave orchestration, not by the")
    log.raw("  container that binds it, so an absent bundle is a provisioning gap")
    log.raw("  rather than a fault of the proxy (975-rsgm).")
    log.raw("  REMEDY: bring the enclave up through the orchestration: `tillandsias --ensure-enclave`")
    log.raw("  (idempotent; the same ensure a lane launch runs). NOT `tillandsias --init`, which only")
    log.raw("  builds images and never touches the proxy (1004-xw3q).")
    verdict.emit("violation:enclave-ca-absent:bundle", 1)
end

-- The proxy is served the CERT from the bind and the KEY from the secret. If they
-- were generated at different times they will not match.
local cert_ok, cert_mod = run({ "openssl", "x509", "-noout", "-modulus", "-in", cert })
local sec_ok, sec_data = run({ "podman", "secret", "inspect", "--showsecret", "--format", "{{.SecretData}}", SECRET })
local key_mod = ""
if sec_ok and sec_data ~= "" then
    local k_ok, k = run({ "openssl", "rsa", "-noout", "-modulus" }, sec_data .. "\n")
    if k_ok then key_mod = k end
end

-- A podman that cannot reveal secret data is a real limitation, not a desync.
if key_mod == "" then verdict.emit("skip:secret-data-unreadable", 0) end
if not cert_ok or cert_mod == "" then verdict.emit("skip:cert-unreadable", 0) end

if cert_mod ~= key_mod then
    log.raw("  The proxy's certificate and its private key do not match.")
    log.raw("    cert   " .. cert .. " (bind mount)")
    log.raw("    key    podman secret '" .. SECRET .. "'")
    log.raw("  squid will start and then die with X509_check_private_key() failed")
    log.raw("  and 'No valid signing certificate configured' — a message that names")
    log.raw("  neither of the two files, which is why this reads as a proxy bug.")
    log.raw("  CAUSE: the CA was regenerated without rotating the secret.")
    log.raw("  ensure_proxy_ca_key_secret refreshes it with --replace on the LAUNCH")
    log.raw("  path only, so a proxy brought up with `podman start` keeps the old key (975-rsgm).")
    log.raw("  REMEDY: bring the proxy up through the orchestration — `tillandsias --ensure-enclave`,")
    log.raw("  which refreshes the secret from the current bundle — never `podman start` and not `--init`.")
    verdict.emit("violation:enclave-ca-desync:key-secret", 1)
end

verdict.emit("ok:enclave-ca-consistent", 0)

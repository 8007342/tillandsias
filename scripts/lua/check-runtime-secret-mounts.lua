-- @env TILLANDSIAS_RUNTIME_SECRET_SRC
-- @read-env TILLANDSIAS_RUNTIME_SECRET_SRC
-- @trace order:1118-fqfk, spec:podman-secrets-integration, spec:podman-idiomatic-patterns
--
-- check-runtime-secret-mounts.lua — 1118-fqfk slice 2a. Credentials reach a
-- container as RUNTIME SECRET FILES: 0444 files in the 0700 tmpfs directory
-- $XDG_RUNTIME_DIR/tillandsias/secrets, bound read-only at /run/secrets/<target>
-- by runtime_secret_volume / runtime_secret_bind. Podman secrets are retired:
-- their file driver and each container's copy are plaintext on durable disk.
--
-- One check per argument, each with teeth:
--   forge-opencode  build_opencode_forge_args mounts EXACTLY ONE token, gated
--                   on opencode_vault_secret, with GIT_VAULT_TOKEN_SECRET_OPTS
--   forge-agent     build_forge_agent_run_args_with_vault: the same, gated on
--                   mode_provider_pair(mode).is_some()
--   proxy           build_proxy_run_args delivers the CA key with
--                   runtime_secret_volume(PROXY_CA_KEY_SECRET, ...), never binds
--                   intermediate.key, never uses a podman secret
-- Every check also proves the helpers still bind from the 0700 tmpfs dir.
-- A second token, a podman --secret, a hand-written /run/secrets bind, or a
-- durable-path helper is a violation.
--
-- Seam for the fixture: TILLANDSIAS_RUNTIME_SECRET_SRC replaces the source dir
-- (default crates/tillandsias-headless/src).
--
-- Usage: tillandsias-plan script run scripts/lua/check-runtime-secret-mounts.lua -- <check>

local src = env.get("TILLANDSIAS_RUNTIME_SECRET_SRC") or "crates/tillandsias-headless/src"
local which = arg[1] or ""

local function body(text, decl)
    local s = text:find("\n" .. decl, 1, true)
    if not s then return nil end
    local e = text:find("\n}\n", s + 1, true)
    return text:sub(s + 1, (e or #text))
end

local function count(hay, needle)
    local n, i = 0, 1
    while true do
        local s = hay:find(needle, i, true)
        if not s then return n end
        n, i = n + 1, s + 1
    end
end

local function fail(why)
    log.raw("  why: " .. why)
    log.raw("  remedy: deliver the credential with crate::vault_bootstrap::runtime_secret_volume/_bind (tmpfs, 0700 dir), one token per forge, never a podman secret or a durable-path bind (1118-fqfk)")
    verdict.emit("violation:runtime-secret-mounts:" .. which, 1)
end

local ok_v, vb = pcall(fs.read, src .. "/vault_bootstrap.rs")
local ok_m, main = pcall(fs.read, src .. "/main.rs")
if not (ok_v and ok_m) then
    verdict.emit("could-not-run:runtime-secret-mounts:no-source:" .. src, 2)
end

-- The helpers: both resolve into runtime_secret_path, which lives under the
-- runtime dir (unseal_key_file_path's parent), and the writer refuses off tmpfs
-- and creates the 0700 directory no other host user can traverse.
local hv = body(vb, "pub(crate) fn runtime_secret_volume(") or ""
local hb = body(vb, "pub(crate) fn runtime_secret_bind(") or ""
local hp = body(vb, "pub(crate) fn runtime_secret_path(") or ""
local hw = body(vb, "pub(crate) fn write_runtime_secret(") or ""
if not (hv:find("runtime_secret_path(", 1, true) and hb:find("runtime_secret_path(", 1, true)
        and hp:find("unseal_key_file_path()", 1, true)
        and hw:find("refused:runtime-secret-not-tmpfs", 1, true) and hw:find("mode(0o700)", 1, true)) then
    fail("the runtime secret helpers no longer bind from the 0700 tmpfs secrets dir (a durable-path bind)")
end

local function forge(decl, helper, gate, label)
    local w = body(main, decl)
    if not w then fail(label .. " forge builder " .. decl .. " not found") end
    local n = count(w, "runtime_secret_volume(") + count(w, "runtime_secret_bind(")
    if n ~= 1 then
        fail(("%s forge builder has %d runtime-secret token mounts, expected exactly 1"):format(label, n))
    end
    if w:find("--secret", 1, true) or w:find(".secret(", 1, true) then
        fail(label .. " forge builder is back on a podman secret, which is plaintext on durable disk")
    end
    if w:find("/run/secrets/", 1, true) then
        fail(label .. " forge builder hand-writes a /run/secrets bind instead of the tmpfs runtime-secret helper")
    end
    if not w:find(gate, 1, true) then fail(label .. " forge token mount is no longer gated on " .. gate) end
    if not w:find(helper .. "(secret_name, GIT_VAULT_TOKEN_SECRET_OPTS)", 1, true) then
        fail(label .. " forge token dropped the scoped vault-token mount opts")
    end
    out.line("ok: " .. label .. " forge builder mounts exactly one gated scoped vault-token tmpfs file")
    verdict.emit("ok:runtime-secret-mounts:" .. which, 0)
end

if which == "forge-opencode" then
    forge("fn build_opencode_forge_args(", "runtime_secret_volume",
        "if let Some(secret_name) = opencode_vault_secret", "opencode")
elseif which == "forge-agent" then
    forge("fn build_forge_agent_run_args_with_vault(", "runtime_secret_bind",
        "if mode_provider_pair(mode).is_some()", "agent")
elseif which == "proxy" then
    local p = body(main, "fn build_proxy_run_args(")
    if not p then fail("build_proxy_run_args not found") end
    local joined = p:gsub("%s", "")
    if not joined:find("runtime_secret_volume(PROXY_CA_KEY_SECRET,PROXY_CA_KEY_SECRET_OPTS", 1, true) then
        fail("the proxy CA key is not delivered as the tmpfs runtime secret file")
    end
    if p:find("intermediate.key", 1, true) then
        fail("the proxy builder binds intermediate.key from the durable CA dir")
    end
    if p:find("--secret", 1, true) or joined:find("{PROXY_CA_KEY_SECRET},{", 1, true) then
        fail("the proxy CA key is back on a podman secret, plaintext on durable disk")
    end
    out.line("ok: tmpfs-file delivery from the 0700 secrets dir, no durable key bind")
    verdict.emit("ok:runtime-secret-mounts:proxy", 0)
end
log.raw("usage: check-runtime-secret-mounts.lua -- forge-opencode|forge-agent|proxy")
verdict.emit("could-not-run:runtime-secret-mounts:usage", 2)

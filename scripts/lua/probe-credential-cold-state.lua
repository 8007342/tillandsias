-- @trace order:900-z3kv, order:1149-vgn2, order:792-ksr8, order:2353-ccsd
-- @env PATH HOME XDG_CACHE_HOME
--
-- probe-credential-cold-state.lua — is this host's clean room CREDENTIAL-COLD or
-- CREDENTIAL-WARM? Ported from probe-credential-cold-state.sh (2353-ccsd), which
-- could only ask the Secret Service over D-Bus and so answered
-- could-not-run:no-busctl on every Mac (v56.11.24.1 macOS smoke, finding 4).
--
-- THE DEFECT THIS SERVES. A host reset empties the runtime store but not the HOST
-- KEYCHAIN, so Vault recovers a pre-existing Shamir share and the keychain/volume
-- resync path is never exercised. Every Linux "clean room" since 2026-06 reused a
-- months-old share while the runbook said otherwise (900-z3kv). The probe lets a
-- run say which state it started in.
--
-- METADATA ONLY, NEVER THE SECRET.
--   linux   Label/Created/Modified/Locked over the Secret Service D-Bus API; never
--           `secret-tool search --all`, which prints the secret inline (two
--           transcripts, 2026-08-25).
--   darwin  `security find-generic-password -s <service> -a <account>` WITHOUT -g or
--           -w: it prints the item's attributes (names and dates) and never the
--           password. Exit 44 is "no such item".
-- The schema is the keyring crate's: Entry::new(KEYCHAIN_SERVICE,
-- VAULT_SHAMIR_SHARE_V1) in vault_bootstrap.rs is service=tillandsias,
-- username/account=vault-shamir-share-v1. A wrong query and an absent secret look
-- identical from outside, so the pair is pinned here and checked against its
-- source by the fixture.
--
-- THE KEYCHAIN IS NOT THE ONLY PLACE A SHARE LIVES (1149-vgn2): a
-- fallback_vault-shamir-share-v1 under the cache root keeps a host warm with an
-- empty keychain. Existence only, never contents. The cache root is
-- ${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias on every platform (core cache_root).
--
-- ADVISORY, NOT A GATE. Exit 0 for cold and warm. Exit 3 (the house could-not-run
-- code; the .sh used 2) when the question could not be ASKED, which is NEVER cold.
--
-- Usage: tillandsias-plan script run scripts/lua/probe-credential-cold-state.lua [-- --format=line|md]
-- Verdict: ok:credential-state:cold (...) | ok:credential-state:warm (...)
--        | could-not-run:credential-state:<why> (... NOT a cold verdict) (exit 3)

local SH = require("common.fixture").posix_shell()
local KEYCHAIN_SERVICE = "tillandsias"
local SHARE_ATTR = "vault-shamir-share-v1"

local FORMAT = "line"
for _, a in ipairs(arg or {}) do
    if a == "--format=line" or a == "--format=md" then FORMAT = a:sub(10)
    else verdict.emit("refused:credential-state:unknown-argument:" .. a, 1) end
end

-- The runner hands a child only a base env: the cache root's inputs are passed on
-- explicitly, or the fallback check would look under the wrong root and say cold.
local CHILD_ENV = {}
for _, k in ipairs{ "HOME", "XDG_CACHE_HOME" } do
    local v = env.get(k)
    if v and v ~= "" then CHILD_ENV[k] = v end
end
local function sh(script, ...)
    local r = proc.run{ argv = { SH, "-s", "--", ... }, stdin = script, env = CHILD_ENV, timeout_ms = 30000 }
    return r.code, r.stdout or "", r.stderr or ""
end
local function has(tool)
    return (sh('command -v -- "$1" >/dev/null 2>&1', tool)) == 0
end
local function could_not_run(why, detail)
    verdict.emit("could-not-run:credential-state:" .. why .. " (" .. detail .. "; this is NOT a cold verdict)", 3)
end
-- emit(kind, line_text, md_lines): the md block (for a findings file) above the one
-- verdict line, which is last in both formats; exit 0 for cold and warm alike.
local function emit(kind, line_text, md)
    if FORMAT == "md" then
        out.line("## Credential state")
        out.line("")
        out.line("- **verdict**: `credential-" .. kind .. "`")
        for _, l in ipairs(md) do out.line(l) end
        out.line("")
    end
    verdict.emit("ok:credential-state:" .. kind .. " (" .. line_text .. ")", 0)
end

-- The fallback share, existence only. fs is repo-scoped, so ask the shell.
local _, fb = sh([[
d="${XDG_CACHE_HOME:-$HOME/.cache}/tillandsias"
for f in "$d/fallback_$1" "$d/fallback_$1".*; do
  [ -e "$f" ] || continue
  m="$(date -u -r "$f" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  printf '%s\t%s\n' "$f" "$m"; exit 0
done]], SHARE_ATTR)
local fb_path, fb_mtime = fb:match("^([^\t\n]+)\t([^\n]*)")

local function warm_from_fallback_or_cold(where)
    if fb_path then
        emit("warm", "no " .. where .. " entry, but fallback share present at " .. fb_path .. ", modified " .. fb_mtime
            .. "; the resync path was NOT exercised by this run — 900-z3kv/1149-vgn2", {
            "- no " .. where .. " entry, but a FALLBACK share is present: `" .. fb_path .. "` (modified " .. fb_mtime .. ")",
            "- vault recovers from the fallback, so `--init` will NOT re-initialize and the resync path is **not** exercised (900-z3kv, 1149-vgn2)" })
    end
    emit("cold", "no " .. SHARE_ATTR .. " in the " .. where .. " and no fallback share on disk; --init will re-initialize and the resync path IS exercised", {
        "- no `" .. SHARE_ATTR .. "` entry for service `" .. KEYCHAIN_SERVICE .. "` in the " .. where .. ", and no fallback share on disk",
        "- the clean room genuinely starts without an unseal share; `--init` will re-initialize Vault and the keychain-volume resync path IS exercised" })
end

local _, uname = sh("uname -s")
uname = text.trim(uname)

-- ── DARWIN: the login Keychain, attributes only ────────────────────────────
if uname == "Darwin" then
    if not has("security") then could_not_run("no-security", "the macOS Keychain could not be queried") end
    -- NO -g, NO -w: those print the password. Without them `security` prints the
    -- item's attribute block (svce, acct, cdat, mdat) and nothing secret.
    local rc, o = sh('security find-generic-password -s "$1" -a "$2" 2>/dev/null', KEYCHAIN_SERVICE, SHARE_ATTR)
    if rc == 44 then warm_from_fallback_or_cold("macOS Keychain") end
    if rc ~= 0 then could_not_run("keychain-query-failed", "security exited " .. tostring(rc)) end
    local function date_attr(tag)
        local d = o:match('"' .. tag .. '"<timedate>=[^"]*"(%d%d%d%d%d%d%d%d%d%d%d%d%d%d)Z')
        if not d then return "unknown" end
        return d:sub(1, 4) .. "-" .. d:sub(5, 6) .. "-" .. d:sub(7, 8) .. "T" .. d:sub(9, 10) .. ":" .. d:sub(11, 12) .. ":" .. d:sub(13, 14) .. "Z"
    end
    local created, modified = date_attr("cdat"), date_attr("mdat")
    emit("warm", "share present in the macOS Keychain, created=" .. created .. " modified=" .. modified
        .. "; the resync path was NOT exercised by this run — 900-z3kv", {
        "- `" .. SHARE_ATTR .. "` PRESENT in the macOS Keychain (service `" .. KEYCHAIN_SERVICE .. "`)",
        "- created `" .. created .. "`, modified `" .. modified .. "`",
        "- a reset that does not reach the Keychain leaves this share for Vault to recover. **The keychain-volume resync path was NOT exercised by this run** (900-z3kv).",
        "- attributes only (`security` without -g/-w); the secret was never read." })
end

-- ── LINUX: the Secret Service over D-Bus ───────────────────────────────────
if not has("busctl") then could_not_run("no-busctl", "the host keychain could not be queried") end
-- CAPTURE BEFORE MATCHING (792-ksr8): a `| grep -q` here SIGPIPEd busctl and two
-- runs seconds apart disagreed. The whole listing is read, then searched.
local _, list = sh("busctl --user list 2>/dev/null || true")
if not ("\n" .. list):find("org.freedesktop.secrets", 1, true) then
    could_not_run("no-secret-service", "org.freedesktop.secrets is not on the user bus")
end
local _, search = sh([[busctl --user call org.freedesktop.secrets /org/freedesktop/secrets \
  org.freedesktop.Secret.Service SearchItems 'a{ss}' 2 service "$1" username "$2" 2>/dev/null || true]], KEYCHAIN_SERVICE, SHARE_ATTR)
if text.trim(search) == "" then could_not_run("search-failed", "SearchItems returned nothing at all") end
-- Reply shape `aoao <n> [paths] <n> [paths]`; a locked item still PROVES PRESENCE.
local item = search:match('"(/org/freedesktop/secrets/[^"]+)"')
if not item then warm_from_fallback_or_cold("host keychain") end

local function prop(name)
    local _, o = sh('busctl --user get-property org.freedesktop.secrets "$1" org.freedesktop.Secret.Item "$2" 2>/dev/null || true', item, name)
    return (o:match("^%S+%s+(%S+)") or ""):gsub('"', "")
end
-- Epoch to ISO: GNU `-d @` first (GNU -r means --reference), BSD `-r` second, each
-- validated by SHAPE, since BSD date "succeeds" with garbage; a miss stays epoch.
local function iso(e)
    if e == "" then return "unknown" end
    local _, o = sh([[d="$(date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
case "$d" in [0-9][0-9][0-9][0-9]-*) printf '%s' "$d"; exit 0 ;; esac
d="$(date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
case "$d" in [0-9][0-9][0-9][0-9]-*) printf '%s' "$d"; exit 0 ;; esac
printf 'epoch:%s' "$1"]], e)
    return o
end
local created, modified, locked = iso(prop("Created")), iso(prop("Modified")), prop("Locked")
emit("warm", "share present, created=" .. created .. " modified=" .. modified .. " locked=" .. locked
    .. "; the resync path was NOT exercised by this run — 900-z3kv", {
    "- `" .. SHARE_ATTR .. "` PRESENT in the host keychain (service `" .. KEYCHAIN_SERVICE .. "`)",
    "- created `" .. created .. "`, modified `" .. modified .. "`, locked `" .. locked .. "`",
    "- `podman system reset --force` does not reach the host keychain, so Vault recovered this pre-existing share. **The keychain-volume resync path was NOT exercised by this run** (900-z3kv).",
    "- metadata only; the secret was never read." })

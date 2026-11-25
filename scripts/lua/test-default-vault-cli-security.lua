-- @env PATH
-- @trace order:799-tb7q, order:851-28b5, order:2368-efqj, spec:tillandsias-vault
--
-- test-default-vault-cli-security.lua — the default image's Vault shim keeps the token out
-- of curl's argv and output, sends bodies on stdin, fails closed with no CA, and agrees
-- with the git-mirror shim (the shared-semantics oracle) on read, write and write-stdin.
-- curl is a stub that checks every request. Ported from the .sh (2368-efqj).
--
-- Verdict: ok:default-vault-cli-security:<n> arms | violation:default-vault-cli-security:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("default-vault-cli-security")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local DEFAULT, GIT = ROOT .. "/images/default/vault-cli.sh", ROOT .. "/images/git/vault-cli.sh"
for _, p in ipairs{ "images/default/vault-cli.sh", "images/git/vault-cli.sh" } do if not fs.exists(p) then T:refuse("no-subject", p) end end
local W = T:scratch()
fs.mkdir(W.rel .. "/bin")
local FAKE = "token-that-must-never-enter-curl-argv"
fs.write(W.rel .. "/ca.crt", "fixture-ca\n")
fs.write(W.rel .. "/vault-token", FAKE .. "\n")
fs.write(W.rel .. "/want-header", "X-Vault-Token: " .. FAKE .. "\n")
-- The stub logs argv, refuses a request whose CA, header file or body shape is wrong, and
-- compares the header file with the expected bytes. stat: GNU first, BSD second.
fs.write(W.rel .. "/bin/curl", [==[#!/usr/bin/env bash
set -euo pipefail
url= cacert= header_arg= data_binary=
log="$CAPTURE_DIR/curl.argv"
while (($#)); do
    case "$1" in
        --cacert) cacert="${2:-}"; printf '%s\n%s\n' "$1" "$cacert" >>"$log"; shift 2 ;;
        --header) header_arg="${2:-}"; printf '%s\n%s\n' "$1" "$header_arg" >>"$log"; shift 2 ;;
        --data-binary) data_binary="${2:-}"; printf '%s\n%s\n' "$1" "$data_binary" >>"$log"; shift 2 ;;
        -*) printf '%s\n' "$1" >>"$log"; shift ;;
        *) url="$1"; printf '%s\n' "$1" >>"$log"; shift ;;
    esac
done
case "$url" in
    */v1/secret/data/shared-read) label=read ;;
    */v1/secret/data/shared-write) label=write ;;
    */v1/secret/data/shared-stdin) label=write-stdin ;;
    */v1/sys/health*) label=health ;;
    *) exit 66 ;;
esac
[[ "$cacert" == "$EXPECTED_CACERT" ]] || exit 67
if [[ "$label" == health ]]; then
    [[ -z "$header_arg" ]] || exit 68
else
    [[ "$header_arg" == @* ]] || exit 69
    header_file="${header_arg#@}"
    [[ -r "$header_file" ]] || exit 70
    [[ "$(stat -c '%a' "$header_file" 2>/dev/null || stat -f '%Lp' "$header_file")" == 600 ]] || exit 71
    cmp -s "$header_file" "$EXPECTED_HEADER" || exit 72
    printf 'ok\n' >>"$CAPTURE_DIR/header-checks"
fi
case "$label" in
    read) [[ -z "$data_binary" ]] || exit 73; printf '{"data":{"data":{"token":"shared-read-result"}}}\n' ;;
    write|write-stdin) [[ "$data_binary" == @- ]] || exit 74; cat >"$CAPTURE_DIR/$label.body"; printf '{"data":{"version":1}}\n' ;;
    health) printf '{"initialized":true,"sealed":false}\n' ;;
esac
]==])
T:must{ "chmod", "755", W.abs .. "/bin/curl" }

-- Run a shim with the stub on PATH; its outputs are kept under <cap>/.
local function vault(cli, cap, e, stdin, ...)
    fs.mkdir(W.rel .. "/" .. cap)
    for _, n in ipairs{ "curl.argv", "header-checks" } do
        if not fs.exists(W.rel .. "/" .. cap .. "/" .. n) then fs.write(W.rel .. "/" .. cap .. "/" .. n, "") end
    end
    local envs = { PATH = W.abs .. "/bin:" .. env.get("PATH"), CAPTURE_DIR = W.abs .. "/" .. cap, EXPECTED_CACERT = W.abs .. "/ca.crt", EXPECTED_HEADER = W.abs .. "/want-header",
        VAULT_ADDR = "https://vault.fixture.invalid:8200", VAULT_CACERT = W.abs .. "/ca.crt", VAULT_TOKEN_FILE = W.abs .. "/vault-token" }
    for k, v in pairs(e or {}) do envs[k] = v or nil end
    local argv = { SH, cli }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    argv.env, argv.env_unset, argv.stdin, argv.cwd = envs, { "TILLANDSIAS_*", "VAULT_*", "CURL_CA_BUNDLE" }, stdin or "", W.abs
    local r = T:run(argv)
    return { rc = r.code, out = r.stdout or "", err = r.stderr or "" }
end
local function got(r) return "rc=" .. tostring(r.rc) .. " " .. r.out:sub(1, 200) .. " " .. r.err:sub(1, 300) end
local function cap(dir, n) local p = W.rel .. "/" .. dir .. "/" .. n; return fs.exists(p) and fs.read(p) or "absent" end

local r = vault(DEFAULT, "missing-ca", { VAULT_CACERT = W.abs .. "/not-present.crt" }, nil, "read", "secret/shared-read")
T:arm("an unreadable CA fails closed (rc 2, named) before curl runs", r.rc == 2 and (r.out .. r.err):find("CA bundle not readable", 1, true) and cap("missing-ca", "curl.argv") == "", got(r))

-- Both production CA shapes, with no override: provider-login's mount, then the runtime bundle.
fs.write(W.rel .. "/login-ca.crt", "login-ca\n"); fs.write(W.rel .. "/runtime-ca.crt", "runtime-ca\n")
for _, s in ipairs{ { "login", "login-ca.crt", "login-ca.crt" }, { "resident", "missing-login-ca.crt", "runtime-ca.crt" } } do
    r = vault(DEFAULT, "shape-" .. s[1], { VAULT_CACERT = false, EXPECTED_CACERT = W.abs .. "/" .. s[3], TILLANDSIAS_VAULT_LOGIN_CACERT = W.abs .. "/" .. s[2],
        TILLANDSIAS_VAULT_RUNTIME_CACERT = W.abs .. "/runtime-ca.crt" }, nil, "read", "-field=token", "secret/shared-read")
    T:arm("the " .. s[1] .. " shape picks its CA with no override", r.rc == 0 and text.trim(r.out) == "shared-read-result", got(r))
end
for _, verb in ipairs{ "renew-self", "lookup-self", "revoke-self" } do
    r = vault(DEFAULT, "verbs", nil, nil, verb)
    T:arm(verb .. " stays the git mirror's, not the default shim's", r.rc == 4 and (r.out .. r.err):find("unknown subcommand", 1, true), got(r))
end

local all = { default = {}, git = {} }
for name, cli in pairs{ default = DEFAULT, git = GIT } do
    local a = all[name]
    a.read = vault(cli, name, nil, nil, "read", "-field=token", "secret/shared-read")
    a.write = vault(cli, name, nil, nil, "write", "secret/shared-write", "username=alice", "password=opaque write value")
    a.stdin = vault(cli, name, nil, "opaque stdin value", "write-stdin", "secret/shared-stdin", "credentials_b64")
    T:arm("the " .. name .. " shim reads, writes and writes stdin", a.read.rc == 0 and a.write.rc == 0 and a.stdin.rc == 0, got(a.read) .. " / " .. got(a.write) .. " / " .. got(a.stdin))
end
local d, g = all.default, all.git
T:arm("the two shims agree on outputs and bodies", d.read.out == g.read.out and d.write.out == g.write.out and d.stdin.out == g.stdin.out
    and cap("default", "write.body") == cap("git", "write.body") and cap("default", "write-stdin.body") == cap("git", "write-stdin.body"), cap("default", "write.body") .. " / " .. cap("git", "write.body"))
T:arm("read -field prints the field", text.trim(d.read.out) == "shared-read-result", d.read.out)
local function body(n) local ok, v = pcall(json.parse, cap("default", n)); return ok and type(v) == "table" and v.data or {} end
T:arm("write sends its KV-v2 body on stdin", body("write.body").username == "alice" and body("write.body").password == "opaque write value", cap("default", "write.body"))
T:arm("write-stdin sends its opaque value in the body", body("write-stdin.body").credentials_b64 == "opaque stdin value", cap("default", "write-stdin.body"))
T:arm("every authenticated request used the 0600 header file", cap("default", "header-checks") == "ok\nok\nok\n", cap("default", "header-checks"))
local argvlog = cap("default", "curl.argv")
T:arm("curl is passed --cacert", ("\n" .. argvlog):find("\n--cacert\n", 1, true), argvlog)
local seen = argvlog
for _, x in pairs(d) do seen = seen .. x.out .. x.err end
T:arm("the token reaches neither curl's argv nor any output", not seen:find(FAKE, 1, true), "leaked")
T:arm("no body reaches curl's argv", not argvlog:find("opaque stdin value", 1, true) and not argvlog:find("opaque write value", 1, true), argvlog)
r = vault(DEFAULT, "default", nil, nil, "health")
T:arm("health answers with no token header", r.rc == 0, got(r))
T:finish()

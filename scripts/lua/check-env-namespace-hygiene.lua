-- @trace order:2031-z4rm, spec:command-runtime
-- @env TILLANDSIAS_ENV_HYGIENE_SCAN_ROOT
--
-- check-env-namespace-hygiene.lua — a TILLANDSIAS_ name is spelled like a
-- credential only if it IS one.
--
-- WHY. Every Lua door child gets the runner's TILLANDSIAS_* variables minus the
-- credential-shaped ones (2031-h5ru, enforced; the full hard block of 2031-dwwy,
-- crates/tillandsias-plan/src/child_env.rs, design 2029-39bt §4.10). That filter is
-- safe only while the namespace keeps two promises, and this guard holds the
-- tree to both:
--   * a real secret is spelled so the filter catches it, and is listed in
--     CREDENTIAL_NAMES below (it is then dropped on purpose);
--   * a non-secret is NOT spelled like a credential, or the filter silently
--     drops a variable children need. TILLANDSIAS_WRAPPER_TOKEN, the process
--     reaper's marker, was exactly that and was renamed
--     TILLANDSIAS_WRAPPER_MARK; TILLANDSIAS_NOTARY_KEY, a path, became
--     TILLANDSIAS_NOTARY_KEY_FILE (both 2031-z4rm).
--
-- THE SHAPE (design 2029-39bt §4.2, class A2, applied to the namespace) is the
-- one in crates/tillandsias-plan/src/child_env.rs::credential_shape (2031-dwwy):
-- a name is credential-shaped when its last _-segment is TOKEN, SECRET,
-- PASSWORD, PASSWD, PASSPHRASE, PASS, KEY, AUTH, CREDENTIALS, CREDENTIAL,
-- COOKIE or SESSION, or it contains TOKEN, SECRET, PASSWORD, PASSWD,
-- PASSPHRASE, API_KEY, ACCESS_KEY, PRIVATE_KEY, SECRET_KEY, SIGNING_KEY,
-- CLIENT_SECRET or CREDENTIAL — UNLESS its last segment is a locator (FILE PATH
-- DIR ID NAME FP LOG URL ADDR SRC COUNT; ENV_FILE and SINK_FILE end in FILE),
-- which names WHERE a credential is, not the credential. Case-insensitive. The
-- Rust rule's prefix and exact-name arms (AWS_, GH_TOKEN, ...) cannot match a
-- TILLANDSIAS_ name, so they are not repeated here.
-- tests/lua_source_agreements.rs::rust_and_lua_credential_shapes_agree runs
-- THIS guard over every TILLANDSIAS_ name in the tree plus one probe per rule
-- and holds its refusals equal to the Rust rule's.
--
-- Scans code, not prose: build.sh, and *.sh *.lua *.rs files under scripts/,
-- crates/ and images/. plan/, openspec/ and cheatsheets are prose and may name
-- any variable. TILLANDSIAS_ENV_HYGIENE_SCAN_ROOT points the scan at another
-- root (the fixture's scratch trees); unset, it is the checkout.
--
-- Verdicts:
--   ok:env-namespace-hygiene:names=<n>:credentials=<k>:retired=<r>      exit 0
--   violation:env-namespace:credential-shape:<NAME>:<file>              exit 1
--   could-not-run:env-namespace-hygiene:empty-population                exit 3

-- Real secrets. Spelled like credentials on purpose, so the door drops them.
local CREDENTIAL_NAMES = {
    TILLANDSIAS_COORD_CLIENT_SECRET = "coordinator Access client secret (coordinator_client)",
    TILLANDSIAS_KEY_PASS = "at-rest CA key passphrase (ca_key_store::PASS_ENV)",
    TILLANDSIAS_CONSENT_TOKEN = "one-shot consent authorisation; must not propagate",
    TILLANDSIAS_BROWSER_E2E_FOREIGN_KEY = "PEM private key of the browser e2e probe's foreign leaf",
    TILLANDSIAS_BROWSER_E2E_ENCLAVE_KEY = "PEM private key of the browser e2e probe's enclave leaf",
}
-- Old spellings still READ (never written) for one transition window, so a
-- process started from an older checkout keeps working. Each names its
-- replacement; delete the entry when the old name is gone from the tree.
local RETIRED_NAMES = {
    TILLANDSIAS_WRAPPER_TOKEN = "TILLANDSIAS_WRAPPER_MARK",
    TILLANDSIAS_NOTARY_KEY = "TILLANDSIAS_NOTARY_KEY_FILE",
}
-- The fixture plants a credential-shaped name in a scratch tree, so its own
-- source carries one. Skipped by exact path, never by pattern.
local SELF_TEST = "scripts/lua/test-env-namespace-hygiene.lua"

local TERMINAL = { TOKEN = true, SECRET = true, PASSWORD = true, PASSWD = true, PASSPHRASE = true,
                   PASS = true, KEY = true, AUTH = true, CREDENTIALS = true, CREDENTIAL = true,
                   COOKIE = true, SESSION = true }
local CONTAINS = { "TOKEN", "SECRET", "PASSWORD", "PASSWD", "PASSPHRASE", "API_KEY", "ACCESS_KEY",
                   "PRIVATE_KEY", "SECRET_KEY", "SIGNING_KEY", "CLIENT_SECRET", "CREDENTIAL" }
local LOCATOR = { FILE = true, PATH = true, DIR = true, ID = true, NAME = true, FP = true,
                  LOG = true, URL = true, ADDR = true, SRC = true, COUNT = true }

local function credential_shaped(name)
    local up = name:upper()
    local last = up:match("_([A-Z0-9]+)$") or up
    if LOCATOR[last] then return false end
    if TERMINAL[last] then return true end
    for _, c in ipairs(CONTAINS) do
        if up:find(c, 1, true) then return true end
    end
    return false
end

local root = env.get("TILLANDSIAS_ENV_HYGIENE_SCAN_ROOT") or ""
local function at(p) return (root ~= "" and (root .. "/" .. p)) or p end

local files = {}
if fs.exists(at("build.sh")) then files[#files + 1] = at("build.sh") end
for _, dir in ipairs({ "scripts", "crates", "images" }) do
    if fs.exists(at(dir)) then
        for _, f in ipairs(fs.walk(at(dir))) do
            if (f:match("%.sh$") or f:match("%.lua$") or f:match("%.rs$"))
                and not f:find("/target/", 1, true) then
                files[#files + 1] = f
            end
        end
    end
end
table.sort(files)
if #files == 0 then
    verdict.emit("could-not-run:env-namespace-hygiene:empty-population", 3)
end

local seen, first_file, names = {}, {}, 0
for _, f in ipairs(files) do
    local rel = (root ~= "" and f:sub(#root + 2)) or f
    if rel ~= SELF_TEST then
        local body = fs.read(f) or ""
        for name in body:gmatch("TILLANDSIAS_[A-Z0-9_]*[A-Z0-9]") do
            if not seen[name] then
                seen[name] = true
                first_file[name] = rel
                names = names + 1
            end
        end
    end
end

local bad, credentials, retired = {}, 0, 0
local sorted = {}
for name in pairs(seen) do sorted[#sorted + 1] = name end
table.sort(sorted)
for _, name in ipairs(sorted) do
    if credential_shaped(name) then
        if CREDENTIAL_NAMES[name] then
            credentials = credentials + 1
        elseif RETIRED_NAMES[name] then
            retired = retired + 1
        else
            bad[#bad + 1] = name
        end
    end
end

if #bad > 0 then
    for i = 1, #bad - 1 do
        out.line("violation:env-namespace:credential-shape:" .. bad[i] .. ":" .. first_file[bad[i]])
    end
    log.raw("  why: a TILLANDSIAS_ name spelled like a credential is dropped from every Lua door child (2031-h5ru/2031-dwwy)")
    log.raw("  remedy: if it holds a secret, add it to CREDENTIAL_NAMES in scripts/lua/check-env-namespace-hygiene.lua;")
    log.raw("          if it does not, rename it (a path ends _FILE/_PATH/_DIR; an id ends _ID; a marker ends _MARK)")
    local last = bad[#bad]
    verdict.emit("violation:env-namespace:credential-shape:" .. last .. ":" .. first_file[last], 1)
end

verdict.emit(("ok:env-namespace-hygiene:names=%d:credentials=%d:retired=%d"):format(names, credentials, retired), 0)

-- @trace order:1384-ddua, order:1538-pwdr, order:1611-imnj, order:2375-psb9
-- @env PATH HOME TMPDIR TILLANDSIAS_PILOT_PARENT
--
-- test-pilot-lua-ports.lua — the first two deciders ported to scripts/lua on the one runner
-- (1384-bqhy), each .sh deleted, and each incident class shown UNREPRESENTABLE by a negative
-- arm. Ported from test-pilot-lua-ports.sh (2375-psb9); same five arms.
--
--   1 SEAM     check-seam-writers-canonical.lua prints the byte-identical verdict (and rc)
--              the .sh printed at the pinned parent, and ok:seam-writers-canonical:3 with
--              `set -o pipefail` in the caller and a 200,000-line writer file (the two
--              conditions under which the .sh inverted)
--   2 DIALECT  ONE bash-4 builtin line is ONE offender (blocked:bash4-unguarded:1, 1374-4u6i's
--              double count), and an empty population is refused (scan-empty), never clean
--   3 SANDBOX  a script reading a path from an env var it did NOT declare with `-- @read-env`
--              is refused; the same read with the declaration succeeds
--   4 STALE    a plan binary without `script run` makes build.sh's _run_lua_decider a loud
--              could-not-run (rc 3, why+remedy), never a pass
--   5 DELETED  both .sh existed at the pinned baseline and are gone, both .lua present
--              (no count: a count moved with every unrelated .sh added or retired)
--
-- The baseline is a FIXED historical commit (5c419a98f, land118's first parent, the last
-- trunk commit carrying both .sh), never a moving ref: a moving default failed ARM 1 and 5
-- by construction once the port landed. Override with TILLANDSIAS_PILOT_PARENT.
--
-- GRAMMAR ok:pilot-lua-ports:<n> arms | violation:pilot-lua-ports:<n>-failed
--       | could-not-run:pilot-lua-ports:no-script-runner (rc 3)

local fixture = require "common.fixture"
local V = require "common.verdict"
local T = fixture.new("pilot-lua-ports")
local ROOT, SH = fixture.repo_root(), fixture.posix_shell()

local PLAN = fixture.plan_binary()
if PLAN ~= "" and not fixture.is_abs(PLAN) then PLAN = ROOT .. "/" .. PLAN:gsub("^%./", "") end
local caps = PLAN ~= "" and (T:run{ PLAN, "capabilities", cwd = ROOT, timeout_ms = 30000 }.stdout or "") or ""
local has_script = false
for _, l in ipairs(text.lines(caps)) do if l == "script" then has_script = true end end
if not has_script then
    out.line("build it: cargo build --release -p tillandsias-plan")
    V.emit("could-not-run:pilot-lua-ports:no-script-runner", 3)
end
local PARENT = env.get("TILLANDSIAS_PILOT_PARENT") or ""
if PARENT == "" then PARENT = "5c419a98fd245bbeee63f2cf9c70956cbd5e22c9" end
local W = T:scratch()
local function both(r) return (r.stdout or "") .. (r.stderr or "") end
local function chomp(s) return ((s or ""):gsub("\n+$", "")) end

-- ── ARM 1: SEAM ─────────────────────────────────────────────────────────────
local a1_why = ""
local SEAM_SH = "scripts/check-seam-writers-canonical.sh"
if T:run{ "git", "cat-file", "-e", PARENT .. ":" .. SEAM_SH, cwd = ROOT }.code == 0 then
    local show = T:must{ "git", "show", PARENT .. ":" .. SEAM_SH, cwd = ROOT }
    fs.write(W.rel .. "/seam-parent.sh", show.stdout)
    local s = T:run{ SH, W.abs .. "/seam-parent.sh", cwd = ROOT }
    local l = T:run{ PLAN, "script", "run", "scripts/lua/check-seam-writers-canonical.lua", cwd = ROOT }
    local sh_out, lua_out = chomp(both(s)), chomp(l.stdout)
    if not (sh_out == lua_out and s.code == l.code) then
        a1_why = "live tree: sh(" .. tostring(s.code) .. ")=[" .. sh_out .. "] lua(" .. tostring(l.code) .. ")=[" .. lua_out .. "];"
    end
else
    a1_why = "parent " .. PARENT .. " has no .sh to compare against (already landed?);"
end
fs.mkdir(W.rel .. "/crate/src")
local WRITER = 'fn f(){ podman_seam_lock(); unsafe { std::env::set_var("TILLANDSIAS_PODMAN_BIN", "x") }; }\n'
fs.write(W.rel .. "/crate/src/w1.rs", WRITER)
fs.write(W.rel .. "/crate/src/w2.rs", WRITER)
local big = { (WRITER:gsub("fn f%(%)", "fn big()")) }
for i = 0, 199999 do big[#big + 1] = "// filler line " .. i .. "\n" end
fs.write(W.rel .. "/crate/src/big.rs", table.concat(big))
local p = T:run{ SH, "-o", "pipefail", "-s", "--", PLAN, "scripts/lua/check-seam-writers-canonical.lua",
    W.abs .. "/crate/src", cwd = ROOT, stdin = '"$1" script run "$2" "$3"\n' }
local p_out = chomp(p.stdout)
if not (p.code == 0 and p_out == "ok:seam-writers-canonical:3") then
    a1_why = a1_why .. " pipefail+200k: rc=" .. tostring(p.code) .. " out=[" .. p_out .. "];"
end
T:arm("ARM 1: seam-writers verdict byte-identical to the parent .sh, and ok:seam-writers-canonical:3 under pipefail with a 200,000-line writer",
    a1_why == "", a1_why)

-- ── ARM 2: DIALECT ──────────────────────────────────────────────────────────
fs.mkdir(W.rel .. "/d1"); fs.mkdir(W.rel .. "/d0")
fs.write(W.rel .. "/d1/one.sh", "#!/usr/bin/env bash\nmapfile -t lines < /etc/hostname\n")
local function dialect(dir)
    local r = T:run{ PLAN, "script", "run", "scripts/lua/check-bash-dialect.lua", cwd = ROOT,
        env_unset = { "TILLANDSIAS_*" }, env = { TILLANDSIAS_DIALECT_SCAN_DIR = dir } }
    return chomp(r.stdout), r.code
end
local o2, r2 = dialect(W.abs .. "/d1")
local o0, r0 = dialect(W.abs .. "/d0")
T:arm("ARM 2: one bash-4 builtin line is ONE offender (blocked:bash4-unguarded:1), and an empty population is refused (scan-empty), never clean",
    o2 == "blocked:bash4-unguarded:1" and r2 == 1 and o0 == "blocked:bash-dialect:scan-empty" and r0 ~= 0,
    "one-builtin=[" .. o2 .. "] rc=" .. tostring(r2) .. "; empty=[" .. o0 .. "] rc=" .. tostring(r0))

-- ── ARM 3: SANDBOX — only a DECLARED env var widens reads ───────────────────
local OUT_DIR = text.trim(T:must{ SH, "-s", stdin = 'd="$(mktemp -d "${TMPDIR:-/tmp}/pilot-outside.XXXXXX")" && printf "secret-outside-the-repo\\n" > "$d/f.txt" && printf "%s" "$d"\n',
    env = { TMPDIR = env.get("TMPDIR") } }.stdout or "")
fs.write(W.rel .. "/undeclared.lua", '-- @env PILOT_DIR\nlocal s = fs.read(env.get("PILOT_DIR") .. "/f.txt")\nverdict.ok("read", #s)\n')
fs.write(W.rel .. "/declared.lua", '-- @env PILOT_DIR\n-- @read-env PILOT_DIR\nlocal s = fs.read(env.get("PILOT_DIR") .. "/f.txt")\nverdict.ok("read", #s)\n')
local u = T:run{ PLAN, "script", "run", W.abs .. "/undeclared.lua", cwd = ROOT, env = { PILOT_DIR = OUT_DIR } }
local d = T:run{ PLAN, "script", "run", W.abs .. "/declared.lua", cwd = ROOT, env = { PILOT_DIR = OUT_DIR } }
if OUT_DIR ~= "" then
    T:run{ "rm", "-f", OUT_DIR .. "/f.txt" }; T:run{ "rmdir", OUT_DIR }
end
local u_out, d_out = chomp(u.stdout), chomp(d.stdout)
T:arm("ARM 3: an undeclared env path outside the repo is refused (" .. u_out .. "); the same read under -- @read-env succeeds",
    OUT_DIR ~= "" and u.code ~= 0 and not u_out:find("^ok:") and not u_out:find("\nok:") and d.code == 0 and d_out == "ok:read:24",
    "undeclared rc=" .. tostring(u.code) .. " out=[" .. u_out .. "]; declared rc=" .. tostring(d.code) .. " out=[" .. d_out .. "]")

-- ── ARM 4: STALE BINARY — the gate's Lua decider is could-not-run ───────────
fs.write(W.rel .. "/old-plan", '#!/usr/bin/env bash\ncase "$1" in capabilities) echo check ;; *) echo "unknown subcommand" >&2; exit 2 ;; esac\n')
T:must{ "chmod", "+x", W.abs .. "/old-plan" }
local fn, on = {}, false
for _, l in ipairs(text.lines(fs.read("build.sh"))) do
    if not on and l:find("^_run_lua_decider%(%) {") then on = true end
    if on then
        fn[#fn + 1] = l
        if l:find("^}") then break end
    end
end
local r4 = T:run{ SH, "-s", cwd = ROOT, env = { SCRIPT_DIR = ROOT, TILLANDSIAS_PLAN_BIN = W.abs .. "/old-plan" },
    stdin = '_afford() { printf "  why: %s\\n  remedy: %s\\n" "$1" "$2" >&2; }\n_run() { "$@"; }\n'
        .. table.concat(fn, "\n") .. "\n_run_lua_decider scripts/lua/check-bash-dialect.lua 2>&1\n" }
local o4 = both(r4)
local cnr, okline = false, false
for _, l in ipairs(text.lines(o4)) do
    if l:find("^could%-not%-run:lua%-decider:check%-bash%-dialect%.lua:no%-script%-runner") then cnr = true end
    if l:find("^ok:") then okline = true end
end
T:arm("ARM 4: with a plan binary lacking script run, the gate's Lua decider is a loud could-not-run (rc 3, why+remedy), never a pass",
    #fn > 0 and r4.code == 3 and cnr and text.contains(o4, "remedy:") and not okline,
    "rc=" .. tostring(r4.code) .. " out=[" .. (o4:gsub("\n", "|")) .. "]")

-- ── ARM 5: DELETED ──────────────────────────────────────────────────────────
local a5_why = ""
for _, n in ipairs{ "check-bash-dialect", "check-seam-writers-canonical" } do
    if T:run{ "git", "cat-file", "-e", PARENT .. ":scripts/" .. n .. ".sh", cwd = ROOT }.code ~= 0 then
        a5_why = a5_why .. " " .. n .. ".sh absent at the baseline " .. PARENT .. " (shallow clone, or a wrong pin);"
    end
    if fs.exists("scripts/" .. n .. ".sh") then a5_why = a5_why .. " scripts/" .. n .. ".sh is back;" end
    if not fs.exists("scripts/lua/" .. n .. ".lua") then a5_why = a5_why .. " scripts/lua/" .. n .. ".lua is missing;" end
end
T:arm("ARM 5: both .sh existed at the baseline and are gone, and both .lua are present", a5_why == "", a5_why)

T:finish()

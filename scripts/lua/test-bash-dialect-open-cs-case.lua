-- @trace order:1582-c32p
-- @env TILLANDSIAS_PLAN_BIN TILLANDSIAS_SCRIPT_RUNNER_BIN
--
-- test-bash-dialect-open-cs-case.lua — check-bash-dialect.lua's case-in-$( )
-- rule on the shape bash 3.2 (macOS /bin/bash) misparses: an UNPARENTHESISED
-- case pattern inside a $( ) whose `$(` opened MID-line, lines earlier. bash
-- 3.2 ends the substitution at the pattern's ')', prints a syntax error,
-- returns rc=0, and the variable holds SOURCE TEXT (1582-c32p, measured on
-- the Mac against images/default/lib-ledger-freshness.sh:51-59).
--
-- Each arm is one constructed file, judged alone (TILLANDSIAS_DIALECT_SCAN_DIR
-- names it), in a scratch dir under target/plan-scratch:
--   1 RED   the measured shape: `x="$(git … \` / `| while …; do` /
--           `case "$r" in origin | origin/HEAD) continue ;; esac`
--   2 RED   the single-line form: `$( … case "$l" in a) … esac … )` on one line
--   3 RED   a multi-line `case … in` header and arm inside an open $( )
--   4 GREEN the measured shape with the pattern written `(origin | origin/HEAD)`
--   5 GREEN the same text inside a single-quoted `bash -c '…'` string
--   6 GREEN the same text in comments
--   7 GREEN an escaped `\$\(` in a regex never opens a substitution
--   8 GREEN `case … in a)` text inside a single-quoted awk program within $( )
--
-- Usage: tillandsias-plan script run scripts/lua/test-bash-dialect-open-cs-case.lua [-- --plan <bin>]

local DIALECT_REL = "scripts/lua/check-bash-dialect.lua"
local PLAN
for i = 1, #arg do if arg[i] == "--plan" then PLAN = arg[i + 1] end end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_PLAN_BIN") end
if not PLAN or PLAN == "" then PLAN = env.get("TILLANDSIAS_SCRIPT_RUNNER_BIN") end
if not PLAN or PLAN == "" then
    verdict.could_not_run("bash-dialect-open-cs-case-fixture", "no plan binary named (--plan, TILLANDSIAS_PLAN_BIN or TILLANDSIAS_SCRIPT_RUNNER_BIN)")
end

local function run(argv, opts)
    local spec = { argv = argv, timeout_ms = 120000 }
    for k, v in pairs(opts or {}) do spec[k] = v end
    return proc.run(spec)
end
local ROOT = text.trim(run({ "git", "rev-parse", "--show-toplevel" }).stdout or "")
local REL = "target/plan-scratch/dialect-open-cs-case-" .. time.iso_utc() .. "-" .. tostring(math.random(100000, 999999))
fs.mkdir(REL)

local function judge(name, body)
    local rel = REL .. "/" .. name .. ".sh"
    fs.write(rel, "#!/usr/bin/env bash\n" .. body)
    local r = run({ PLAN, "script", "run", ROOT .. "/" .. DIALECT_REL },
        { cwd = ROOT, env = { TILLANDSIAS_DIALECT_SCAN_DIR = rel } })
    return (r.status == "exited" and r.code or -1), (r.stdout or ""), (r.stderr or ""), rel
end
local passed, failed = {}, {}
local function check(name, cond, why)
    if cond then passed[#passed + 1] = name; out.line("ok:   " .. name)
    else failed[#failed + 1] = name; out.line("FAIL: " .. name .. " — " .. why) end
end
local function red(name, body, line)
    local rc, o, e, rel = judge(name, body)
    check(name, rc == 1 and text.trim(o) == "blocked:bash4-unguarded:1"
        and e:find("UNPARENTHESISED case pattern inside $( )", 1, true) ~= nil
        and e:find("  " .. rel .. ":" .. line .. "\n", 1, true) ~= nil,
        "want blocked naming line " .. line .. "; rc=" .. rc .. " out=[" .. o .. "] err=[" .. e:sub(1, 400) .. "]")
end
local function green(name, body)
    local rc, o, e = judge(name, body)
    check(name, rc == 0 and text.trim(o) == "ok:bash-dialect-clean",
        "want ok:bash-dialect-clean; rc=" .. rc .. " out=[" .. o .. "] err=[" .. e:sub(1, 400) .. "]")
end

local MEASURED = table.concat({
    'f() {',
    '    newest_line="$(git -C "$1" for-each-ref refs/remotes/origin \\',
    "        --format='%(refname:short) %(committerdate:unix)' 2>/dev/null \\",
    '        | while read -r _ref _ts; do',
    '            case "$_ref" in origin | origin/HEAD) continue ;; esac',
    "            printf '%s %s\\n' \"$_ref\" \"$_ts\"",
    '            break',
    '        done)"',
    '}', "" }, "\n")

red("1-RED-measured-shape", MEASURED, 6)
red("2-RED-single-line", 'x="$(printf a | while read -r l; do case "$l" in a) echo y ;; esac; done)"\n', 2)
red("3-RED-multiline-case", table.concat({
    'x="$(printf a \\',
    '    | while read -r l; do',
    '        case "$l" in',
    '            a) echo y ;;',
    '        esac',
    '    done)"', "" }, "\n"), 5)
green("4-GREEN-parenthesised", (MEASURED:gsub("in origin | origin/HEAD%)", "in (origin | origin/HEAD)")))
green("5-GREEN-single-quoted-bash-c", "bash -c '\n" .. MEASURED:gsub("'", "") .. "'\n")
green("6-GREEN-comment", (MEASURED:gsub("([^\n]*)\n", "# %1\n")))
green("7-GREEN-escaped-regex", table.concat({
    '[[ "$s" =~ ^\\$\\( ]] && echo y',
    'case "$s" in a) echo y ;; esac', "" }, "\n"))
green("8-GREEN-awk-program", table.concat({
    'n="$(printf x \\',
    "    | awk '",
    '      { s = "case a in b) c" }',
    "      ')\"", "" }, "\n"))

run({ "rm", "-rf", ROOT .. "/" .. REL })

if #failed > 0 then
    verdict.emit("violation:bash-dialect-open-cs-case-fixture:" .. #failed .. ":of:" .. (#passed + #failed), 1,
        "failed arms: " .. table.concat(failed, "; "))
end
verdict.ok("bash-dialect-open-cs-case-fixture", #passed)

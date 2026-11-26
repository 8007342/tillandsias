-- @env PATH HOME
-- @trace order:761-g36m, order:1055-6yp8, order:1374-4u6i, order:1553-x8js, order:2377-znx4
--
-- test-check-bash-dialect.lua — check-bash-dialect.lua refuses what bash 3.2 or BSD tools cannot
-- run, passes the portable form beside it, and honours a named exemption. Ported from the .sh of the
-- same name (2377-znx4). Each arm is one scratch script; the last group asks this host's sed whether the
-- refused and the passed spellings are what the rules say.
--
-- Usage: tillandsias-plan script run scripts/lua/test-check-bash-dialect.lua
-- Verdict: ok:check-bash-dialect-fixture:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("check-bash-dialect-fixture")
local SH, PLAN, ROOT = fixture.posix_shell(), fixture.plan_binary(), fixture.repo_root()
if PLAN == "" then T:refuse("no-plan-binary") end
local CLEAN = "ok:bash-dialect-clean"
local function check(files, how)
    local d, list = T:scratch(), {}
    for n, b in pairs(files) do
        fs.write(d.rel .. "/" .. n, "#!/usr/bin/env bash\n" .. b)
        list[#list + 1] = d.abs .. "/" .. n
    end
    local e = { PATH = env.get("PATH"), HOME = env.get("HOME") }
    if how == "files" then e.TILLANDSIAS_DIALECT_SCAN_FILES = table.concat(list, "\n") else e.TILLANDSIAS_DIALECT_SCAN_DIR = d.abs end
    local r = proc.run{ argv = { PLAN, "script", "run", "scripts/lua/check-bash-dialect.lua" }, cwd = ROOT, env = e, env_unset = { "TILLANDSIAS_*" }, timeout_ms = 60000 }
    return { rc = r.code, out = text.trim(r.stdout or ""), why = "rc=" .. tostring(r.code) .. " " .. (r.stdout or ""):sub(1, 200) .. (r.stderr or ""):sub(1, 300) }
end
local function refused(name, body)
    local x = check{ ["x.sh"] = body }
    T:arm(name .. " is refused", x.rc == 1 and x.out == "blocked:bash4-unguarded:1", x.why)
end
local function passes(name, body)
    local x = check{ ["x.sh"] = body }
    T:arm(name .. " passes", x.rc == 0 and x.out == CLEAN, x.why)
end
-- COMPOSED, so this file never spells an invocation another guard refuses.
local S, C, A, MF, ST = "s" .. "ed", "ca" .. "se", "a" .. "wk", "map" .. "file", "st" .. "at"
local LOWER = 'x="$1"\nprintf %s "${x,,}"\n'
refused("bash4: an unguarded expansion", LOWER)
passes("bash4: one behind a BASH_VERSINFO guard", 'if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then echo "refused:bash4-required" >&2; exit 3; fi\n' .. LOWER)
passes("bash4: a clean script", "echo ok\n")
refused("bash4: an unguarded builtin", MF .. ' -t arr < "$1"\n')
passes("bash4: the dual marker", "# bash-dialect: dual (probed fallback)\nif TZ=UTC0 printf '%(%s)T' -1 >/dev/null 2>&1; then TZ=UTC0 printf '%(%s)T' -1; else date +%s; fi\n")
passes("bash4: a comment that mentions one", "# never use ${x,,} or " .. MF .. " here\necho ok\n")
refused("date: +%s%3N", 't="$(date +%s%3N)"\necho "$t"\n')
passes("date: the same with its exemption", 't="$(date +%s%3N)" # gnu-date: ok (digit-validated)\necho "$t"\n')
refused("date: -u -d", 't=$(date -u -d "@123" +%s)\necho "$t"\n')
refused("date: -d", "date -d yesterday +%Y\n")
refused("arrays: declare -gA", "declare -gA M=()\n")
passes("arrays: declare -a", "declare -a L=()\necho ok\n")
refused("arrays: local -A", "f() { local -A m=(); m[x]=1; }\nf\n")
passes("arrays: local -r", 'f() { local -r x=1; echo "$x"; }\nf\n')
local HEAD = "set -euo pipefail\nfile_list=()\n"
local FILL = 'if [ -n "${X:-}" ]; then\n    file_list+=("a")\nfi\n'
refused("empty array under set -u", HEAD .. FILL .. 'for file in "${file_list[@]}"; do\n    echo "$file"\ndone\n')
passes("empty array: the + form", HEAD .. FILL .. 'for file in ${file_list[@]+"${file_list[@]}"}; do\n    echo "$file"\ndone\n')
passes("empty array: the exemption", HEAD .. 'file_list+=("a")\nfor file in "${file_list[@]}"; do # maybe-empty: ok (populated above)\n    echo "$file"\ndone\n')
passes("empty array: a count", HEAD .. 'if [ "${#file_list[@]}" -eq 0 ]; then echo none; fi\n')
passes("empty array: without set -u", 'file_list=()\nfor file in "${file_list[@]}"; do\n    echo "$file"\ndone\n')
local RANGE = "'/if \\[ -n \"\\${TILLANDSIAS_SIDECAR_TARGET_DIR/,/^fi/p'"
refused("procsub: sourcing one with a dot", "    . <(" .. S .. " -n " .. RANGE .. ' "$SIDECAR")\n')
refused("procsub: sourcing one by name", "source <(printf X=1)\n")
passes("procsub: the eval form", '    eval "$(' .. S .. " -n " .. RANGE .. ' "$SIDECAR")"\n')
passes("procsub: one not sourced", "diff <(sort a) <(sort b)\nwhile read -r l; do :; done < <(ls)\n")
passes("procsub: the exemption", ". <(printf X=1) # procsub-source: ok (fixture)\n")
refused("awk -v of many lines, piped (88tp)", "_pt_digests=\"$(tr '\\n' '\\0' <<<\"$_pt_files\" | xargs -0 sha256sum 2>/dev/null || true)\"\n{ printf '%s' \"$_PER_TEST_LOG\" | " .. A .. " -F'\\t' \\\n    -v digests=\"$_pt_digests\" \\\n    'BEGIN { n = split(digests, dl, \"\\n\") } { print }'; } 2>/dev/null || true\n")
refused("awk -v of many lines, captured (tsfu)", "floor_text=\"$(grep -vE '^#' \"$FLOOR\")\"\njoined=\"$(" .. A .. " -v ft=\"$floor_text\" '\n    BEGIN { n = split(ft, L, \"\\n\") } NF == 2 { print }' <<<\"$counts\")\"\n")
passes("awk: ENVIRON instead", "joined=\"$(FT=\"$floor_text\" " .. A .. " 'BEGIN { n = split(ENVIRON[\"FT\"], L, \"\\n\") }' <<<\"$counts\")\"\n")
passes("awk: -v of a scalar", "ps -W | " .. A .. " -v p=\"$pid\" '$4 == p { found = 1 } END { exit !found }'\n")
passes("awk: the exemption", A .. " -v t=\"$tags\" 'BEGIN { n = split(t, T, \"\\n\") }' # awk-v-multiline: ok (fixture)\n")
local ONE = "x=$(" .. C .. ' "$1" in /*) echo a ;; *) echo r ;; esac)\n'
refused("case in $(): one line", ONE)
passes("case in $(): one line, parenthesised", "x=$(" .. C .. ' "$1" in (/*) echo a ;; (*) echo r ;; esac)\n')
refused("case in $(): many lines", "x=$(\n  " .. C .. ' "$1" in\n    /*) echo a ;;\n    *) echo r ;;\n  esac\n)\n')
passes("case in $(): many lines, parenthesised", "x=$(\n  " .. C .. ' "$1" in\n    (/*) echo a ;;\n    (*) echo r ;;\n  esac\n)\n')
refused("case in $(): quoted and nested", 'P="$(cd / && _p="$(pwd)" && ' .. C .. ' "$_p" in /*) printf a ;; *) printf r ;; esac)"\n')
passes("case in $(): the exemption", "x=$(" .. C .. ' "$1" in /*) echo a ;; esac) # case-in-cs: ok (fixture)\n')
passes("case outside $()", "( " .. C .. ' "$1" in /*) echo a ;; esac )\nf() { ' .. C .. ' "$1" in /*) echo a ;; esac; }\nx=$(f "$1")\n')
local x = check({ ["x.sh"] = ONE }, "files")
T:arm("scan: a named file list scopes it the same", x.out == "blocked:bash4-unguarded:1", x.why)
x = check{ ["a.sh"] = MF .. ' -t arr < "$1"\n', ["b.sh"] = LOWER }
T:arm("scan: two files count two", x.rc == 1 and x.out == "blocked:bash4-unguarded:2", x.why)
refused("sed: {p}", S .. " -n '/a/{p}' \"$1\"\n")
passes("sed: {p;}", S .. " -n '/a/{p;}' \"$1\"\n")
refused("sed: a # delimiter then }", S .. ' "\\\\#marker line#{n;s#return 0#return 1#}" "$G" > "$M"\n')
passes("sed: a # delimiter then ;}", S .. ' "\\\\#marker line#{n;s#return 0#return 1#;}" "$G" > "$M"\n')
refused("sed: {s/x/y/}", S .. " '/a/{s/x/y/}' \"$1\"\n")
refused("sed: a nested close", S .. " -n '1{/a/{p;}}' \"$1\"\n")
passes("sed: nested and terminated, braces in text", S .. " -n '1{/a/{p;};}' \"$1\"\nx=\"${HOME}/s/{a}\"; " .. S .. ' "s/${x}/{lit}/" "$1"\n')
passes("sed: -e per command", S .. " -e ':a' -e '/\\\\$/{N;s/\\\\\\n//;ba' -e '}' \"$1\"\n")
passes("sed: braces over lines", S .. " -n '/a/{\np\n}' \"$1\"\n")
passes("sed: the marker with a reason", S .. " -n '/a/{p}' \"$1\" # sed-brace: ok (fixture: GNU-only tool, never run on darwin)\n")
refused("sed: the marker with none", S .. " -n '/a/{p}' \"$1\" # sed-brace: ok\n")
for _, form in ipairs{ "-i 's/a/b/' \"$f\"", "-i \"s/a/$v/\" \"$f\"", "-i '2i cat >/dev/null' \"$f\"", "-i '' 's/a/b/' \"$f\"", "-n -i 's/a/b/' \"$f\"" } do
    refused("sed in place, no suffix [" .. form .. "]", S .. " " .. form .. "\n")
end
passes("sed in place: the portable forms and a mention", S .. " 's/a/b/' \"$f\" > \"$f.tmp\" && mv \"$f.tmp\" \"$f\"\n" .. S .. " -i.bak 's/a/b/' \"$f\" && rm -f \"$f.bak\"\necho \"never write " .. S .. " -i 's/a/b/' here\"\n")
refused("stat -c with no fallback", "m=\"$(" .. ST .. " -c %Y \"$d\" 2>/dev/null || echo '')\"\n")
refused("stat -f -c", 't="$(' .. ST .. ' -f -c %T "$d" 2>/dev/null)" || t=""\n')
passes("stat -c with a BSD fallback", 'm="$(' .. ST .. ' -c %Y "$d" 2>/dev/null || ' .. ST .. ' -f %m "$d" 2>/dev/null)"\nif ! mode="$(' .. ST .. " -c '%a' \"$f\" 2>/dev/null)\"; then\n    mode=\"$(" .. ST .. " -f '%Lp' \"$f\")\"\nfi\n")
passes("stat -c with its fallback in the same function", '_mt() {\n  local m\n  m="$(' .. ST .. ' -c %Y "$1" 2>/dev/null)" && { echo "$m"; return; }\n  :\n  :\n  :\n  :\n  ' .. ST .. ' -f %m "$1"\n}\n')
passes("stat -c with its marker and a reason", 't="$(' .. ST .. ' -c %a /dev/net/tun 2>/dev/null)" # stat-c: ok (linux-only device probe)\n')

-- The host's own sed. A red spelling that BSD sed accepts means the rule is wrong.
local r = T:run{ SH, "-s", stdin = [==[
f() { printf 'a\nreturn 0\nb\n' | "$SED" -n "$1" >/dev/null 2>&1; }
SED=se; SED="${SED}d"
if "$SED" --version >/dev/null 2>&1; then echo gnu; else echo bsd; fi
for p in '/a/{p}' '/a/{n;s#return 0#return 1#}' '/a/{s/a/X/}' '1{/a/{p;}}'; do f "$p" && echo "red-accepted $p"; done
for p in '/a/{p;}' '/a/{n;s#return 0#return 1#;}' '/a/{s/a/X/;}' '1{/a/{p;};}'; do f "$p" || echo "green-refused $p"; done
echo done
]==] }
local o = "\n" .. (r.stdout or "")
T:arm("host sed refuses every refused spelling, if it is BSD", text.contains(o, "\ngnu\n") or not text.contains(o, "\nred-accepted "), o)
T:arm("host sed takes every passed spelling", text.contains(o, "\ndone\n") and not text.contains(o, "\ngreen-refused "), o)
T:finish()

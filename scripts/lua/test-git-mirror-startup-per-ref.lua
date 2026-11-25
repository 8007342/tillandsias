-- @env PATH
-- @trace spec:git-mirror-service, order:2296-pn45
--
-- test-git-mirror-startup-per-ref.lua — regression pin for order 441, ported from the
-- .sh of the same name (2296-pn45). The mirror's startup retry-push relays PER REF, so a
-- fast-forwardable ref flushes even when a sibling is stranded, and a stranded ref is
-- logged BY NAME. The .sh re-implemented the loop; this one extracts and runs the REAL
-- startup_retry_push (and its credential test) from images/git/entrypoint.sh, with a mock
-- relay that refuses any ref containing "stranded". Offline.
--
--   1 FLUSHED    the fast-forwardable head after the stranded one is relayed
--   2 NAMED      the stranded head is logged by name with the relay's reason
--   3 TAG        a stranded tag is logged as expected, not as a fault
--   4 PER-REF    the relay is called once per ref, with one record each
--   5 SUMMARY    the closing line names every stranded ref and no flushed one
--   6 SKIPPED    an https remote with no credential is one line and no relay call
--
-- Usage: tillandsias-plan script run scripts/lua/test-git-mirror-startup-per-ref.lua
-- Verdict: ok:git-mirror-startup-per-ref:<n> arms | violation:...

local fixture = require "common.fixture"
local T = fixture.new("git-mirror-startup-per-ref")
local SH = fixture.posix_shell()
local src = "\n" .. fs.read("images/git/entrypoint.sh")
local fns = {}
for _, f in ipairs{ "_startup_upstream_credential", "startup_retry_push" } do
    local body = src:match("\n(" .. f .. "%(%) {\n.-\n}\n)")
    if not body then T:refuse("no-subject", f .. "() is not in images/git/entrypoint.sh") end
    fns[#fns + 1] = body
end
local S = T:scratch()
local MIRROR, WORK = S.abs .. "/mirror.git", S.abs .. "/work"
local ENV = { PATH = env.get("PATH"), HOME = S.abs, GIT_CONFIG_NOSYSTEM = "1",
    GIT_AUTHOR_NAME = "f", GIT_AUTHOR_EMAIL = "f@example.invalid",
    GIT_COMMITTER_NAME = "f", GIT_COMMITTER_EMAIL = "f@example.invalid" }
local function must(...)
    local r = proc.run{ argv = { ... }, env = ENV, timeout_ms = 60000 }
    if r.code ~= 0 then T:refuse("setup-failed", table.concat({ ... }, " ") .. ": " .. tostring(r.stderr)) end
end
must("git", "init", "-q", "--bare", MIRROR)
must("git", "init", "-q", "-b", "main", WORK)
must("git", "-C", WORK, "commit", "-q", "--allow-empty", "-m", "base")
-- `a-stranded` sorts before `main`, so an all-or-nothing sweep would lose main.
for _, r in ipairs{ "refs/heads/main", "refs/heads/a-stranded", "refs/tags/v-stranded" } do
    must("git", "-C", WORK, "push", "-q", MIRROR, "HEAD:" .. r)
end
fs.write(S.rel .. "/relay", "#!/bin/sh\nn=0\nwhile read -r old new ref; do\n  n=$((n + 1)); echo \"call-$$ $n $old $new $ref\" >> \"" .. S.abs .. "/calls\"\n"
    .. "  case \"$ref\" in *stranded*) echo \"refusing non-fast-forward: $ref\" >&2; exit 1 ;; esac\ndone\nexit 0\n")
must("chmod", "+x", S.abs .. "/relay")
local function sweep(remote)
    fs.write(S.rel .. "/calls", "")
    local r = proc.run{ argv = { SH, "-s", "--", MIRROR, remote }, env = ENV, timeout_ms = 60000,
        stdin = "retry_msg() { printf '%s\\n' \"$*\"; }\nRELAY_REF='" .. S.abs .. "/relay'\nVAULT_TOKEN_FILE='" .. S.abs .. "/no-token'\n"
            .. table.concat(fns) .. 'startup_retry_push "$1" "$2" 3 </dev/null\n' }
    local calls = {}
    for _, l in ipairs(text.lines(fs.read(S.rel .. "/calls"))) do if l ~= "" then calls[#calls + 1] = l end end
    return r.code, r.stdout or "", calls, r.stderr or ""
end

local c, o, calls, e = sweep("file:///nowhere")
local d = "rc=" .. tostring(c) .. " " .. o .. e
local summary = o:match("stranded=([^\n]*)") or ""
T:arm("1 FLUSHED the fast-forwardable head after the stranded one is relayed", text.contains(o, "retry-push OK: refs/heads/main"), d)
T:arm("2 NAMED the stranded head is logged by name with the relay's reason",
    text.contains(o, "STRANDED (logged by name): refs/heads/a-stranded") and text.contains(o, "refusing non-fast-forward: refs/heads/a-stranded"), d)
T:arm("3 TAG a stranded tag is logged as expected, not as a fault",
    text.contains(o, "STRANDED (expected, not a fault): refs/tags/v-stranded") and not text.contains(o, "(logged by name): refs/tags/"), d)
local once = #calls == 3
for _, l in ipairs(calls) do
    local n, old, new = l:match("^call%-%d+ (%d+) (%x+) (%x+) refs/")
    if n ~= "1" or old ~= new then once = false end
end
T:arm("4 PER-REF the relay is called once per ref, with one record each", once, table.concat(calls, " | "))
T:arm("5 SUMMARY the closing line names every stranded ref and no flushed one", summary == "refs/heads/a-stranded refs/tags/v-stranded", summary)
c, o, calls, e = sweep("https://example.invalid/r.git")
T:arm("6 SKIPPED an https remote with no credential is one line and no relay call",
    c == 0 and #calls == 0 and text.contains(o, "retry-push SKIPPED") and not text.contains(text.trim(o), "\n"), "rc=" .. tostring(c) .. " " .. o .. e)
T:finish()

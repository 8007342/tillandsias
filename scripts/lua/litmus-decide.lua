-- @trace order:1800-nvsc, order:1799-5kvy, order:1624-bv73
-- @env LITMUS_DECIDE_CARGO LITMUS_DECIDE_NO_CACHE LITMUS_DECIDE_CACHE_TTL_S
--
-- litmus-decide.lua — the parameterised deciders a litmus `command:` names
-- INSTEAD of a piped bash string.
--
-- WHY. 954 litmus commands pipe (quote-aware count, 2026-10-19; 1477 by raw
-- `|`), 162 of them three or more times. Each one re-parses a producer's
-- output with grep/awk/head and judges it in-line, and each one fails its own
-- way: `grep -q` under pipefail inverts (SIGPIPE), `head` truncates the line a
-- reader needed, `|| true` swallows the producer, and a `$(...)` capture with
-- no echo on the failing branch goes RED WITH EMPTY OUTPUT, which is what the
-- v56.10.19.1 release gate did on envelope-citability step 20 (1799-5kvy):
-- nobody could tell which test failed. The operator's direction (2026-10-19):
-- "these nested weird commands with lots of pipes should be parameterized Lua
-- scripts instead: `command: MyRobustLuaScript.lua`, which in its belly does
-- all the parsing and capturing of error states gracefully and provides proper
-- affordances for recoveries, retries, using caches, etc."
--
-- ONE SCRIPT, ONE FAMILY PER CALL. The runtime nils `require` (a decider is a
-- single file by design, script_run.rs), so the shared library below is a
-- section of this file and the family is the first argument:
--
--   tillandsias-plan script run scripts/lua/litmus-decide.lua -- <family> [--name <n>] <options>
--
-- FAMILIES (counts are the 2026-10-19 census, scratchpad classify.pl):
--   cargo-test      28    run `cargo test -p <pkg>` ONCE per tree state (cached),
--                         judge it by NAMED tests, never by a bare count
--   file-grep      299    a pattern over files: present | absent | count
--   (planned, each its own slice under 1800-nvsc: script-output 394,
--    structured-field 63, podman-probe 63, cargo-other 37, process 22,
--    plan-query 12, git-query 6)
--
-- CONTRACT, every family:
--   * an EMPTY POPULATION is could-not-run (exit 3), never ok: zero tests ran,
--     zero files matched the path list, a producer that printed nothing
--   * a MISSING TOOL (spawn failed) is could-not-run naming the tool, never a
--     refusal of the tree and never a pass
--   * every non-ok verdict carries `why:` and `remedy:` on stderr and names the
--     thing (the test, the file:line, the count) — a red with empty output is
--     unconstructible here: verdict.* always prints, and a script that falls
--     off the end is refused:no-verdict by the runner
--   * bounded retries for TRANSIENT producer failures only (a build-directory
--     lock, a busy resource), never for a failed assertion: `--retries N`
--   * caching where it is SAFE: a cargo test run is keyed on the package, the
--     cargo argv, HEAD, and the sha256 of `git diff HEAD` plus the untracked
--     list under crates/, with a TTL (default 1800 s). Every step that judges
--     the same crate in one gate shares one run. LITMUS_DECIDE_NO_CACHE=1
--     disables it; the ok line says cache=hit|miss|off so a reader never
--     has to infer it.
--
-- VERDICT GRAMMAR (script_run.rs; the runner's expected_behavior is a
-- containment match on stdout, so a step declares `ok:<name>`):
--   ok:<name>:<facts>                                   exit 0
--   refused:<name>:<reason>[:<detail>]                  exit 1  (the tree failed)
--   could-not-run:<name>:<reason>                       exit 3  (nothing was decided)
--
-- Usage examples:
--   -- cargo-test --package tillandsias-plan --min-ok 'answer::tests::' 8 \
--        --require-ok every_live_packet_has_a_span_that_contains_its_own_id \
--        --name envelope-unit-pins-green
--   -- file-grep --path crates/tillandsias-plan/src/answer.rs \
--        --pattern 'citations.is_empty\(\) \|\| confidence == Confidence::Unsupported' \
--        --mode present --name confidence-is-derived
--   -- file-grep --path skills --suffix .md --pattern 'python3? .*yaml' --mode absent

-- ═══════════════════════════════════════════════════════════════════════════
-- LIB — shared by every family
-- ═══════════════════════════════════════════════════════════════════════════
local FAMILIES = {}

local function why(s) log.raw("  why: " .. s) end
local function remedy(s) log.raw("  remedy: " .. s) end
local function lines(s) local t = {}; for l in ((s or "") .. "\n"):gmatch("(.-)\n") do t[#t + 1] = l end; if t[#t] == "" then t[#t] = nil end; return t end

-- parse_args: `--k v` pairs (repeatable keys collect in order), `--flag`
-- booleans from a declared set, the rest positional.
local function parse_args(argv, flags)
    local opts, pos, i = {}, {}, 1
    while i <= #argv do
        local a = argv[i]
        local k = a:match("^%-%-([%w%-]+)$")
        if k and flags[k] then
            opts[k] = true; i = i + 1
        elseif k then
            local v = argv[i + 1]
            if v == nil then return nil, "option --" .. k .. " needs a value" end
            opts[k] = opts[k] or {}
            opts[k][#opts[k] + 1] = v
            i = i + 2
        else
            pos[#pos + 1] = a; i = i + 1
        end
    end
    return opts, pos
end
local function one(opts, k) return opts[k] and opts[k][#opts[k]] or nil end
local function num(opts, k, default) local v = one(opts, k); if v == nil then return default end; local n = tonumber(v); if not n then return nil, "--" .. k .. " must be a number, got '" .. v .. "'" end; return n end

-- run_once: proc.run in argv form; a missing program is reported as such,
-- never folded into "the producer failed".
local function run_once(argv, opts)
    local spec = { argv = argv, timeout_ms = (opts and opts.timeout_ms) or 600000 }
    if opts and opts.cwd then spec.cwd = opts.cwd end
    if opts and opts.env then spec.env = opts.env end
    local ok, r = pcall(proc.run, spec)
    if not ok then return { status = "error", stderr = tostring(r), stdout = "" } end
    return r
end

-- run_with_retry: retries ONLY when the failure text matches transient_re.
-- A failed assertion is never retried: a flaky test retried to green is a
-- false green, and a step that wants it must say so in its own words.
local DEFAULT_TRANSIENT = "Blocking waiting for file lock|resource busy|Text file busy|Resource temporarily unavailable"
local function run_with_retry(argv, opts)
    local retries = (opts and opts.retries) or 0
    local transient = (opts and opts.transient_re) or DEFAULT_TRANSIENT
    local delay_ms = (opts and opts.retry_delay_ms) or 500
    local attempts = 0
    local r
    while true do
        attempts = attempts + 1
        r = run_once(argv, opts)
        local text_all = (r.stdout or "") .. "\n" .. (r.stderr or "")
        local failed = not (r.status == "exited" and r.code == 0)
        if not failed or attempts > retries or not text.is_match(text_all, transient) then break end
        log.raw("  retry " .. attempts .. "/" .. retries .. ": transient producer failure (" .. (text.first_match(text_all, transient, { lines = 1 }) or transient) .. ")")
        if delay_ms > 0 then run_once({ "sleep", tostring(delay_ms / 1000) }, { timeout_ms = delay_ms + 5000 }) end
    end
    return r, attempts
end

-- tool_missing: the could-not-run every family emits for a spawn failure.
local function tool_missing(name, argv, r)
    local L = "could-not-run:" .. name .. ":tool-missing:" .. argv[1]
    why((r.stderr or r.status or "spawn failed"))
    remedy("install or name the tool (the first argv element, '" .. argv[1] .. "'); a missing producer decides nothing about the tree")
    verdict.emit(L, 3, "producer could not start: " .. table.concat(argv, " "))
end

-- cache: target/plan-scratch/litmus-decide-cache/<sha>.out, keyed on the
-- producer argv and the TREE STATE (HEAD + sha256 of the diff and untracked
-- list under `paths`). A hit prints its age so a reader can judge it.
local CACHE_DIR = "target/plan-scratch/litmus-decide-cache"
local function tree_state(paths)
    local head = run_once({ "git", "rev-parse", "HEAD" }, { timeout_ms = 20000 })
    if not (head.status == "exited" and head.code == 0) then return nil end
    local diff_argv = { "git", "diff", "HEAD", "--" }
    local untracked_argv = { "git", "ls-files", "--others", "--exclude-standard", "--" }
    for _, p in ipairs(paths) do diff_argv[#diff_argv + 1] = p; untracked_argv[#untracked_argv + 1] = p end
    local d = run_once(diff_argv, { timeout_ms = 60000 })
    local u = run_once(untracked_argv, { timeout_ms = 60000 })
    if not (d.status == "exited" and u.status == "exited") then return nil end
    -- an untracked file's CONTENT is part of the state, not only its name
    local untracked_blob = ""
    for _, f in ipairs(lines(u.stdout)) do
        local okr, body = pcall(fs.read, f)
        untracked_blob = untracked_blob .. "\n== " .. f .. "\n" .. (okr and body or "<unreadable>")
    end
    return text.trim(head.stdout) .. ":" .. hash.sha256((d.stdout or "") .. untracked_blob)
end
local function cache_key(family, argv, paths)
    local st = tree_state(paths)
    if not st then return nil end
    return hash.sha256(family .. "\0" .. table.concat(argv, "\0") .. "\0" .. st)
end
local function cache_get(key, ttl_s)
    if not key then return nil end
    local p = CACHE_DIR .. "/" .. key .. ".out"
    if not fs.exists(p) then return nil end
    local okr, body = pcall(fs.read, p)
    if not okr then return nil end
    local ts = tonumber(body:match("^#litmus%-decide%-cache ts_ms=(%d+)\n"))
    if not ts then return nil end
    local age_s = math.floor((time.now_ms() - ts) / 1000)
    if age_s < 0 or age_s > ttl_s then return nil end
    return body:gsub("^[^\n]*\n", "", 1), age_s
end
local function cache_put(key, body)
    if not key then return end
    pcall(fs.mkdir, CACHE_DIR)
    pcall(fs.write, CACHE_DIR .. "/" .. key .. ".out", "#litmus-decide-cache ts_ms=" .. tostring(time.now_ms()) .. "\n" .. body)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FAMILY cargo-test
-- ═══════════════════════════════════════════════════════════════════════════
-- Options:
--   --package <crate>        required
--   --filter <substr>        cargo's positional test filter (optional)
--   --cargo-arg <a>          extra cargo args, repeatable (e.g. --features x)
--   --min-ok <re> <n>        at least n lines `test <re>.* ... ok` (repeatable;
--                            two positionals after the flag)
--   --require-ok <test>      the EXACT test name must have run and passed
--                            (repeatable). Absent is `missing-test`, distinct
--                            from failed: a renamed pin is not a green pin.
--   --retries <n>            transient-only retries (default 1)
--   --timeout-ms <ms>        producer deadline (default 900000)
--   --no-cache               force a fresh run
-- Verdicts:
--   ok:<name>:n=<passed>:failed=0:cache=hit|miss|off[:age=<s>]:attempts=<k>
--   refused:<name>:failed=<k>            the failing tests and panics on stderr
--   refused:<name>:compile-error         the first error lines on stderr
--   refused:<name>:only=<c>:need=<n>:<re>
--   refused:<name>:missing-test:<test>
--   could-not-run:<name>:empty-population   zero tests ran (a filter that
--                                           matches nothing, or a crate with
--                                           no tests) — never a pass
--   could-not-run:<name>:tool-missing:cargo
--   could-not-run:<name>:timed-out:<ms>
FAMILIES["cargo-test"] = function(name, argv)
    local opts, pos = parse_args(argv, { ["no-cache"] = true })
    if not opts then verdict.could_not_run(name, pos) end
    local pkg = one(opts, "package")
    if not pkg then
        why("cargo-test needs --package <crate>")
        remedy("name the crate whose tests decide this step, e.g. --package tillandsias-plan")
        verdict.could_not_run(name .. ":no-package")
    end
    local retries = num(opts, "retries", 1)
    local timeout_ms = num(opts, "timeout-ms", 900000)
    local cargo = env.get("LITMUS_DECIDE_CARGO")
    if not cargo or cargo == "" then cargo = "cargo" end
    local cargo_argv = { cargo, "test", "-p", pkg }
    for _, a in ipairs(opts["cargo-arg"] or {}) do cargo_argv[#cargo_argv + 1] = a end
    if one(opts, "filter") then cargo_argv[#cargo_argv + 1] = one(opts, "filter") end
    -- min-ok pairs: the flag takes TWO values, so they arrive as `--min-ok re`
    -- followed by a positional n; pair them up in order.
    local mins = {}
    for i, re in ipairs(opts["min-ok"] or {}) do
        local n = tonumber(pos[i])
        if not n then
            why("--min-ok takes two values: <re> <n>; got re='" .. re .. "' n='" .. tostring(pos[i]) .. "'")
            remedy("write --min-ok 'answer::tests::' 8")
            verdict.could_not_run(name .. ":bad-min-ok")
        end
        mins[#mins + 1] = { re = re, n = n }
    end

    local cache_mode = "off"
    local key, age
    local no_cache = opts["no-cache"] or (env.get("LITMUS_DECIDE_NO_CACHE") or "") ~= ""
    local ttl = tonumber(env.get("LITMUS_DECIDE_CACHE_TTL_S") or "") or 1800
    local output, attempts, status, code = nil, 0, "exited", 0
    if not no_cache then
        key = cache_key("cargo-test", cargo_argv, { "crates", "Cargo.toml", "Cargo.lock" })
        local hit
        hit, age = cache_get(key, ttl)
        if hit then output, cache_mode = hit, "hit" else cache_mode = "miss" end
    end
    if not output then
        local r
        r, attempts = run_with_retry(cargo_argv, { retries = retries, timeout_ms = timeout_ms })
        if r.status == "spawn_failed" or r.status == "error" then tool_missing(name, cargo_argv, r) end
        if r.status == "timed_out" then
            why("cargo test -p " .. pkg .. " outlived " .. timeout_ms .. " ms")
            remedy("raise --timeout-ms, or split the crate's slow tests behind a --filter")
            verdict.could_not_run(name .. ":timed-out:" .. timeout_ms)
        end
        if r.status ~= "exited" then
            why("producer status " .. tostring(r.status) .. ": " .. (r.stderr or ""))
            verdict.could_not_run(name .. ":producer-" .. tostring(r.status))
        end
        status, code = r.status, r.code
        output = (r.stdout or "") .. "\n" .. (r.stderr or "")
        -- cache only a COMPLETE run; a compile error is cached too (the tree
        -- state is in the key, so a fix misses)
        if key then cache_put(key, output) end
    end

    -- judge
    local compile_err = text.is_match(output, "(?m)^error(\\[E[0-9]+\\])?: |could not compile")
    local failed_names = text.captures_all(output, "(?m)^test (.+) \\.\\.\\. FAILED$")
    local panics = text.captures_all(output, "(?m)^(.*panicked at .*)$")
    local passed = text.count_lines(output, "^test .* \\.\\.\\. ok$")
    local ran = passed + #failed_names + text.count_lines(output, "^test .* \\.\\.\\. ignored")
    local facts = ":cache=" .. cache_mode .. (age and (":age=" .. age .. "s") or "") .. ":attempts=" .. attempts
    if compile_err then
        local L = "refused:" .. name .. ":compile-error" .. facts
        for _, l in ipairs(lines(text.first_match(output, "^error.*", { lines = 20 }) or "")) do log.raw("  " .. l) end
        why("the crate did not build, so no test decided anything")
        remedy("cargo build -p " .. pkg .. " --tests, fix the first error above")
        verdict.emit(L, 1, "compile error in " .. pkg)
    end
    if #failed_names > 0 or #panics > 0 then
        local L = "refused:" .. name .. ":failed=" .. #failed_names .. facts
        log.raw("  failing tests (" .. #failed_names .. "):")
        for i, t in ipairs(failed_names) do if i <= 40 then log.raw("    FAILED " .. t) end end
        if #panics > 0 then
            log.raw("  panics (" .. #panics .. "):")
            for i, p in ipairs(panics) do if i <= 40 then log.raw("    " .. text.trim(p)) end end
        end
        why(#failed_names .. " test(s) failed in " .. pkg .. (#panics > 0 and ("; " .. #panics .. " panic line(s)") or ""))
        remedy("cargo test -p " .. pkg .. " " .. (failed_names[1] or "") .. " -- --nocapture")
        verdict.emit(L, 1, "named above")
    end
    if ran == 0 and code ~= 0 then
        -- the producer died before any test ran (a lock, a killed harness):
        -- nothing was decided about the tree, so this is not a refusal
        local L = "could-not-run:" .. name .. ":producer-exit=" .. tostring(code) .. facts
        for _, l in ipairs(lines(text.first_match(output, "^(error.*|Blocking.*|.*[Ll]ock.*)$", { lines = 10 }) or "")) do log.raw("  " .. l) end
        why("`" .. table.concat(cargo_argv, " ") .. "` exited " .. tostring(code) .. " before running a single test")
        remedy("re-run; if the cause is a build-directory lock, another cargo holds it (--retries N waits for it); if it is a compile error, the first error line is above")
        verdict.emit(L, 3, "producer failed before any test ran")
    end
    if ran == 0 then
        local L = "could-not-run:" .. name .. ":empty-population" .. facts
        why("zero tests ran for `" .. table.concat(cargo_argv, " ") .. "` (exit " .. tostring(code) .. "); a run with nothing in it cannot be green")
        for _, l in ipairs(lines(text.first_match(output, "^(running 0 tests|test result:.*)$", { lines = 5 }) or "")) do log.raw("  " .. l) end
        remedy("check --package and --filter: the filter must match at least one test; drop --filter to see the crate's tests")
        verdict.emit(L, 3, "zero tests ran")
    end
    if code ~= 0 then
        local L = "refused:" .. name .. ":exit=" .. tostring(code) .. facts
        for _, l in ipairs(lines(text.first_match(output, "^(error.*|test result:.*)$", { lines = 10 }) or "")) do log.raw("  " .. l) end
        why("cargo test exited " .. tostring(code) .. " without a named FAILED test or panic (a doctest or harness failure)")
        remedy("cargo test -p " .. pkg .. " 2>&1 | tail -40")
        verdict.emit(L, 1, "non-zero exit")
    end
    for _, m in ipairs(mins) do
        local c = text.count_lines(output, "^test " .. m.re .. ".* \\.\\.\\. ok$")
        if c < m.n then
            local L = "refused:" .. name .. ":only=" .. c .. ":need=" .. m.n .. ":" .. m.re .. facts
            why("only " .. c .. " passing tests match `" .. m.re .. "`; the step pins at least " .. m.n)
            remedy("if tests were MOVED, update --min-ok's pattern; if they were DELETED, that is the regression this step exists to catch")
            verdict.emit(L, 1, m.re)
        end
    end
    for _, t in ipairs(opts["require-ok"] or {}) do
        if not text.is_match(output, "(?m)^test (.*::)?" .. text.escape(t) .. " \\.\\.\\. ok$") then
            local L = "refused:" .. name .. ":missing-test:" .. t .. facts
            why("the pinned test `" .. t .. "` did not run and pass (renamed, deleted, ignored, or filtered out)")
            remedy("grep -rn '" .. t .. "' crates/; a renamed pin must be renamed here too")
            verdict.emit(L, 1, "pin not present")
        end
    end
    verdict.ok(name, "n=" .. passed, "failed=0", "cache=" .. cache_mode .. (age and (":age=" .. age .. "s") or ""), "attempts=" .. attempts)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- FAMILY file-grep
-- ═══════════════════════════════════════════════════════════════════════════
-- Options:
--   --path <p>           file or directory, repo-relative, repeatable
--   --suffix <s>         when a path is a directory, only files ending in s
--   --pattern <re>       Rust regex over each LINE (one pattern)
--   --fixed              the pattern is a literal, not a regex
--   --mode present|absent|count   (default present)
--   --min <n> --max <n>  for count
-- Verdicts:
--   ok:<name>:matches=<k>:files=<f>
--   refused:<name>:present-but-missing          (mode present, 0 matches)
--   refused:<name>:absent-but-found:<file>:<line>
--   refused:<name>:count=<k>:min=<n>|max=<n>
--   could-not-run:<name>:empty-population        no readable file in --path
FAMILIES["file-grep"] = function(name, argv)
    local opts, pos = parse_args(argv, { fixed = true })
    if not opts then verdict.could_not_run(name, pos) end
    local pat = one(opts, "pattern")
    if not pat or not opts.path then
        why("file-grep needs --path <file|dir> (repeatable) and --pattern <re>")
        remedy("e.g. --path crates/tillandsias-plan/src/answer.rs --pattern 'fn supported' --mode present")
        verdict.could_not_run(name .. ":bad-arguments")
    end
    if opts.fixed then pat = text.escape(pat) end
    local mode = one(opts, "mode") or "present"
    local suffix = one(opts, "suffix")
    local files = {}
    for _, p in ipairs(opts.path) do
        if fs.exists(p) then
            -- a regular file reads; a directory does not, and walks instead
            local okr = pcall(fs.read, p)
            if okr then
                files[#files + 1] = p
            else
                local okw, walked = pcall(fs.walk, p, suffix and { suffix = suffix } or nil)
                if okw then for _, f in ipairs(walked) do files[#files + 1] = f end end
            end
        end
    end
    if #files == 0 then
        local L = "could-not-run:" .. name .. ":empty-population"
        why("no readable file under --path " .. table.concat(opts.path, ", ") .. (suffix and (" with suffix " .. suffix) or "") .. "; a grep over nothing decides nothing")
        remedy("check the path(s) exist on this tree; a moved file must move here too")
        verdict.emit(L, 3, "no files")
    end
    local total, first = 0, nil
    for _, f in ipairs(files) do
        local okr, body = pcall(fs.read, f)
        if okr then
            local c = text.count_lines(body, pat)
            if c > 0 and not first then
                local ln = 0
                for i, l in ipairs(lines(body)) do if text.is_match(l, pat) then ln = i; first = { f = f, line = i, txt = l }; break end end
            end
            total = total + c
        end
    end
    local facts = "matches=" .. total .. ":files=" .. #files
    if mode == "present" then
        if total == 0 then
            local L = "refused:" .. name .. ":present-but-missing:" .. facts
            why("`" .. pat .. "` matched no line in " .. #files .. " file(s)")
            remedy("if the text moved, point --path at its new home; if it was deleted, that is the regression this step catches")
            verdict.emit(L, 1, pat)
        end
    elseif mode == "absent" then
        if total > 0 then
            local L = "refused:" .. name .. ":absent-but-found:" .. first.f .. ":" .. first.line
            log.raw("    " .. first.f .. ":" .. first.line .. ": " .. first.txt)
            why("`" .. pat .. "` must not appear; " .. total .. " line(s) match")
            remedy("remove the matching line(s), or narrow --pattern if the match is a mention rather than a use")
            verdict.emit(L, 1, first.txt)
        end
    elseif mode == "count" then
        local mn, mx = num(opts, "min", nil), num(opts, "max", nil)
        if mn and total < mn then
            local L = "refused:" .. name .. ":count=" .. total .. ":min=" .. mn
            why("`" .. pat .. "` matched " .. total .. " line(s); the step needs at least " .. mn)
            verdict.emit(L, 1, pat)
        end
        if mx and total > mx then
            local L = "refused:" .. name .. ":count=" .. total .. ":max=" .. mx
            why("`" .. pat .. "` matched " .. total .. " line(s); the step allows at most " .. mx)
            verdict.emit(L, 1, pat)
        end
    else
        why("--mode must be present, absent or count; got '" .. mode .. "'")
        verdict.could_not_run(name .. ":bad-mode")
    end
    verdict.ok(name, facts)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DISPATCH
-- ═══════════════════════════════════════════════════════════════════════════
local family = arg[1]
local rest = {}
for i = 2, #arg do rest[#rest + 1] = arg[i] end
-- --name may appear anywhere; it names the verdict and is not a family option
local name
local stripped = {}
local i = 1
while i <= #rest do
    if rest[i] == "--name" then name = rest[i + 1]; i = i + 2 else stripped[#stripped + 1] = rest[i]; i = i + 1 end
end
if not family or not FAMILIES[family] then
    local known = {}
    for k in pairs(FAMILIES) do known[#known + 1] = k end
    table.sort(known)
    local L = "could-not-run:litmus-decide:unknown-family:" .. tostring(family)
    why("the first argument names the decider family; known: " .. table.concat(known, ", "))
    remedy("tillandsias-plan script run scripts/lua/litmus-decide.lua -- <family> --name <verdict-name> <options>")
    verdict.emit(L, 3, "unknown family")
end
FAMILIES[family](name or family, stripped)

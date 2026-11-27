-- @trace order:1274-cbk7, order:1303-2d5g, order:2164-desp, order:2387-lrg2, spec:spec-traceability
-- @env PATH
-- preflight: gate-only — runs scripts/run-litmus-test.sh end to end (the whole litmus runner)
--
-- test-litmus-parse-only-duplicate-key.lua — two checks answer two questions:
--   run-litmus-test.sh --parse-only           -> can the RUNNER extract steps here
--   scripts/lua/check-litmus-yaml-parses.lua  -> does this LOAD as YAML
-- The runner's line parser took the last of a duplicated key; a loader rejects the document.
-- During 1252-znbn three corpus files gained one, --parse-only said ok, and the gate refused
-- ~15 minutes later (1274-cbk7). Ported from test-litmus-parse-only-duplicate-key.sh
-- (2387-lrg2); same arms, in its order:
--
--    0  PREMISE   the loader accepts the clean probe and rejects the duplicate
--    1  PRE-FIX   detector AND load (1303-2d5g) neutralised in a copy: the false green returns;
--                 both mutations asserted applied first
--  2-4  a duplicated assert_output_contains / timeout_ms / command is refused, file and key named
--    5  NEGATIVE  the clean probe still parses, exit 0
--    6  CORPUS    every real corpus file has a verdict, and each live refusal is one the base
--                 copy refuses too (this change adds no refusal; 2164-desp: base parses only those)
--    7  the mode states its scope (FILES NAMED) and names check-litmus-yaml-parses.lua
--    8  a merged `- name:` item is NOT a duplicated key (the loader accepts it)
--    9  the corpus comparator rejects an equal-count, different-names set
-- 10-15 parse-only runs no Rust query, podman probe or remote/fake check; normal mode still
--       does (13 is Linux-only: podman preflight), and nothing reaches cargo/rustup/toolbox/docker
--
-- Arm 1 is the load-bearing one: without it every other arm stays green if the detector is
-- deleted. Sentinels on PATH refuse and record every tool the runner must not reach. The
-- prefix is assembled (LIT) so check-litmus-pin-claims.sh reads no claim here.
--
-- GRAMMAR ok:litmus-parse-only-duplicate-key:<n> arms
--       | violation:litmus-parse-only-duplicate-key:<n>-failed
--       | skip:litmus-parse-only-duplicate-key:no-yaml-reader

local fixture = require "common.fixture"
local SH = fixture.posix_shell()
local LIT = "litmus"
local T = fixture.new(LIT .. "-parse-only-duplicate-key")
local ROOT = fixture.repo_root()
local SUBJ = "scripts/run-litmus-test.sh"
local OK_PARSEABLE = "ok:" .. LIT .. "-parseable"

-- Resolve from this checkout (1401-x76w), not the caller's PATH.
local READER = fixture.plan_binary()
if READER == "" then T:skip("no-yaml-reader") end
if not fixture.is_abs(READER) then READER = ROOT .. "/" .. READER:gsub("^%./", "") end

local W = T:scratch()
local TMP = W.abs
local function put(rel, body, exec)
    fs.write(W.rel .. "/" .. rel, body)
    if exec then T:must{ "chmod", "+x", TMP .. "/" .. rel } end
end
fs.mkdir(W.rel .. "/project/scripts"); fs.mkdir(W.rel .. "/project/images/router")
fs.mkdir(W.rel .. "/bin"); fs.mkdir(W.rel .. "/markers"); fs.mkdir(W.rel .. "/tests")
local SUBJ_TEXT = fs.read(SUBJ)
put("project/scripts/run-litmus-test.sh", SUBJ_TEXT, true)
put("project/scripts/plan-binary-probe.sh", fs.read("scripts/plan-binary-probe.sh"))
put("project/images/router/tillandsias-router-sidecar", "")
local RUNNER = TMP .. "/project/scripts/run-litmus-test.sh"
local PREFIX_RUNNER = TMP .. "/project/scripts/prefix-runner.sh"
local SENT = '#!/bin/sh\nname=${0##*/}\nprintf \'%s\\n\' "$*" >> "$SENTINEL_DIR/$name"\n'
    .. 'echo "refused:fixture-sentinel:$name:73" >&2\nexit 73\n'
for _, tool in ipairs{ "tillandsias-litmus-rust", "cargo", "rustup", "toolbox", "podman", "docker" } do
    put("bin/" .. tool, SENT, true)
end
put("bin/yq", "#!/bin/sh\nexit 73\n", true)
put("project/scripts/tillandsias-podman", '#!/bin/sh\nprintf \'%s\\n\' "$*" >> "$SENTINEL_DIR/podman"\n'
    .. "echo 'refused:fixture-sentinel:podman:73' >&2\nexit 73\n", true)

local BASE_ENV = {
    PATH = TMP .. "/bin:" .. (env.get("PATH") or "/usr/bin:/bin"), SENTINEL_DIR = TMP .. "/markers",
    TILLANDSIAS_PLAN_BIN = READER, CARGO_TARGET_DIR = TMP .. "/cargo-target",
    TILLANDSIAS_LITMUS_RUNTIME_DIR = TMP .. "/project/target/litmus-runtime",
    LITMUS_PODMAN_CALLS_FILE = TMP .. "/podman-calls.log", XDG_RUNTIME_DIR = TMP,
    TILLANDSIAS_TIMING_LOG = TMP .. "/timing.jsonl", LITMUS_STEP_TIMING_LOG = TMP .. "/steps.jsonl",
}
local UNSET = { "CONTAINER_HOST", "TILLANDSIAS_PODMAN_REMOTE_URL", "TILLANDSIAS_PODMAN_BIN",
    "TILLANDSIAS_REAL_PODMAN", "LITMUS_PODMAN_MODE" }
-- run_runner(runner, args, extra_env) -> code, stdout, stderr
local function run_runner(runner, args, extra)
    local e = {}
    for k, v in pairs(BASE_ENV) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    local argv = { SH, runner }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    argv.cwd, argv.env, argv.env_unset, argv.timeout_ms = ROOT, e, UNSET, 300000
    local r = T:run(argv)
    return r.code, r.stdout or "", r.stderr or ""
end
local function last(s) local ls = text.lines(text.trim(s)); return ls[#ls] or "" end
local function exists(abs) return T:run{ "test", "-e", abs }.code == 0 end
local function nonempty(abs) return T:run{ "test", "-s", abs }.code == 0 end
local function rm_markers() for _, f in ipairs(fs.list(W.rel .. "/markers") or {}) do
    T:run{ "rm", "-f", TMP .. "/markers/" .. (f:match("[^/]+$")) } end end

local function probe_text(extra)
    local l = { "name: " .. LIT .. ":cbk7-probe", "spec: spec-traceability", "phase: pre-build",
        "severity: high", "size: instant", "description: >", "  probe for 1274-cbk7", "critical_path:",
        '  - step: "a step"', '    command: "echo hello"', "    timeout_ms: 3000" }
    if extra and extra ~= "" then l[#l + 1] = extra end
    l[#l + 1] = '    expected_behavior: "hello"'
    return table.concat(l, "\n") .. "\n"
end
put("clean.yaml", probe_text('    assert_output_contains: "hello"'))
put("dup-assert.yaml", probe_text('    assert_output_contains: "hello"\n    assert_output_contains: "hello"'))
put("dup-timeout.yaml", probe_text("    timeout_ms: 9000"))
put("dup-command.yaml", probe_text('    command: "echo again"'))
local function yaml_rc(abs) return T:run{ READER, "validate-yaml", abs, timeout_ms = 30000 }.code end

-- ARM 0
local rc_clean, rc_dup = yaml_rc(TMP .. "/clean.yaml"), yaml_rc(TMP .. "/dup-assert.yaml")
T:arm("ARM 0: premise — a YAML loader ACCEPTS the clean probe and REJECTS the duplicate",
    rc_clean == 0 and rc_dup ~= 0, "clean rc=" .. tostring(rc_clean) .. " dup rc=" .. tostring(rc_dup))

-- ARM 1: two sites since 1303-2d5g — the load sits above the detector.
local function count_lines(s, pat) local n = 0
    for _, l in ipairs(text.lines(s)) do if l:find(pat) then n = n + 1 end end return n end
local pl = {}
for _, l in ipairs(text.lines(SUBJ_TEXT)) do
    if l:match("^ *duplicate_keys%+=%(") then l = "                    : # neutralised for ARM 1"
    elseif l:match("^ *local _parse_load_enabled=1 ") then l = "                local _parse_load_enabled=0 # neutralised for ARM 1" end
    pl[#pl + 1] = l
end
local PREFIX_TEXT = table.concat(pl, "\n") .. "\n"
put("project/scripts/prefix-runner.sh", PREFIX_TEXT, true)
local live_load = count_lines(SUBJ_TEXT, "local _parse_load_enabled=1 ")
local mut_load = count_lines(PREFIX_TEXT, "local _parse_load_enabled=1 ")
-- "+=(" is a Lua pattern error, so this one is counted literally.
local function count_plain(s, needle) local n = 0
    for _, l in ipairs(text.lines(s)) do if l:find(needle, 1, true) then n = n + 1 end end return n end
local live_hits, mut_hits = count_plain(SUBJ_TEXT, "duplicate_keys+=("), count_plain(PREFIX_TEXT, "duplicate_keys+=(")
local applied = live_hits >= 1 and mut_hits == 0 and live_load >= 1 and mut_load == 0
if applied then
    local prc, po, pe = run_runner(PREFIX_RUNNER, { "--parse-only", TMP .. "/dup-assert.yaml" })
    T:arm("ARM 1: PRE-FIX the duplicate is reported parseable and exits 0 — the defect reproduces on demand",
        prc == 0 and text.contains(po .. pe, OK_PARSEABLE), "rc=" .. tostring(prc))
else
    T:arm("ARM 1: both mutations applied to the pre-fix copy", false,
        "detector live=" .. live_hits .. " mutant=" .. mut_hits .. "; load live=" .. live_load .. " mutant=" .. mut_load)
end

-- ARMS 2-4
for _, p in ipairs{ { "dup-assert", "assert_output_contains" }, { "dup-timeout", "timeout_ms" }, { "dup-command", "command" } } do
    local rc, o, e = run_runner(RUNNER, { "--parse-only", TMP .. "/" .. p[1] .. ".yaml" })
    local all = o .. e
    T:arm("ARM: duplicated '" .. p[2] .. "' refused, refusal names the file and the key",
        rc ~= 0 and text.contains(all, p[1] .. ".yaml") and text.contains(all, p[2]),
        "rc=" .. tostring(rc) .. " " .. last(all))
end

-- ARM 5
local rc5, o5, e5 = run_runner(RUNNER, { "--parse-only", TMP .. "/clean.yaml" })
T:arm("ARM 5: a clean probe still reports parseable with its step count, exit 0",
    rc5 == 0 and text.contains(o5 .. e5, OK_PARSEABLE), "rc=" .. tostring(rc5))

-- ARM 6
local function accepted_set(stdout)
    local set, list = {}, {}
    for _, l in ipairs(text.lines(stdout)) do
        local f = l:match("^" .. OK_PARSEABLE:gsub("%-", "%%-") .. ":(.*):%d+ step%(s%)$")
        if f and not set[f] then set[f] = true; list[#list + 1] = f end
    end
    table.sort(list)
    return set, list
end
local function same_set(a, b) return table.concat(a, "\n") == table.concat(b, "\n") end
if applied then
    local corpus = {}
    for _, f in ipairs(fs.list("openspec/" .. LIT .. "-tests") or {}) do
        local name = f:match("[^/]+$")
        if name:match("%.yaml$") then corpus[#corpus + 1] = "openspec/" .. LIT .. "-tests/" .. name end
    end
    table.sort(corpus)
    -- 2418-kvdz: in batches. One argv naming the whole corpus passed the 32 767-character Windows
    -- command-line limit (os error 206, spawn failed, every file "unaccounted"). The merged
    -- verdict is the same on every host: stdout and stderr concatenated, the worst exit kept, and
    -- a batch that never ran (no exit code) keeps crc nil, so the arm still fails.
    local crc, co, ce = 0, "", ""
    for i = 1, #corpus, 80 do
        local args = { "--parse-only" }
        for j = i, math.min(i + 79, #corpus) do args[#args + 1] = corpus[j] end
        local brc, bo, be = run_runner(RUNNER, args)
        co, ce = co .. bo, ce .. be
        if brc == nil or crc == nil then crc = nil elseif brc > crc then crc = brc end
    end
    local acc = accepted_set(co)
    local diag = ce:gsub("\27%[[0-9;]*m", "")
    local dl = {}
    for _, l in ipairs(text.lines(diag)) do dl[l] = true end
    local refused, ok_all, unacc = {}, true, {}
    local in_corpus = {}
    for _, f in ipairs(corpus) do
        in_corpus[f] = true
        if not acc[f] then
            if dl["  [PARSE FAIL] " .. f] or text.contains(diag, "  [PARSE ERROR] " .. f .. ":")
                or dl["blocked:parse-only:not-yaml:" .. f] then refused[#refused + 1] = f
            else unacc[#unacc + 1] = f; ok_all = false end
        end
    end
    for f in pairs(acc) do if not in_corpus[f] then ok_all = false end end
    if #refused == 0 then ok_all = ok_all and crc == 0 else ok_all = ok_all and crc == 1 end
    local new_ref = {}
    if #refused > 0 then
        local bargs = { "--parse-only" }
        for _, f in ipairs(refused) do bargs[#bargs + 1] = f end
        local _, bo = run_runner(PREFIX_RUNNER, bargs)
        local _, bl = accepted_set(bo)
        new_ref = bl
    end
    out.line("corpus:live:files=" .. #corpus .. " refused=" .. #refused .. " rc=" .. tostring(crc))
    T:arm("ARM 6: every real corpus file is accounted for, and each live refusal was already refused by the base copy",
        ok_all and #new_ref == 0, "unaccounted=" .. table.concat(unacc, ",") .. " new-refusals=" .. table.concat(new_ref, ","))
else
    T:arm("ARM 6: a usable baseline copy", false, "mutation did not apply")
end

-- ARM 7
T:arm("ARM 7: --parse-only states its scope and names the corpus-wide gate by path",
    text.contains(o5 .. e5, "check-litmus-yaml-parses.lua") and text.contains((o5 .. e5):upper(), "FILES NAMED"),
    last(o5 .. e5))

-- ARM 8
put("merged.yaml", table.concat({ "name: " .. LIT .. ":cbk7-merged", "spec: spec-traceability",
    "phase: pre-build", "severity: high", "size: instant", "description: >", "  merged-item probe",
    "critical_path:", '  - step: "first item"', '    command: "echo one"', "    timeout_ms: 3000",
    '    expected_behavior: "one"', '  - name: "second item, opened by the WRONG key"',
    '    command: "echo two"', "    timeout_ms: 3000", '    expected_behavior: "two"', "" }, "\n"))
local rc_merged = yaml_rc(TMP .. "/merged.yaml")
local _, o8, e8 = run_runner(RUNNER, { "--parse-only", TMP .. "/merged.yaml" })
if rc_merged ~= 0 then
    T:arm("ARM 8: premise — the loader accepts the merged-item probe", false, "rc=" .. tostring(rc_merged))
else
    T:arm("ARM 8: a merged '- name:' item is NOT reported as a duplicated key",
        not text.contains(o8 .. e8, "duplicated mapping key"), "FALSE POSITIVE: " .. last(o8 .. e8))
end

-- ARM 9: the SAME comparator ARM 6 uses.
local sa, sb = { "a.yaml", "b.yaml" }, { "a.yaml", "c.yaml" }
T:arm("ARM 9: equal-count/different-filenames control is rejected by the corpus comparator",
    #sa == #sb and same_set(sa, sa) and not same_set(sa, sb), "comparator accepted a substitution")

-- ARMS 10-15: the mode boundary.
put("bindings.yaml", "version: '1.0'\nspecs:\n- spec_id: spec-traceability\n  status: active\n  "
    .. LIT .. "_tests:\n  - " .. LIT .. ":cbk7-probe\n")
local NORMAL_ENV = { TILLANDSIAS_LITMUS_BINDINGS = TMP .. "/bindings.yaml", TILLANDSIAS_LITMUS_TESTS_DIR = TMP .. "/tests" }
local function normal_probe(extra)
    local e = {}
    for k, v in pairs(NORMAL_ENV) do e[k] = v end
    for k, v in pairs(extra or {}) do e[k] = v end
    local rc, o, er = run_runner(RUNNER, { "--test", LIT .. ":cbk7-probe", "--phase", "pre-build", "--size", "instant", "--compact" }, e)
    return rc, o .. er
end
local PROBE_REL = "tests/" .. LIT .. "-cbk7-probe.yaml"
local PROBE = TMP .. "/" .. PROBE_REL
local PARSED = OK_PARSEABLE .. ":" .. PROBE .. ":1 step(s)"
put(PROBE_REL, probe_text('    assert_output_contains: "hello"') .. "rust_queries:\n  - id: fixture.rust.query@v1\n"
    .. "    spec: spec-traceability\n    processor: syn\n    file: fixture.rs\n    method: harmless\n    required: true\n")
rm_markers()
local yrc = yaml_rc(PROBE)
local prc, po, pe = run_runner(RUNNER, { "--parse-only", PROBE })
T:arm("ARM 10: Rust-query file parses without invoking the refusing helper",
    yrc == 0 and prc == 0 and text.contains(po .. pe, PARSED) and not exists(TMP .. "/markers/tillandsias-litmus-rust"),
    "yaml=" .. tostring(yrc) .. " parse=" .. tostring(prc) .. " " .. last(po .. pe))
rm_markers()
local nrc, no = normal_probe()
T:arm("ARM 11: normal execution still invokes and refuses the Rust-query helper",
    nrc ~= 0 and nonempty(TMP .. "/markers/tillandsias-litmus-rust")
        and text.contains(no, "refused:fixture-sentinel:tillandsias-litmus-rust:73"), "rc=" .. tostring(nrc))

local podman_probe = probe_text('    assert_output_contains: "hello"'):gsub('command: "echo hello"', 'command: "podman ps"')
put(PROBE_REL, podman_probe)
rm_markers()
prc, po, pe = run_runner(RUNNER, { "--parse-only", PROBE })
T:arm("ARM 12: Podman-shaped input parses without invoking the environmental probe",
    prc == 0 and text.contains(po .. pe, PARSED) and not exists(TMP .. "/markers/podman"), "rc=" .. tostring(prc))
if (T:run{ "uname", "-s" }.stdout or ""):match("^Linux") then
    rm_markers()
    nrc, no = normal_probe()
    T:arm("ARM 13: normal execution still invokes and refuses the Podman preflight",
        nrc ~= 0 and nonempty(TMP .. "/markers/podman") and text.contains(no, "[ENV-FAIL]")
            and text.contains(no, "refused:fixture-sentinel:podman:73"), "rc=" .. tostring(nrc))
else
    out.line("skip:ARM-13:Podman-preflight-is-Linux-only")
end

put(PROBE_REL, podman_probe .. "backend: fake\n")
local erc, eo, ee = run_runner(RUNNER, { "--parse-only", PROBE }, { CONTAINER_HOST = "fixture://no-runtime" })
local enr, eno = normal_probe{ CONTAINER_HOST = "fixture://no-runtime" }
T:arm("ARM 14: the remote/fake environment check is execution-only and still refuses normal mode",
    erc == 0 and text.contains(eo .. ee, PARSED) and enr ~= 0
        and text.contains(eno, "refused:litmus-gate:fake-backend-under-remote-podman"),
    "parse=" .. tostring(erc) .. " normal=" .. tostring(enr))
local escaped = {}
for _, tool in ipairs{ "cargo", "rustup", "toolbox", "docker" } do
    if exists(TMP .. "/markers/" .. tool) then escaped[#escaped + 1] = tool end
end
T:arm("ARM 15: no Cargo fallback, tool provisioning or container launch attempted",
    #escaped == 0, table.concat(escaped, ","))

T:finish()

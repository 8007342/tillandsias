-- @trace order:1464-v3xq, order:2399-lrg3, spec:spec-traceability
-- @env PATH HOME
--
-- test-litmus-podman-preflight-trigger.lua — the litmus runner's podman preflight fires when
-- a step INVOKES podman, not when a step's text mentions the word. Ported from
-- test-litmus-podman-preflight-trigger.sh (2399-lrg3); same arms, in its order.
--
--   3  the helper (_lt_command_invokes_podman, cut from the real runner) answers a table of
--      shapes: command position, after ; && | $( (, wrappers, VAR=value prefixes, absolute
--      paths, require_podman, a quoted -c script — yes; quoted prose, grep patterns, crate
--      names, echo text, `command -v`, `vm-exec -- podman` (the VM's podman) — no
--   1  (Linux) under a FAILING fake podman first on PATH, a test whose only podman mentions are
--      prose runs and passes
--   2  (Linux) a test that invokes podman in command position, or inside `bash -lc '...'`,
--      still ENV-FAILs naming podman
-- The preflight is Linux-only by design; elsewhere arms 1-2 are one named skip and arm 3 runs.
--
-- Hermetic: the only podman a child can reach is the scratch fake (first on PATH, and named
-- as TILLANDSIAS_REAL_PODMAN); CONTAINER_HOST and TILLANDSIAS_PODMAN_* are stripped. The
-- table's strings are classifier DATA, never executed. The probe's name is composed, never
-- a literal litmus-name token (the 721-77yu pin checker).
--
-- GRAMMAR ok:litmus-podman-preflight-trigger:<n> arms[ skipped=1]
--       | violation:litmus-podman-preflight-trigger:<n>-failed

local fixture = require "common.fixture"
local T = fixture.new("litmus-podman-preflight-trigger")
local ROOT = fixture.repo_root()
local SH = fixture.posix_shell()
local W = T:scratch()
local skipped = 0

-- ── 3: the helper, over a table ─────────────────────────────────────────────
local YES = {
    [["podman ps"]],
    [["set -e; podman info >/dev/null && echo ok"]],
    [["x=$(podman images -q | head -1); test -n \"$x\""]],
    [["true && /usr/bin/podman run --rm x"]],
    [["timeout 5 podman ps"]],
    [["DOCKER_HOST=unix:///x.sock podman info"]],
    [["out=$(systemd-run --user --wait --pipe -p NoNewPrivileges=yes --setenv=CONTAINER_HOST=unix://x podman info --format x)"]],
    [["bash -lc 'FORGE_IMG=$(podman images --format x | head -1) && podman run --rm $FORGE_IMG true'"]],
    [['b="${XDG_RUNTIME_DIR}/x"; podman rm -f $(podman ps -a -q) 2>/dev/null || true']],
    [["bash -c 'source scripts/common.sh && require_podman && echo ok'"]],
}
local NO = {
    [["PB=x; printf '%s' 'query: how do I run podman rootless' > f; echo ok"]],
    [["grep -F 'podman build' scripts/build-image.sh"]],
    [["grep -F \"exec podman run\" run-forge-standalone.sh"]],
    [["cargo test -p tillandsias-podman launch::tests::x"]],
    [["if x; then echo 'FAIL: a GPU podman cannot deliver'; fi"]],
    [["bash -c 'b=$(command -v podman || true); test -n \"$b\"'"]],
    [["bash -lc 'cargo run --example vm-exec -- podman ps'"]],
}
-- One harness call: load the helper exactly as the .sh did (sed range from the runner), then
-- answer yes/no for each case file in argv order.
fs.write(W.rel .. "/harness.sh", table.concat({
    [[eval "$(sed -n '/^_lt_command_invokes_podman() {/,/^}/p' "$1")"]],
    [[declare -F _lt_command_invokes_podman >/dev/null || { echo NO-HELPER; exit 3; }]],
    [[shift]],
    [[for f in "$@"; do if _lt_command_invokes_podman "$f"; then echo yes; else echo no; fi; done]], "" }, "\n"))
local cases, argv = {}, { SH, W.abs .. "/harness.sh", ROOT .. "/scripts/run-litmus-test.sh" }
for _, c in ipairs(YES) do cases[#cases + 1] = { c, "yes" } end
for _, c in ipairs(NO) do cases[#cases + 1] = { c, "no" } end
for i, c in ipairs(cases) do
    fs.write(W.rel .. "/case-" .. i .. ".yaml", "    command: " .. c[1] .. "\n")
    argv[#argv + 1] = W.abs .. "/case-" .. i .. ".yaml"
end
argv.cwd, argv.env_unset, argv.timeout_ms = ROOT, { "TILLANDSIAS_*", "CONTAINER_HOST" }, 30000
local r = T:run(argv)
local got = text.lines(text.trim(r.stdout or ""))
if got[1] == "NO-HELPER" then
    T:arm("arm 3: _lt_command_invokes_podman is defined in run-litmus-test.sh", false, "not defined")
else
    local wrong, ny, nn = {}, 0, 0
    for i, c in ipairs(cases) do
        if got[i] == c[2] then
            if c[2] == "yes" then ny = ny + 1 else nn = nn + 1 end
        else
            wrong[#wrong + 1] = "[" .. c[1] .. "] -> " .. tostring(got[i]) .. ", want " .. c[2]
        end
    end
    T:arm("arm 3: the helper answers " .. #YES .. " invocation shapes yes and " .. #NO .. " prose shapes no",
        #wrong == 0, table.concat(wrong, "; "))
end

-- ── 1 and 2: through the runner ─────────────────────────────────────────────
local os_name = text.trim(T:run{ "uname", "-s" }.stdout or "")
if os_name ~= "Linux" then
    skipped = 1
    out.line("skip: arms 1-2: the podman preflight is Linux-only by design (run-litmus-test.sh)")
else
    fs.mkdir(W.rel .. "/bin"); fs.mkdir(W.rel .. "/lt")
    fs.write(W.rel .. "/bin/podman", '#!/bin/sh\necho "fake podman: storage is broken" >&2\nexit 1\n')
    T:must{ "chmod", "+x", W.abs .. "/bin/podman" }
    local LIT = "litmus"
    fs.write(W.rel .. "/bindings.yaml", table.concat({
        "version: '1.0'", "description: fixture for 1464-v3xq", "specs:", "- spec_id: spec-traceability",
        "  status: active", "  " .. LIT .. "_tests:", "  - " .. LIT .. ":v3xq-probe", "  coverage_ratio: 100",
        "  last_verified: '2026-09-28'", "" }, "\n"))
    local function probe(cmd)
        fs.write(W.rel .. "/lt/" .. LIT .. "-v3xq-probe.yaml", table.concat({
            "name: " .. LIT .. ":v3xq-probe", "spec: spec-traceability", "phase: pre-build", "severity: high",
            "size: instant", "description: >", "  probe for 1464-v3xq", "critical_path:", '  - step: "probe"',
            '    command: "' .. cmd .. '"', "    timeout_ms: 20000", '    expected_behavior: "probe-done"', "" }, "\n"))
        local p = T:run{ SH, "scripts/run-litmus-test.sh", "spec-traceability", "--phase", "pre-build", "--size", "instant",
            cwd = ROOT, stdin = "", timeout_ms = 120000,
            env_unset = { "TILLANDSIAS_*", "CONTAINER_HOST", "PROJECT_ROOT" },
            env = { PATH = W.abs .. "/bin:" .. (env.get("PATH") or ""), TILLANDSIAS_REAL_PODMAN = W.abs .. "/bin/podman",
                TILLANDSIAS_LITMUS_BINDINGS = W.abs .. "/bindings.yaml", TILLANDSIAS_LITMUS_TESTS_DIR = W.abs .. "/lt" } }
        return (((p.stdout or "") .. (p.stderr or "")):gsub("\27%[[0-9;]*m", ""))
    end
    local function lines_with(s, words)
        local k = {}
        for _, l in ipairs(text.lines(s)) do
            for _, w in ipairs(words) do if text.contains(l, w) and #k < 3 then k[#k + 1] = l; break end end
        end
        return table.concat(k, " | ")
    end
    local o = probe([[printf '%s\\\\n' 'query: how do I run podman rootless' > /dev/null; command -v podman >/dev/null || true; echo 'grep pattern: exec podman run' >/dev/null; echo probe-done]])
    T:arm("arm 1: a test that only MENTIONS podman (a quoted question, command -v, an echoed pattern) runs and passes",
        text.contains(o, "Status: [PASS]") and not text.contains(o, "ENV-FAIL"), lines_with(o, { "ENV-FAIL", "Status", "FAIL" }))
    local function env_failed(s)
        for _, l in ipairs(text.lines(s)) do
            local a = l:find("[ENV-FAIL]", 1, true)
            if a and l:find("podman ps", a, true) then return true end
        end
        return false
    end
    o = probe("podman ps >/dev/null 2>&1; echo probe-done")
    T:arm("arm 2: a test that invokes podman in command position still ENV-FAILs naming podman", env_failed(o),
        lines_with(o, { "ENV-FAIL", "Status" }))
    o = probe("bash -lc 'podman images -q >/dev/null'; echo probe-done")
    T:arm("arm 2: podman inside a quoted bash -lc script still ENV-FAILs", env_failed(o), lines_with(o, { "ENV-FAIL", "Status" }))
end

if skipped > 0 and #T.failed == 0 then
    T:finish{ ok = function(n) return "ok:litmus-podman-preflight-trigger:" .. n .. " arms skipped=" .. skipped end }
end
T:finish()

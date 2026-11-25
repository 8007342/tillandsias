-- @trace order:2231-zmzd, spec:ci-release
--
-- local-ci-landed-guards.lua — local-ci.sh to Lua, slice 5 (2231-zmzd): the
-- roster of the "Recently Landed Guards" section. It was 18 copies of one
-- bash skeleton in about 380 lines; each row below is one of them, and
-- run_landed_guards in local-ci.sh runs the rows in this order.
--
-- Why each guard is wired here, and what it pins, is recorded with its order;
-- the comments that sat on the bash copies are kept as the `why` of each row.
--
-- Run as a HELPER (`script run --helper`): stdout is one row per guard, the
-- fields separated by the ASCII unit separator (0x1f), in this order:
--   id kind runtime path args log pass_msg fail_msg missing_detail
-- kind      gate    rc decides pass or fail
--           report  always passes (informational; its rc is ignored)
-- runtime   bash    run as `bash <path> <args>`
--           lua     run as `<runner> script run <path> -- <args>`
-- args      space-separated, `-` for none
-- missing_detail is what log_fail_missing_guard names when <path> is absent.

local US = "\31"

local function gate(id, path, log, pass_msg, fail_what, why)
    return { id = id, kind = "gate", runtime = "bash", path = path, args = "-", log = log,
        pass_msg = pass_msg, fail_msg = fail_what .. " (see " .. log .. ")",
        missing_detail = path, why = why }
end

local ROSTER = {
    { id = "tray-string-corpus-drift", kind = "report", runtime = "lua",
        path = "scripts/lua/check-tray-string-corpus-drift.lua", args = "-",
        log = "/tmp/tray-string-corpus-drift.log",
        pass_msg = "Tray string-corpus drift reported (792-77bt, informational)", fail_msg = "-",
        missing_detail = "scripts/lua/check-tray-string-corpus-drift.lua (or no runnable tillandsias-plan)",
        why = "792-77bt (windows lane). A report: prints the tray string-corpus drift ratio and exits 0 whatever it is; ported to Lua in 2094-ay52." },
    { id = "deslop-sweep-health", kind = "report", runtime = "bash",
        path = "scripts/check-deslop-sweep-health.sh", args = "-",
        log = "/tmp/deslop-sweep-health.log",
        pass_msg = "De-slop sweep health reported (829-dkuc, informational)", fail_msg = "-",
        missing_detail = "scripts/check-deslop-sweep-health.sh",
        why = "829-dkuc: the de-slop sweep's ritual detector. A report: prints ok:/unknown:/red: and exits 0 either way." },
    { id = "cheatsheet-frontmatter", kind = "gate", runtime = "lua",
        path = "scripts/lua/check-cheatsheet-frontmatter.lua", args = "-",
        log = "/tmp/cheatsheet-frontmatter.log",
        pass_msg = "Cheatsheet frontmatter valid",
        fail_msg = "Cheatsheet frontmatter violations (see /tmp/cheatsheet-frontmatter.log)",
        missing_detail = "scripts/lua/check-cheatsheet-frontmatter.lua (or no runnable tillandsias-plan)",
        why = "1572-nqx5: ported to Lua. No runnable plan binary is a missing guard, not a pass." },
    { id = "dev-embed-model-agreement", kind = "gate", runtime = "lua",
        path = "scripts/lua/source-agreements.lua",
        args = "dev_embed_model_agreement images/default/config-overlay/mcp/lib-dev-env.sh scripts/dev-inference-ensure.sh",
        log = "/tmp/dev-embed-model-agreement.log",
        pass_msg = "Dev embed model agrees across surfaces",
        fail_msg = "Dev embed model disagreement (see /tmp/dev-embed-model-agreement.log)",
        missing_detail = "scripts/lua/source-agreements.lua",
        why = "The dev embed model must agree across the MCP env library and the inference ensurer." },
    gate("spec-index-resolution-agreement", "scripts/check-spec-index-resolution-agreement.sh",
        "/tmp/spec-index-resolution-agreement.log",
        "Spec-index resolution agrees across producer and readers", "Spec-index resolution drift",
        "801-a2by: the spec-index producer and its two readers resolve the durable root in two runtimes; a disagreement is silent by construction."),
    { id = "spec-index-repo-relative-rung", kind = "gate", runtime = "lua",
        path = "scripts/lua/test-spec-index-repo-relative-rung.lua", args = "-",
        log = "/tmp/spec-index-repo-relative-rung.log",
        pass_msg = "Spec-index repo-relative rung fixes Windows without moving other hosts",
        fail_msg = "Spec-index repo-relative rung regression (see /tmp/spec-index-repo-relative-rung.log)",
        missing_detail = "scripts/lua/test-spec-index-repo-relative-rung.lua (or no runnable tillandsias-plan)",
        why = "931-p26p: rung 4 must fix Windows without relocating a working index on Linux or macOS; three arms are negative controls. Ported to Lua in 2348-psb6." },
    gate("spec-index-durable-tier-demotion", "scripts/test-spec-index-durable-tier-demotion.sh",
        "/tmp/spec-index-durable-tier-demotion.log",
        "Spec-index durable tier: not-permitted is distinguishable from absent, and rung 4 is not target/",
        "Spec-index durable-tier demotion regression",
        "1003-v3dc: EACCES on a rootless podman mountpoint read as absent demoted the index into a cargo-clean target (lenovinha, 2026-09-04)."),
    { id = "litmus-grep-escapes", kind = "gate", runtime = "lua",
        path = "scripts/lua/test-litmus-grep-escapes.lua", args = "-", log = "/tmp/litmus-grep-escapes.log",
        pass_msg = "Litmus grep patterns use escapes GNU grep actually defines",
        fail_msg = "Litmus grep-escape regression (see /tmp/litmus-grep-escapes.log)",
        missing_detail = "scripts/lua/test-litmus-grep-escapes.lua (or no plan binary)",
        why = "901-jtvi: GNU grep ERE has no \\t; an interactive ugrep function hid it on three hosts." },
    gate("litmus-runner-reports-rc", "scripts/test-litmus-runner-reports-rc.sh", "/tmp/litmus-runner-rc.log",
        "Litmus runner reports the step exit status on every [FAIL]", "Litmus runner rc-reporting regression",
        "1018-5f5a: a [FAIL] without its rc was read as a SIGPIPE 141 across three hosts."),
    gate("litmus-budget-tally", "scripts/test-litmus-budget-tally.sh", "/tmp/litmus-budget-tally.log",
        "Litmus runner tallies a budget kill apart from a failed assertion", "Litmus BUDGET tally regression",
        "1187-iij8 arm (a), bound because it was an orphan (1205-aipn); 820-c8q8: a budget kill still FAILS."),
    gate("unrunnable-platform-arms", "scripts/test-unrunnable-platform-arms.sh", "/tmp/unrunnable-platform-arms.log",
        "Cross-platform gate-arm advisory names arms this host cannot run", "Cross-platform arm advisory regression",
        "1194-davi: the advisory runs on the land path; its fixture runs here."),
    gate("must-ship-rows", "scripts/test-must-ship-rows.sh", "/tmp/must-ship-rows.log",
        "Must-ship-next release advisory names rows absent from the cut", "Must-ship advisory regression",
        "1218-25z3: the advisory runs on the release path; its fixture runs here."),
    -- Both ported to Lua on trunk while this roster was in flight; the roster
    -- follows the port (merge of 2026-11-23).
    { id = "unstable-installer-default", kind = "gate", runtime = "lua",
        path = "scripts/lua/test-unstable-installer-defaults-to-unstable.lua", args = "-",
        log = "/tmp/unstable-installer-default.log",
        pass_msg = "Unstable-channel installers default to unstable; stable copies do not",
        fail_msg = "Unstable installer default regression (see /tmp/unstable-installer-default.log)",
        missing_detail = "scripts/lua/test-unstable-installer-defaults-to-unstable.lua (or no plan binary)",
        why = "1369-sjbc: the copy uploaded to unstable defaults its installers to unstable; also in build.sh --check." },
    { id = "pending-banner", kind = "gate", runtime = "lua",
        path = "scripts/lua/test-installers-print-pending-banner.lua", args = "-",
        log = "/tmp/pending-banner.log",
        pass_msg = "Installers end with a PENDING ACTIONS banner",
        fail_msg = "Pending-actions banner regression (see /tmp/pending-banner.log)",
        missing_detail = "scripts/lua/test-installers-print-pending-banner.lua (or no plan binary)",
        why = "1380-zmpi: every installer ends with a PENDING ACTIONS banner; also in build.sh --check." },
    gate("gate-stamp-movers", "scripts/test-gate-stamp-names-content-movers.sh", "/tmp/gate-stamp-movers.log",
        "Stale-stamp refusal names content movers, not mtime movers", "Stale-stamp content-mover regression",
        "970-7fqk: a stale-stamp refusal names content movers, not mtime movers."),
    { id = "expect-none-fixture-only", kind = "gate", runtime = "lua",
        path = "scripts/lua/check-enclave-expect-none-is-fixture-only.lua", args = "-",
        log = "/tmp/expect-none-fixture-only.log",
        pass_msg = "The enclave health check's absent-detection opt-out stays fixture-only",
        fail_msg = "A production caller passes the expect-none opt-out (see /tmp/expect-none-fixture-only.log)",
        missing_detail = "scripts/lua/check-enclave-expect-none-is-fixture-only.lua",
        why = "1004-inkc: the expect-none opt-out disables absent detection; confined to the fixture, and the confinement is checked (Lua since 1616-njfd)." },
    { id = "gate-fast-refusals", kind = "gate", runtime = "lua",
        path = "scripts/lua/test-gate-fast-refusals.lua", args = "-",
        log = "/tmp/gate-fast-refusals.log",
        pass_msg = "The gate's sub-second deciders run before its first compile",
        fail_msg = "Gate fast-refusal ordering regression (see /tmp/gate-fast-refusals.log)",
        missing_detail = "scripts/lua/test-gate-fast-refusals.lua (or no plan binary)",
        why = "1009-gccx: the gate's cheap deciders stay ahead of its compiles; the fixture pins the ORDER (Lua since 2342-9f4k)." },
    { id = "litmus-dead-inputs", kind = "gate", runtime = "lua",
        path = "scripts/lua/check-litmus-dead-inputs.lua", args = "-",
        log = "/tmp/litmus-dead-inputs.log",
        pass_msg = "Every litmus inputs: glob resolves to a tracked file",
        fail_msg = "Dead litmus inputs glob (see /tmp/litmus-dead-inputs.log)",
        missing_detail = "scripts/lua/check-litmus-dead-inputs.lua",
        why = "765-mza8: a dead inputs: glob is silent by construction; it can only skip a test (Lua since 1643-q3at)." },
}

local FIELDS = { "id", "kind", "runtime", "path", "args", "log", "pass_msg", "fail_msg",
    "missing_detail" }
for _, row in ipairs(ROSTER) do
    local cells = {}
    for i, f in ipairs(FIELDS) do cells[i] = row[f] end
    out.line(table.concat(cells, US))
end

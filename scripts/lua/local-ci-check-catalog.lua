-- @trace order:2223-bzsn, spec:ci-release
--
-- local-ci-check-catalog.lua — local-ci.sh to Lua, slice 3 (2223-bzsn): the
-- check catalog. One table replaces three parallel bash case tables
-- (check_weight, check_spec_ref, failed_reason_for_check) that were keyed by
-- the same check ids and had to be edited in step.
--
-- Run as a HELPER (`script run --helper`): stdout is one row per check,
--   <id> TAB <weight> TAB <spec ref> TAB <failure reason>
-- in catalog order, then the default row for an id the catalog does not
-- name, whose id is `*` and whose reason carries `%s` where the id goes.
-- The convergence writer (local-ci-convergence-artifacts.lua, 2224-x32n)
-- reads the rows and looks ids up in them.

local CATALOG = {
    { "spec-cheatsheet-binding", 100, "spec:spec-traceability", "Spec-cheatsheet binding below 90% (see /tmp/binding-check.log)" },
    { "spec-code-drift", 120, "spec:spec-traceability", "Spec-code drift detected: ghost traces or zero-trace specs found (see /tmp/drift-check.log)" },
    { "spec-trace-coverage", 90, "spec:methodology-accountability", "Spec trace coverage below 90% (see /tmp/trace-coverage.log)" },
    { "version-monotonicity", 40, "spec:versioning", "Version is not monotonically greater than last release (see /tmp/version-check.log)" },
    { "rust-formatting", 40, "spec:dev-build", "Rust code not formatted: run 'cargo fmt --all' (see /tmp/fmt-check.log)" },
    { "rust-clippy", 60, "spec:dev-build", "Clippy warnings found: run 'cargo clippy --workspace' to see details (see /tmp/clippy-check.log)" },
    { "rust-clippy-all-features", 180, "spec:dev-build", "All-features clippy warnings: run 'cargo clippy --workspace --all-targets --all-features -- -D warnings' (see /tmp/clippy-all-features-check.log)" },
    { "rust-tests", 80, "spec:testing", "Test failures detected: run 'cargo test --workspace --lib --no-fail-fast' to see details (see /tmp/test-check.log)" },
    { "container-base-policy", 40, "spec:default-image", "Container base-image policy drift found (see /tmp/container-bases.log)" },
    { "cheatsheet-tiers", 80, "spec:cheatsheet-source-layer", "Cheatsheet tier errors or strict warnings found (see /tmp/cheatsheet-tiers.log)" },
    { "no-python-scripts", 30, "methodology.yaml tlatoani_hard_no_python", "Python scripts found in tracked files (see /tmp/no-python-check.log)" },
    { "no-base64-script-injection", 30, "methodology.yaml base64_script_injection_ban", "Base64 script injection detected (see /tmp/no-base64-script-injection.log)" },
    { "litmus-pre-build", 100, "spec:podman-orchestration", "Pre-build litmus failures detected (see /tmp/litmus-pre-build.log)" },
    { "litmus-post-build", 120, "spec:dev-build", "Post-build smoke failures detected (see /tmp/litmus-post-build.log)" },
    { "litmus-runtime", 140, "spec:litmus-convergence", "Runtime litmus failures detected (see /tmp/litmus-runtime.log)" },
    { "litmus-tests", 140, "spec:litmus-convergence", "Litmus test failures detected (see /tmp/litmus-check.log)" },
}

for _, c in ipairs(CATALOG) do
    out.line(c[1] .. "\t" .. tostring(c[2]) .. "\t" .. c[3] .. "\t" .. c[4])
end
out.line("*\t0\tspec:unknown\tCheck failed: %s")

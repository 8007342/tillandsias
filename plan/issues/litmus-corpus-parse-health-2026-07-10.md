# Litmus corpus parse health — folded commands, patternless steps, YAML-invalid files

- **Filed**: 2026-07-10T02:50Z
- **Agent**: linux-macuahuitl-fable5-20260710T0009Z (order 256 slice-1 audit)
- **Classification**: enhancement (litmus infrastructure)
- **Status**: open — remediation promoted to plan/index.yaml order 267
- **Related**: order 256 (runner exit-code/diagnostics slice, done), orders
  224/225 (litmus command DSL — the durable fix for this class), order 263
  (mirror YAML gate — will reject edits to the YAML-invalid files below)

## Audit method (reproducible)

```bash
ruby -ryaml -e '
folded = []; patternless = []
Dir["openspec/litmus-tests/*.yaml"].sort.each do |f|
  begin; y = YAML.load_file(f); rescue => e; puts "PARSE-BROKEN: #{f}"; next; end
  (y["critical_path"] || []).each do |s|
    next unless s.is_a?(Hash)
    folded << "#{f} :: #{s["step"]}" if s["command"].is_a?(String) && s["command"].include?("\n")
    patternless << "#{f} :: #{s["step"]}" if !s.key?("expected_behavior") && !s.key?("success_pattern")
  end
end
puts folded; puts "patternless: #{patternless.size}"'
```

## Findings (2026-07-10 snapshot)

### A. 31 folded/multi-line `command:` steps across 8 files — SKIPPED since authoring

The bash runner only extracts single-line double-quoted `command:` scalars;
folded (`>`/`>-`) values were silently dropped, so these files ran with
thinner coverage than authored (or zero steps → generic fail). As of order
256 slice 1 the runner emits a loud `[PARSE WARNING]` per affected step;
promotion to a hard per-step FAIL waits for the rewrites (order 267).

| File | folded steps |
|---|---|
| litmus-podman-idiomatic-storage-isolation-runtime.yaml | 11 |
| litmus-podman-idiomatic-event-driven.yaml | 9 |
| litmus-tray-network-bootstrap.yaml | 5 |
| litmus-browser-isolation-e2e.yaml | 2 |
| litmus-init-command-shape.yaml | 1 |
| litmus-integration-strategy-consistency.yaml | 1 |
| litmus-nix-cache-size-signal.yaml | 1 |
| litmus-no-raw-error-in-status-chip.yaml (windows-owned scope — coordinate) | 1 |

### B. 4 litmus files are not valid YAML at all (Psych rejects)

- litmus-binary-e2e-smoke.yaml
- litmus-environment-isolation.yaml
- litmus-inference-deferred-model-pulls.yaml
- litmus-log-field-stability-schema.yaml

The regex-based runner tolerates them today, but `tillandsias-policy
validate-yaml`, the ruby fallback, AND the order-263 git-mirror pre-receive
gate all reject them — the first agent to EDIT one of these files will have
its push refused until the file is repaired. Repair proactively.

### C. 164 patternless steps (no expected_behavior, no success_pattern)

Before order 256 these were dead checks: only timeout could fail them; a
non-zero exit passed silently. Runner slice 1 makes the exit code
authoritative for exactly this class, so they are now LIVE checks — no
rewrite needed, but any that start failing were failing invisibly before
(treat as real findings, not regressions). Count by the audit one-liner;
mostly `cargo test …` wrappers.

## Remediation (order 267)

1. Rewrite the 31 folded steps as single-line double-quoted scalars (or
   extract helper scripts under scripts/ where a one-liner is unreadable —
   preferred for the 9-step podman-event and 11-step storage-isolation
   files). Coordinate the windows-owned chip litmus with the windows
   terminal per sibling-scope discipline.
2. Repair the 4 YAML-invalid files (they also block the order-263 gate on
   next edit).
3. Promote the runner's `[PARSE WARNING]` to a hard per-step parse FAIL
   (flip documented at the warning site in run-litmus-test.sh).
4. Re-run the full suite matrix; zero warnings, zero parse errors.

## Strict-mode dry run results (2026-07-10T02:55Z — order 267's burn-down list)

Full pre-build suite with exit-code authority unconditionally ON
(evidence: scratchpad prebuild-suite-strict.log of session
20260710T0009Z; reproduce with TILLANDSIAS_LITMUS_STRICT_EXIT=1):

Newly-red litmuses (were passing as dead checks):

1. litmus:clickable-trace-index-observatorium-skeleton — STEP 1 "launch
   observatorium" exit 1 (patternless).
2. litmus:headless-init-status-check-source-built — PARSE WARNING (bash
   parser could not extract at least one command — file is ruby-valid, so
   the bash/ruby parse gap is BROADER than folded scalars: quote-style
   variants) + STEP 2 exit 2 cascade.
3. litmus:host-browser-mcp-frame-shape — STEP 1 has an EMPTY name and
   exits 127: the parser mis-associates lines and executes a fragment
   ("command not found"). Structural mis-parse class.
4. litmus:runtime-diagnostics-typed-events-shape — same empty-name exit
   127 class.
5. litmus:diagnostics-envelope-shape — same empty-name exit 127 class.
6. litmus:init-command-shape — STEP 3 exit 1 (also carries 1 folded step).
7. litmus:podman-build-command-shape — STEP 4 "human aliases refreshed"
   exit 1.
8. litmus:spec-traceability-shape — STEP 2 exit 1.
9. litmus:guest-binary-embed-integrity — pattern-based fail, standalone
   context only (guest binaries are staged by --ci-full's prepare step;
   not a strict-exit casualty; verify it stays green inside the gate).

Runner state after order 256 slice 1: strict mode exists behind
TILLANDSIAS_LITMUS_STRICT_EXIT=1 (default off); legacy mode passes these
but prints [DEAD-CHECK WARNING] per occurrence; folded/unparsed steps
print [PARSE WARNING]; zero-step files fail with a named parse error.
Order 267 owns: repairing items 1-8, the 31 folded rewrites, the 4
YAML-invalid files, then flipping strict-exit default on and promoting
parse warnings to per-step FAIL.

## Order-268 forensics: the exact rewrite recipe for litmus-inference-deferred-model-pulls.yaml

The 2026-07-10 gate red was three stacked shape divergences, all in the
LITMUS's launch command, none in the product launch (which uses
`--userns=keep-id --security-opt=label=disable` on the enclave network,
main.rs:2032-2094):

1. `--userns=host` + no `label=disable`: SELinux (Enforcing) denies BOTH
   traversal of the enclave-written cache and writes into the mounted
   cache — the entrypoint's `install` into `.tools/ollama` fails silently.
2. No `--network`: the image's baked `HTTP(S)_PROXY=http://proxy:3128`
   cannot resolve → `curl: (5)` before touching the wire (fixed
   product-side by the order-268 proxy-resolvability guard, but the litmus
   should still launch product-shaped).
3. `success_pattern: "Pulling T0|T1 ready"` pins a pre-order-168
   entrypoint revision; the current strings are
   `pulling default model <tag> (first run)...` /
   `default model <tag> ready` / `ready (cached)`.

Rewrite recipe: single-line commands; launch shape
`podman run --userns=keep-id --security-opt=label=disable --rm -e
TILLANDSIAS_INFERENCE_SKIP_RUNTIME_PULLS=1 -v <cache>:/home/ollama/.ollama/models:rw`;
assert the order-268 guard line (`does not resolve — running direct`) in
the bare shape, then `default model .* ready`; generous timeout (the
tarball is 1.34 GiB — 600s curl cap product-side). Also: main.rs's
`/usr/bin/ollama serve` trailing args to this container are DEAD (the
entrypoint ignores "$@"; no /usr/bin/ollama exists in the image) — remove
them in a separate hygiene commit when touching that launch path.

## environment-isolation STEP 2 flake observation (gate run 20260710T062934Z)

`litmus:environment-isolation` (one of the four YAML-invalid files above)
failed STEP 2 "execute forge container and count env vars" with EMPTY
output inside its 5s timeout — green in the same night's earlier gate
(021654Z) and no code path from the intervening diffs (macOS vz/ssh
masking, WSL unit env pin, headless push topics) touches forge env
construction. Suspected cold-start/exec timing flake; the 5s budget and
the exec-target coupling to STEP 1's container need review during this
file's YAML repair. If a subsequent gate reds the same step, promote to
its own bug packet instead of retrying.

## Slice progress 2026-07-10T07:0xZ + the fake-podman shim finding

- **litmus-environment-isolation.yaml REWRITTEN** (valid YAML, explicit
  fail-loud verdicts, 30-60s timeouts, image pre-warm step) — the 5s
  cold-start flake class is closed for this file.
- **litmus-inference-deferred-model-pulls.yaml PARKED with a new finding**:
  the failing `--userns=host` launch shape is NOT in the litmus file — the
  runner exports a PATH shim (run-litmus-test.sh:79-133) routing every
  litmus `podman` call through `scripts/tillandsias-podman raw`, whose
  profile injects `--userns=host` and no `label=disable`. Under SELinux
  Enforcing the binary install into the mounted cache is denied. Fix
  options for the rewrite slice: (a) expose REAL_PODMAN_BIN to steps for
  product-shape launches; (b) let `tillandsias-podman raw` accept
  label/userns overrides; (c) PREFERRED per the order-271 doctrine — drive
  the launch through the product ensure_inference path instead of raw
  podman, making the litmus test the real layer. Also fix while there: the
  TILMANDSIAS_ env-var typo in the cached-run step and the pre-order-168
  success strings ("Pulling T0|T1 ready" → "default model .* ready" /
  "ready (cached)").

## Parser-anchor change parked (gate-4 orphan triage, 2026-07-10T08:1xZ)

The gate-4 in-forge agent's `^[[:space:]]*command:` anchor in
run-litmus-test.sh is correct in intent (stops mid-string/rollback
`command:` matches — the empty-step-name exit-127 class) but re-pairs
steps/expecteds in files still carrying folded commands
(litmus:tray-network-bootstrap STEP 1 fails while printing its ok line).
REVERTED for now; re-apply in the same commit as the remaining folded
rewrites (or make step/expected pairing robust first). The agent's three
sibling fixes (podman-build alias grep to "$PODMAN", spec-traceability
doc path, entrypoint-test stubs) were verified strict-green and adopted.

## Iteration-5 tail status: strict flip blocked on exactly ONE litmus

Fixed this iteration (all strict-verified): init-command-shape steps 1-3
(rg regex-vs-literal: -F for exact source lines; -z→-U multiline; the
canonical image pin updated 8→10 images per orders 253/76);
headless-init harness step quoting (single→double-quoted scalar — it had
NEVER executed) + rustup env (RUSTUP_HOME/CARGO_HOME pinned before the
HOME override); the command:-regex anchor RE-APPLIED safely post-slice-2
(a doc comment containing the literal pattern reproduced the mid-string
match bug — the anchor now guards it).

REMAINING BLOCKER (the only one): litmus-headless-init-status-check-
source-built STEP 3+ — the harness cargo test
source_built_init_and_status_check_smoke_uses_fake_podman "passes" in
0.07s WITHOUT writing the calls log (self-short-circuit; a hermetic
skip disguised as pass). Rust-side investigation: find the early-return
condition (env probe? fake-podman detection?) and make the test fail
loud when its preconditions are absent. Until then the strict-exit
default flip stays off; this file alone produces DEAD-CHECK warnings in
legacy mode.

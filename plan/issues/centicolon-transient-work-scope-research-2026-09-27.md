# CentiColon Scope for Transient Work and the Distillation Layer (Research & Design)

- Date: 2026-09-27.
- Author: Antigravity (Advanced Agentic Coding agent, pairing with the operator).
- Related: Order `1447-9sne` (`plan/index.d/20260927t234600z-1447-9sne-centicolon-scope-for-transient-work-research-macuahuitl.yaml`), `1395-n7qd`, `1395-88tp`, `1395-ue3i`, `1395-miwn`, `1395-64r7`.
- Operator direction (2026-09-27):
  > "As we make progress in our CentiColon metrics, to better enforce our Monotonic Reduction Of Uncertainty and have this delicious LUA layer and LITMUS TEST for our specs, there is a lot of work filed as ./plan packets which might not necessarily be in the form of a SPEC, and it doesn't have to. I just wonder if we need a similar metric, or even the same, for transient work, like bug fixing which isn't really a spec 'fix bug X' but would instead produce a spec 'Y and Z prevent bug X', our centicolon metrics, even while still not as meaningful as we want them, might still be missing some scope on them. File research packet, and I'll have Codex and Antigravity chime in design decisions."
  > "The ./plan resembles more the tracing of the obligations and their distillation into implementations. It's a weird layer in the middle."

---

## 1. The Core Insight: `./plan` as the Distillation Middle Layer

The repository's ontology consists of three distinct tiers:

1. **The Statics (`openspec/`)**: WHAT the system contractually guarantees. Stable, user-visible requirements and scenarios with permanent IDs (`<!-- req-id: <hex> -->`).
2. **The Dynamics (`./plan`)**: HOW knowledge is acquired, friction is diagnosed, and reality is distilled. A CRDT ledger of active transformation ($\Delta$).
3. **The Substrate (`crates/`, `scripts/`, `images/`)**: The concrete program bytes executing across physical and virtual hosts (Linux, macOS Darwin, Windows/WSL, Forge tmpfs).

### The Pathology of Forcing All Work into Specs
When a dev-box error occurs (e.g. `1393-aa7v` Windows CRLF in Lua print, `1401-x76w` forge `CARGO_TARGET_DIR` regime, `1375-tsfu` eliminating `jq` callsites):
- **It is not an end-user product requirement**: End users of Tillandsias do not care about WSL 9p mount latencies or BSD `awk` argument flags. Polluting `openspec/specs/` with transient host quirks degrades specification quality.
- **Yet it cannot be treated as invisible**: If CentiColons only measures `openspec/specs/`, this vital infrastructure work yields $\Delta \mathcal{R} = 0$, causing convergence velocity $\mathcal{V}_c$ to stall, falsely triggering thrashing penalties ($C > C_{\text{max}}, \mathcal{V}_c \le 0$).
- **The middle layer's role**: `./plan` packets act as the **distillation apparatus**. A packet takes a raw observation/bug, isolates it into a reproducer, and distills it into either:
  - A user-facing feature/contract refinement (closing a spec scenario),
  - A **Systemic Invariant** (e.g. `inv:toolchain:no-jq-callsites`), or
  - A **Platform Precondition** (e.g. `env:darwin:bash32-portable-shims`).

---

## 2. Answers to the 6 Design Questions (Antigravity's Position)

### (1) One metric or two: The Decomposed Residual Vector $\vec{\mathcal{R}}$
**Position**: Decomposed vector with a unified scalar ranking projection, plus an orthogonal Invariant-Yield Ratio.
- **The Residual Vector**:
  $$\vec{\mathcal{R}} = \langle \mathcal{R}_{\text{spec}}, \mathcal{R}_{\text{inv}}, \mathcal{R}_{\text{env}} \rangle$$
  - $\mathcal{R}_{\text{spec}}$: Remaining unclosed spec scenario obligations (`cc:<req-id>:<scenario-hash>`).
  - $\mathcal{R}_{\text{inv}}$: Remaining unclosed repository invariants (`cc:inv:<domain>:<hash>`).
  - $\mathcal{R}_{\text{env}}$: Remaining unclosed platform preconditions (`cc:env:<platform>:<hash>`).
- **The Scalar Projection ($R$)**:
  $$R = W_{\text{spec}} \mathcal{R}_{\text{spec}} + W_{\text{inv}} \mathcal{R}_{\text{inv}} + W_{\text{env}} \mathcal{R}_{\text{env}}$$
  This maintains a single, bounded Floyd/Lyapunov ranking function (satisfying `977-j6qu`'s rule) while allowing the dashboard and `--check` to report the exact component histogram.
- **The Invariant-Yield Ratio ($Y_{\text{inv}}$)**:
  $$Y_{\text{inv}} = \frac{N_{\text{durable\_invariants\_produced}}}{N_{\text{transient\_defects\_closed}}}$$
  Reported beside $R$ as a process health metric to prevent fixes that do not leave automated guards behind.

### (2) What counts as the durable residue of a transient fix?
**Position**: A machine-checkable Invariant Litmus test or gate decider with pre-fix FAIL evidence.
- A transient bug fix is considered to have yielded durable residue IF AND ONLY IF:
  1. It adds or updates a `Cacheable` or `Observing` Lua Litmus test (or gate decider `.step`),
  2. The test/decider executes in the gate (`./build.sh --check` or `--ci-full`), and
  3. The packet record cites pre-fix failure evidence (`Pre-fix result: FAILS`).
- Prose alone (notes in cheatsheets or READMEs) does NOT qualify as durable residue.

### (3) Closure rule & verifiable closure grammar
**Position**: Expand `check-scorable-obligation-added.sh` to accept five explicit forms:
```yaml
# 1. Spec Scenario Closure: verified by centicolon-grade-observed.lua >= positively_tested
verifiable_closure: centicolon: <req-id>[, ...]

# 2. Invariant Closure: verified by bound Lua Litmus invariant test
verifiable_closure: centicolon: inv:<domain>:<id>

# 3. Platform Precondition Closure: verified by host-specific litmus record
verifiable_closure: centicolon: env:<platform>:<id>

# 4. Operational Maintenance: verifiably passes clean exit code; neutral transition (ΔR = 0)
verifiable_closure: maintenance: <command>

# 5. Explicit Unscoreable: research/spikes where no mechanical assert exists
verifiable_closure: unscoreable: <substantive rationale>
```
At packet closure time, the grader validates that named obligations are $\ge \text{positively\_tested}$. Packets declaring `maintenance:` do not penalize $\mathcal{V}_c$ as thrashing.

### (4) Monotonicity under continuous bug arrival
**Position**: Strict separation between the **State Lattice** and the **Backlog Queue**.
- A newly observed bug is an unpredicted observation (`methodology/event/`) or an open issue in the backlog queue ($\mathcal{Q}$).
- It does NOT immediately change the ranking denominator.
- It enters the denominator ONLY when formally codified as a new Invariant or Spec Requirement, which is classified as an explicit **Scope Change** (`regime=broken:scope-added:<n>`).
- Under a fixed denominator, $R$ descends strictly monotonically as invariants and scenarios reach $\text{positively\_tested}$.

### (5) Recurrence detection via the Lua Litmus layer
**Position**: Native AST and pattern-matching predicates in Lua.
- The Lua runtime (`mlua` + `lua_std`) provides pure, fast file querying without shell pipes.
- Recurrence predicates (e.g. checking for shell pipe patterns in new scripts, unquoted heredocs, or known flaky constructs) run in $< 5\text{ms}$.
- If a recurring failure pattern reappears, the predicate fails loud in `./build.sh --check` as `violation:recurring-defect-pattern:<name>`.

### (6) Computational Cost
**Position**: Sub-10ms gate execution; zero host subprocess leaks.
- Because Lua predicates execute in-process via `mlua` with content-addressed memoization (`ReadLog`), running 50 invariant checks adds $< 100\text{ms}$ to `./build.sh --check`.
- Eliminating bash subshells and external pipes actually *reduces* total gate execution time and eliminates flake modes (such as SIGPIPE rc=141 or macOS GNU vs BSD utility divergence).

---

## 3. Recommended Implementation Roadmap

1. **Phase 1 (Spec & Methodology)**: Land the updated requirements in `openspec/specs/methodology-accountability/spec.md` (done).
2. **Phase 2 (Extractor & Grader Support for Invariants)**:
   - Extend `scripts/lua/centicolon-extract.lua` to extract `### Invariant:` blocks and `openspec/invariants/*.yaml` into `cc:inv:<domain>:<hash>`.
   - Update `scripts/lua/centicolon-grade-static.lua` to grade invariant bindings.
3. **Phase 3 (Gate Seams & Verifiable Closure)**:
   - Update `scripts/check-scorable-obligation-added.sh` and `scripts/check-declared-closures-added.sh` to accept `centicolon: inv:*` and `maintenance: *`.
4. **Phase 4 (Velocity & SKILL Update)**:
   - Update `skills/coordinate-multihost-work/SKILL.md` to use the decomposed vector $\vec{\mathcal{R}}$ and isolate backlog queue length $\mathcal{Q}$ from the ranking function.

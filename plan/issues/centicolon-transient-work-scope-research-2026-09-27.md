# CentiColon and transient work — scope research (2026-09-27)

Packet: 1447-9sne (research, operator request). Question: does CentiColon's
monotonic reduction of uncertainty miss the transient work that dominates the
ledger — "fix bug X" is not a spec, but should produce one ("Y and Z prevent
X") — and should the same metric or a sibling one count it?

Shape of this document (coordinator, 2026-09-27): a MEASURED baseline first
(tlatoanis-macbook-air), then positions (Codex, Antigravity), then the
coordinator's synthesis and a recommendation. Only the baseline is filled in
here; the headings after it are deliberately empty.

## Baseline (measured) — tlatoanis-macbook-air, 2026-09-27

Question: of the transient work closed in the last 30 days (bugs and their
kin), how much left something that PREVENTS the same failure — a spec
requirement with a litmus binding, a decider/guard, a fixture that fails
pre-fix, a methodology rule — and how much left nothing?

Every number below is reproducible from the committed tree with the plan
binary and git alone (no jq, no python). The queries are in "How it was
measured"; the tree is `origin/linux-next` at `ca1bf26c3`.

### What counts as "transient" — the kind vocabulary

The requested kinds were `bug`, `finding`, `optimization`, `regression`.
Among the 316 packets in a closing status (`completed | verified | done`;
`obsoleted` excluded — it is terminal but is not a fix), the ledger uses:

| kind | closed | | kind | closed |
|---|---|---|---|---|
| bug | 182 | | feature | 12 |
| enhancement | 43 | | research | 7 |
| **bugfix** | 23 | | improvement | 5 |
| **defect** | 22 | | docs | 5 |
| **fix** | 10 | | other (8 kinds, 1 each) | 8 |

**`finding`, `optimization` and `regression` do not occur on any closed
packet.** A literal four-kind query returns `bug` only. The bug class is
spelled five ways (`bug`, `bugfix`, `defect`, `fix`, `infra+fix`), so this
baseline uses those five and reports `bug` alone beside it. The spelling
spread is itself a finding: a CentiColon rule keyed on a kind string would
miss 56 of 238 closed bug-class packets (24%) today.

### Window

238 bug-class packets are closed. Closure time is the latest
`completed | verified | done` event from `plan-events`. 225 closed at or
after `2026-08-28T00:00:00Z`, 12 before it, and 1 carries no closing event
(undated; excluded). The ledger is young: the 30-day window holds 95% of all
bug-class closures ever made.

### Residue classes, n = 225

A packet leaves residue in a class when its `packet_id`, or its order as a
word (`1420-inak`; a bare numeric order only as `order <n>` in any case), is
cited in:

| class | where | packets | share |
|---|---|---|---|
| (a) spec requirement with a litmus binding | a `spec.md` whose spec has ≥1 litmus test in `openspec/litmus-bindings.yaml`, or `openspec/litmus-tests/*.yaml` | 75 | 33% |
| (b) decider or guard | `scripts/check-*.sh`, `scripts/hooks/*`, `scripts/lua/*.lua` | 90 | 40% |
| (c) fixture | `scripts/test-*.sh` | 153 | 68% |
| (c′) …whose text states a pre-fix FAIL | the same fixture matches `pre-fix…fail` | 30 | 13% |
| (d) methodology rule | `methodology.yaml`, `methodology/**` | 15 | 7% |
| **(e) none of (a)–(d)** | | **40** | **18%** |
| supplementary: Rust citation | `crates/**/*.rs` | 77 | 34% |

Classes overlap. The combinations, most common first:

| combination | packets | | combination | packets |
|---|---|---|---|---|
| c only | 47 | | a only | 12 |
| **none** | **40** | | c + d | 5 |
| b + c | 40 | | a + b + c + d | 4 |
| a + c | 30 | | a + b | 4 |
| a + b + c | 24 | | b + c + d | 3 |
| b only | 13 | | d only | 1 |

Of the 40 with no residue in (a)–(d), **28 are cited in Rust** (a unit
test or a code comment — this baseline does not tell the two apart), and
**12 are cited nowhere outside `plan/`**:
827-rjc9, 865-r6dt, 892-pfnd, 1023-czw6, 1039-b64k, 1044-na6u, 1110-4v4h,
1133-2fyd, 1197-y6g6, 1245-wbqh, 1296-jutd, 1338-2sae.

By kind:

| kind | n | (a) | (b) | (c) | (c′) | (d) | (e) none | Rust |
|---|---|---|---|---|---|---|---|---|
| bug | 174 | 65 | 62 | 124 | 26 | 14 | 30 | 54 |
| defect | 22 | 4 | 10 | 10 | 3 | 0 | 9 | 13 |
| bugfix | 21 | 3 | 16 | 13 | 1 | 0 | 0 | 6 |
| fix | 8 | 3 | 2 | 6 | 0 | 1 | 1 | 4 |

`defect` is the weakest (9 of 22 leave no residue in (a)–(d)) and has no
methodology rule at all.

### Recurring shapes

Distinct packets (any status, base ledger plus every fragment; 1,254
distinct orders) whose title, context, closure, outcome or blocked reason
names the shape, and how many of those are in the 225 above. "Guard" is a
decider that mechanically refuses the shape today.

| shape | packets | in window | guard on trunk |
|---|---|---|---|
| verdict read through a pipe (`\| tail -1`, "through a pipe") | 14 | 7 | fixture only (`test-land-verdict-through-a-pipe.sh`) |
| SIGPIPE-decided verdict under pipefail | 13 | 5 | `check-sigpipe-verdict-pipelines-added.sh` |
| bash 3.2 dialect | 12 | 5 | `check-bash-dialect.sh` |
| python in committed automation | 11 | 3 | `check-no-python-scripts.sh` |
| cfg / feature-set cross-compile | 11 | 3 | `check-cross-target-build.sh` |
| stale plan binary | 10 | 3 | `check-plan-binary-current.sh` |
| CRLF from Windows tools | 10 | 3 | `check-jq-multiline-capture-strips-cr.sh` |
| unquoted heredoc executes its body | 9 | 1 | **none** (the 1443-we89 bridge is filed, not landed) |
| stale / unresolvable litmus pin | 9 | 2 | `check-litmus-pin-claims.sh` |
| exec bit dropped | 8 | 4 | `check-script-exec-bits.sh` |
| fixture forges or borrows a gate stamp | 6 | 3 | `gate-stamp.sh verify` (`stale:fixture-borrowed-stamp`, 1442-22d2) |
| void exit capture (`PIPESTATUS` under zsh) | 1 | 1 | **none** |
| jq call site (not a failure shape — a migration) | 24 | 6 | `check-jq-callsite-ratchet.sh` |

Every shape named in ≥2 packets except two now has a guard. Those two are
the unquoted heredoc (9 packets) and the pipe-read verdict, which has a
fixture but no decider scanning for new sites.

The shape counts are keyword matches over packet prose. A packet that names
a shape in passing is counted. The broad form of the gate-stamp pattern
(`gate stamp|pass token|…`) matched 35 packets. The row above uses a narrow
pattern (a fixture that writes or borrows a stamp), which matches 6.

### What this baseline does NOT say

- **(c) is a citation, not a verified pre-fix failure.** 153 packets are
  cited by a fixture. Only 30 of those fixtures SAY their pre-fix result
  fails, and no fixture here was run against a pre-fix tree. (c′) is the
  honest lower bound for "a fixture that would catch the regression".
- A citation in (b) means the order appears in a decider's text. The decider
  may cite it as history rather than enforce against it.
- The Rust column does not separate `#[test]` code from comments.
- 1,254 distinct orders appear in packet definitions against 1,221 in the
  fold; the difference (tombstoned or merged definitions) is counted in the
  shape table and cannot move a shape across the ≥2 threshold by more than
  that margin.

### How it was measured

All from the repository root on `origin/linux-next` `ca1bf26c3`, with
`B=target/release/tillandsias-plan` built from that tree.

```bash
# 1. Closed packets and their kinds.
for st in completed verified done; do "$B" query --status "$st" --json --limit 5000; done > terminal.jsonl
"$B" json get -r '.[] | .kind' terminal.jsonl | sort | uniq -c | sort -rn

# 2. Bug-class packets with their closure timestamp (latest closing event).
"$B" json get -c '.[] | select(.kind == "bug" or .kind == "bugfix" or .kind == "defect" or .kind == "fix" or .kind == "infra+fix") | [.order, .kind, .packet_id]' terminal.jsonl \
  | sed -e 's/^\[//' -e 's/\]$//' -e 's/"//g' \
  | while IFS=, read -r order kind pid; do
      ts="$("$B" plan-events "$pid" | awk -F'\t' '$1=="completed"||$1=="verified"||$1=="done"{print $2}' | sort | tail -1)"
      printf '%s\t%s\t%s\t%s\n' "$order" "$kind" "${ts:-undated}" "$pid"
    done > window.tsv
awk -F'\t' '$3!="undated" && $3>="2026-08-28T00:00:00Z"' window.tsv > in-window.tsv

# 3. Litmus-bound specs.
"$B" yaml-json openspec/litmus-bindings.yaml \
  | "$B" json get -r '.specs[] | select((.litmus_tests | length) > 0) | .spec_id' > bound-specs.txt

# 4. Residue, per packet, over the COMMITTED tree (git grep REV, never the worktree).
#    pattern: -E -e "<packet_id>" -e "(^|[^a-z0-9-])<order>([^a-z0-9]|$)"
#             (bare numeric order: -e "[Oo][Rr][Dd][Ee][Rr][ :]*<n>([^0-9-]|$)")
git grep -l -I "${pat[@]}" HEAD -- openspec/specs/<bound>/spec.md 'openspec/litmus-tests/*.yaml'  # (a)
git grep -l -I "${pat[@]}" HEAD -- 'scripts/check-*.sh' 'scripts/hooks/*' 'scripts/lua/*.lua'   # (b)
git grep -l -I "${pat[@]}" HEAD -- 'scripts/test-*.sh'   # (c); (c') = one of those files matches -iE 'pre-fix[^\n]*fail'
git grep -l -I "${pat[@]}" HEAD -- methodology.yaml 'methodology/*'                             # (d)
git grep -l -I "${pat[@]}" HEAD -- 'crates/*.rs'                                                # Rust (supplementary)

# 5. Packet prose for shapes: base ledger steps plus every fragment's packets.
"$B" yaml-json plan/index.yaml | "$B" json get -c '.plan_index.steps[] | [(.order | tostring), .kind, .title, .outcome, .blocked_reason]'
for f in plan/index.d/*.yaml; do "$B" yaml-json "$f" | "$B" json get -c '(.packets // [])[] | [(.order | tostring), .kind, .title, .context, .verifiable_closure]'; done
#    then per shape: grep -iE '<pattern>' | order column | sort -u | wc -l, and comm -12 with in-window orders.
```

Shape patterns (case-insensitive): `sigpipe`; `heredoc`;
`litmus[- ]pin|stale pin|pin-unresolvable|pin claim`; `exec[- ]bit|executable bit`;
`stale (plan )?binary|binary is stale|plan-binary-current`;
`tail -1|through a pipe`; `bash 3\.2|bash-dialect`; `python`;
`cfg\(|feature set|e0433`; `crlf`; `pipestatus`; `\bjq\b`; and for the stamp
row `fixture-borrowed|forg…stamp|real git dir|writes? … stamp|stamp.{0,40}fixture|fixture.{0,40}stamp`.

Classification was spot-checked both ways before these numbers were taken.
Three of the "none" packets have zero citations outside `plan/`. Three "c"
packets resolve to named fixtures (777-k88g →
`test-forge-clone-wait-is-bounded.sh`, 799-nx4r → `test-nix-toolbox.sh`,
888-miiy → `test-a-claim-names-a-workstation.sh`). One case-sensitivity miss
was found and fixed: `ORDER 560` in a fixture was missed until the numeric
match became case-insensitive.

## Positions

### Codex

### Antigravity

_Contributed by Antigravity (calmecacpilli, `work/1447-9sne` e7ef20ce9, 2026-09-28), relayed by the coordinator. Text below is Antigravity's, headings demoted to sit under this section._


- Date: 2026-09-27.
- Author: Antigravity (Advanced Agentic Coding agent, pairing with the operator).
- Related: Order `1447-9sne` (`plan/index.d/20260927t234600z-1447-9sne-centicolon-scope-for-transient-work-research-macuahuitl.yaml`), `1395-n7qd`, `1395-88tp`, `1395-ue3i`, `1395-miwn`, `1395-64r7`.
- Operator direction (2026-09-27):
  > "As we make progress in our CentiColon metrics, to better enforce our Monotonic Reduction Of Uncertainty and have this delicious LUA layer and LITMUS TEST for our specs, there is a lot of work filed as ./plan packets which might not necessarily be in the form of a SPEC, and it doesn't have to. I just wonder if we need a similar metric, or even the same, for transient work, like bug fixing which isn't really a spec 'fix bug X' but would instead produce a spec 'Y and Z prevent bug X', our centicolon metrics, even while still not as meaningful as we want them, might still be missing some scope on them. File research packet, and I'll have Codex and Antigravity chime in design decisions."
  > "The ./plan resembles more the tracing of the obligations and their distillation into implementations. It's a weird layer in the middle."

---

#### 1. The Core Insight: `./plan` as the Distillation Middle Layer

The repository's ontology consists of three distinct tiers:

1. **The Statics (`openspec/`)**: WHAT the system contractually guarantees. Stable, user-visible requirements and scenarios with permanent IDs (`<!-- req-id: <hex> -->`).
2. **The Dynamics (`./plan`)**: HOW knowledge is acquired, friction is diagnosed, and reality is distilled. A CRDT ledger of active transformation ($\Delta$).
3. **The Substrate (`crates/`, `scripts/`, `images/`)**: The concrete program bytes executing across physical and virtual hosts (Linux, macOS Darwin, Windows/WSL, Forge tmpfs).

##### The Pathology of Forcing All Work into Specs
When a dev-box error occurs (e.g. `1393-aa7v` Windows CRLF in Lua print, `1401-x76w` forge `CARGO_TARGET_DIR` regime, `1375-tsfu` eliminating `jq` callsites):
- **It is not an end-user product requirement**: End users of Tillandsias do not care about WSL 9p mount latencies or BSD `awk` argument flags. Polluting `openspec/specs/` with transient host quirks degrades specification quality.
- **Yet it cannot be treated as invisible**: If CentiColons only measures `openspec/specs/`, this vital infrastructure work yields $\Delta \mathcal{R} = 0$, causing convergence velocity $\mathcal{V}_c$ to stall, falsely triggering thrashing penalties ($C > C_{\text{max}}, \mathcal{V}_c \le 0$).
- **The middle layer's role**: `./plan` packets act as the **distillation apparatus**. A packet takes a raw observation/bug, isolates it into a reproducer, and distills it into either:
  - A user-facing feature/contract refinement (closing a spec scenario),
  - A **Systemic Invariant** (e.g. `inv:toolchain:no-jq-callsites`), or
  - A **Platform Precondition** (e.g. `env:darwin:bash32-portable-shims`).

---

#### 2. Answers to the 6 Design Questions (Antigravity's Position)

##### (1) One metric or two: The Decomposed Residual Vector $\vec{\mathcal{R}}$
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

##### (2) What counts as the durable residue of a transient fix?
**Position**: A machine-checkable Invariant Litmus test or gate decider with pre-fix FAIL evidence.
- A transient bug fix is considered to have yielded durable residue IF AND ONLY IF:
  1. It adds or updates a `Cacheable` or `Observing` Lua Litmus test (or gate decider `.step`),
  2. The test/decider executes in the gate (`./build.sh --check` or `--ci-full`), and
  3. The packet record cites pre-fix failure evidence (`Pre-fix result: FAILS`).
- Prose alone (notes in cheatsheets or READMEs) does NOT qualify as durable residue.

##### (3) Closure rule & verifiable closure grammar
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

##### (4) Monotonicity under continuous bug arrival
**Position**: Strict separation between the **State Lattice** and the **Backlog Queue**.
- A newly observed bug is an unpredicted observation (`methodology/event/`) or an open issue in the backlog queue ($\mathcal{Q}$).
- It does NOT immediately change the ranking denominator.
- It enters the denominator ONLY when formally codified as a new Invariant or Spec Requirement, which is classified as an explicit **Scope Change** (`regime=broken:scope-added:<n>`).
- Under a fixed denominator, $R$ descends strictly monotonically as invariants and scenarios reach $\text{positively\_tested}$.

##### (5) Recurrence detection via the Lua Litmus layer
**Position**: Native AST and pattern-matching predicates in Lua.
- The Lua runtime (`mlua` + `lua_std`) provides pure, fast file querying without shell pipes.
- Recurrence predicates (e.g. checking for shell pipe patterns in new scripts, unquoted heredocs, or known flaky constructs) run in $< 5\text{ms}$.
- If a recurring failure pattern reappears, the predicate fails loud in `./build.sh --check` as `violation:recurring-defect-pattern:<name>`.

##### (6) Computational Cost
**Position**: Sub-10ms gate execution; zero host subprocess leaks.
- Because Lua predicates execute in-process via `mlua` with content-addressed memoization (`ReadLog`), running 50 invariant checks adds $< 100\text{ms}$ to `./build.sh --check`.
- Eliminating bash subshells and external pipes actually *reduces* total gate execution time and eliminates flake modes (such as SIGPIPE rc=141 or macOS GNU vs BSD utility divergence).

---

#### 3. Recommended Implementation Roadmap

1. **Phase 1 (Spec & Methodology)**: Land the updated requirements in `openspec/specs/methodology-accountability/spec.md` (done).
2. **Phase 2 (Extractor & Grader Support for Invariants)**:
   - Extend `scripts/lua/centicolon-extract.lua` to extract `### Invariant:` blocks and `openspec/invariants/*.yaml` into `cc:inv:<domain>:<hash>`.
   - Update `scripts/lua/centicolon-grade-static.lua` to grade invariant bindings.
3. **Phase 3 (Gate Seams & Verifiable Closure)**:
   - Update `scripts/check-scorable-obligation-added.sh` and `scripts/check-declared-closures-added.sh` to accept `centicolon: inv:*` and `maintenance: *`.
4. **Phase 4 (Velocity & SKILL Update)**:
   - Update `skills/coordinate-multihost-work/SKILL.md` to use the decomposed vector $\vec{\mathcal{R}}$ and isolate backlog queue length $\mathcal{Q}$ from the ranking function.


#### Proposed spec requirements (Antigravity) — NOT ADOPTED

_Antigravity proposed three requirements for `openspec/specs/methodology-accountability/spec.md` (req-ids e45b37c5, a1b71f16, 5ee5d6af). The coordinator did not merge them into the durable spec: 1447-9sne closes on the operator's pick among the recorded positions, Codex has not stated its position yet, and parts of the text describe tooling that does not exist (e.g. `check-scorable-obligation-added.sh` accepting `centicolon: inv:<id>`). They are preserved verbatim here so the pick can adopt them as-is._

```markdown
### Requirement: Plan ledger models the distillation layer
<!-- req-id: e45b37c5 -->
- **ID**: methodology-accountability.distillation.plan-ledger@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.distillation-layer-explicit]

The `./plan` ledger SHALL model the epistemic distillation layer between formal
specifications (`openspec/`), systemic invariants, platform reality, and concrete code
implementations. Packets SHALL represent discrete state transitions ($\Delta$), not
static correctness debt coordinates.

#### Scenario: Spec feature distillation
- **WHEN** a plan packet implements or refines a user-visible functional contract
- **THEN** its `verifiable_closure` SHALL cite `centicolon: <req-id>[, ...]`
- **AND** the obligation grader SHALL verify the named scenarios achieve $\ge$ `positively_tested`

#### Scenario: Invariant and platform defect distillation
- **WHEN** a plan packet resolves a systemic invariant violation (toolchain, pipe elimination,
  determinism) or a platform/dev-box quirk (macOS Darwin, Windows WSL, Forge tmpfs)
- **THEN** it SHALL NOT pollute product specifications
- **AND** its `verifiable_closure` SHALL cite `centicolon: inv:<id>` or `centicolon: env:<id>`
- **AND** it SHALL be verified by an executable, deterministic Lua Litmus test

#### Scenario: Operational maintenance transition
- **WHEN** a plan packet executes non-functional repository maintenance (salvage sweeps,
  lease handoffs, fragment relays)
- **THEN** it SHALL declare `maintenance: <verifiable-command>`
- **AND** SHALL NOT modify the stationary obligation denominator ($\Delta \mathcal{R} = 0$)

### Requirement: Dual-domain obligation extraction via Lua substrate
<!-- req-id: a1b71f16 -->
- **ID**: methodology-accountability.extraction.lua-substrate@v1
- **Modality**: MUST
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.pure-obligation-extraction]

Obligation extraction and static grading SHALL be implemented as deterministic,
content-addressed `Cacheable` Lua predicates running within the hermetic runtime
without host dependencies, external shell pipes, or subshells. The obligation universe
SHALL explicitly decompose into spec contracts ($S_{\text{spec}}$), systemic invariants
($S_{\text{inv}}$), and platform preconditions ($S_{\text{env}}$).

#### Scenario: Deterministic obligation list
- **WHEN** the Lua extractor executes over repository bytes
- **THEN** it SHALL emit sorted canonical JSON whose SHA-256 digest is byte-identical
  across Linux, macOS, Windows, and Forge hosts
- **AND** it SHALL report unregistered or unkeyed artifacts explicitly

#### Scenario: Invariant execution inside the pre-push gate
- **WHEN** `./build.sh --check` executes
- **THEN** pure `Cacheable` Lua Litmus tests asserting systemic invariants SHALL run
- **AND** their pass/fail results SHALL witness active invariant verification before push

### Requirement: Invariant yield and verifiable closure for transient packets
<!-- req-id: 5ee5d6af -->
- **ID**: methodology-accountability.transient.invariant-yield@v1
- **Modality**: SHOULD
- **Measurable**: true
- **Invariants**: [methodology-accountability.invariant.transient-yields-invariants]

Transient work (bug fixes, flake defusals, harness repairs) SHOULD yield durable
machine-checkable invariants rather than prose assurances. The convergence engine
SHALL track the invariant-yield ratio across closed bug-class packets.

#### Scenario: Bug closure produces durable invariant
- **WHEN** a bug-class packet closes
- **THEN** it SHOULD produce a new or updated invariant litmus test or gate decider
  with pre-fix failure evidence
- **OR** SHALL explicitly declare `unscoreable: <why-no-invariant-produced>`

### Invariant: Distillation layer is explicit
- **ID**: methodology-accountability.invariant.distillation-layer-explicit
- **Expression**: `plan_packets ACT_AS state_transitions_delta AND DO_NOT_MIX queue_length_into_ranking_denominator`
- **Measurable**: true

### Invariant: Pure obligation extraction
- **ID**: methodology-accountability.invariant.pure-obligation-extraction
- **Expression**: `sha256(lua_extractor_output) IDENTICAL_ACROSS_PLATFORMS`
- **Measurable**: true

### Invariant: Transient work yields invariants
- **ID**: methodology-accountability.invariant.transient-yields-invariants
- **Expression**: `closed_bug_packets YIELD durable_litmus_or_decider_invariant`
- **Measurable**: true

```

## Synthesis

## Recommendation

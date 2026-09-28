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

## Synthesis

## Recommendation

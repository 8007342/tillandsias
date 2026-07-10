# In-forge agent pushed a syntactically invalid plan/index.yaml — ledger validation is advisory on the forge push path

- **Filed**: 2026-07-10T01:25Z
- **Agent**: linux-macuahuitl-fable5-20260710T0009Z (meta-orchestration cycle)
- **Classification**: enhancement (verifiable-constraint gap)
- **Status**: open — promoted to plan/index.yaml order 263
- **Related**: plan/issues/build-install-smoke-e2e-findings-2026-07-10.md (the
  run whose in-forge cycle produced the breakage), order 261 (ruby-free
  validation — shares the validator-portability question), methodology.yaml
  finalization step 3 ("Validate touched YAML with a parser")

## What happened

During e2e run 20260710T003451Z, the in-forge agent
(linux-tlatoani-big-pickle-20260710T0044Z) recorded its order-254 completion
event in `plan/index.yaml` and pushed `61abd3bf` — with the pre-existing
`filed` event's `agent_id:` line re-indented two columns deep (line 6059).
The committed ledger did not parse (`Psych::SyntaxError ... line 6057`) on
`origin/linux-next` until the coordinator's mechanical mediation this cycle.

Consequences while broken:

- Any agent whose cycle parses the ledger (advance-work-from-plan claim
  scan, archive tooling, policy checks) fails or — worse — silently skips
  work discovery.
- The next in-forge verification cycle (order 262's live re-run) would have
  failed for an unrelated reason, muddying the litmus verdict.

## The gap

The meta-orchestration finalization step "Validate touched YAML with a
parser" is prose. On coordinator hosts it is habitually executed; inside the
forge lane nothing enforces it — the agent's push went through the
git-mirror relay with no syntactic gate. A guard only an attentive agent
honors is a suggestion, not a constraint (philosophy.yaml).

## Proposed reduction (order 263)

Make ledger parseability an executable gate on the push path itself:

1. git-mirror-service pre-receive: reject a push whose touched
   `plan/**/*.yaml` / `plan.yaml` / `openspec/**/*.yaml` blobs fail a YAML
   parse, emitting the file + parser error to the pusher. The mirror is the
   single choke point every forge push already traverses
   (forge-push-credential-channel), so this closes the gap for ALL in-forge
   agents at once, cross-host.
2. Validator choice: `tillandsias-policy validate-yaml` where the binary is
   available in the mirror image; ruby fallback otherwise (mirror runs on
   Linux, so the order-261 Windows constraint does not bite here).
3. Pin with a shape litmus: a fixture push containing a broken index is
   rejected with the parse error; a clean push passes (positive control).

Until 263 lands, coordinators should treat "in-forge cycle touched
plan/*.yaml" as a cue to re-validate after fetch (this cycle's mediation
pattern).

## Cycle 2026-08-25T23:37:23Z — lenovinha (linux_immutable, linux-next, operator /loop)

Clean start, all guards green. Third cycle running the same subsystem (credential guard →
promotion gate → stamp → credential guard again), which is the operator's related-packets
directive working: this one was cheap because 886-qmdz was already in context.

### 892-aw9p — a correct verdict has a SHELF LIFE (db5299d82)

Found and measured by calmecacpilli, who could not file it because they were blocked by the
very defect. I filed it on their behalf first, then they handed it over directly — their reason
is worth keeping: they are session-local and die with their user's terminal, so "next cycle" is
a promise they may not be alive to keep.

The guard runs once at Start-Of-Cycle and cannot see a credential that dies afterwards. On
calmecacpilli it returned `ok:gh-keyring-push-verified`, two pushes succeeded, and ~50 minutes
later the third failed with `remote: Invalid username or token`. **Nothing the guard measured
was wrong** — the verdict was true when issued. Its result outlived the thing it checked.

They ruled out my own false-positive shape before handing over: `grep -c refstate-refused` = 2,
so their checkout carries 886-qmdz and a behind-branch refusal would have exited 0. It did not.
That two-line proof is why I never had to re-derive whether my own fix was misfiring.

Fix: `check-credential-channel.sh reverify`. Re-probes; when the channel is dead AND a passing
stamp from this cycle exists, returns `blocked:credential-expired-mid-cycle`. The stamp records
only that a pass happened — it exists so the guard can distinguish "this credential DIED" from
"this host never had one", two conditions with the same repair cost, very different diagnoses,
previously both reported as `missing:no-credential-channel`.

**Where it runs is the design.** Finalization 3b, immediately before `./build.sh --check` — not
per push. Per-push re-probing would make the healthy path pay a round trip per git operation,
and a guard slow enough to notice gets bypassed. Before the gate is the last point where the
remaining cost is still worth saving. Stated honestly to calmecacpilli as a PARTIAL fix: it
moves discovery earlier, it does not move it early enough to save the implementation work, and
I invited them to push back since they paid for the data.

Landed on its own rather than folded into the class, at their request and the coordinator's
endorsement — a five-line fix should not wait on a taxonomy.

### The CLASS, filed separately (research, v0.6)

Credentials and build stamps are two instances of "a check whose result outlives the thing it
checked". **I fixed the stamp instance earlier the same night without noticing it was an
instance of anything** — which is the argument for enumerating rather than waiting to be bitten
a third time. Both known instances fail late and expensively, plausibly because a check consumed
far from where it was produced has the widest staleness window; if that holds it is predictive.

Filed with an explicit negative-control requirement: at least one check examined and found NOT
in the class, or the taxonomy is unfalsifiable and everything gets swept in. "Accept with reason
stated" is an allowed recommendation, or the audit manufactures work.

### Two fixture bugs in my own work, both the shape I have been fixing all night

- The no-auth `gh` stub was never created (a heredoc insert missed its anchor), so the
  "never had a credential" arm passed on **this host's LIVE credential** rather than the
  condition it claimed to test. With the stub it correctly returns `missing:no-credential-channel`
  instead of `blocked:gh-cli-only`.
- The hot-path assertion was a bare `grep -c 'push --dry-run'`, which counted two COMMENT lines
  describing the probe and fired at 5 when there are 3 real invocation sites. That is exactly the
  incidental co-occurrence defect I fixed in the promotion gate (888-m75r) — reproduced inside a
  test written to check for that kind of sloppiness.

Also hit the closure-evidence gate: my appended events landed under `packets:` instead of an
`events:` key, so a `completed` status carried no evidence-bearing event. The gate caught it.

### E2E: deferred a fifth time, with a reason rather than silence

`e2e-preflight` says `skip:live-runtime-present`, but that probe answers about the LOCAL-BUILD
gate and this host is routed to curl-install, so it does not answer my question. The real reason:
**no new tag exists yet** (VERSION and latest release are both v0.4.260817.1), and the fleet has
already decided not to promote that version — I proved it has windows-only evidence. Running a
destructive curl-install e2e now produces linux evidence for a release nobody will ship, while
the new cut is imminent and will need all three platforms fresh.

Checked one hazard before deciding: 804-bpke (uninstall deleting a VM dir while printing "Cache
preserved") is macOS-only, so it does not bite this host's destructive step. The deferral is
about timing, not risk. **Fifth consecutive deferral is a pattern, and the right moment is the
new tag** — flagging so it does not keep sliding on good reasons.

### Metrics
```
mcp: servers=3 per_server=cli=14484;forge-plan=187;project-info=209 health=ok
expert_accuracy: pass=28 graded=28 total=33 rate=100% skipped=5 skipped_engines=spec.answer NOT-EXERCISED-ON-THIS-HOST
flow: cycles=27 avg_completed_per_cycle=0.81 avg_commits_per_cycle=3.04 overhead_ratio=3.73
timing: steps=5645 build_check_ms_avg=45856 litmus_ms_avg=30351
plan: packets=613 ready=382
```
overhead_ratio has fallen 4.41 -> 3.73 across four cycles of related-packet batching.

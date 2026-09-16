# The fault's output is well-formed, so only the reader it blocks can find it

Five times on 2026-09-15, across five unrelated subsystems, a reader was stopped
or misled by something that produced **a plausible, well-formed output where the
correct outcome was "no answer here"**. The five have five different causes.
What they share is the detection condition:

> Nothing in a well-formed output announces its own boundary. A rule read wider
> than it is written produces the OUTPUT OF COMPLIANCE — silence, and work not
> attempted, indistinguishable from work correctly declined. A record read wider
> than its scope produces a complete, truthful log that looks exactly like a
> complete, truthful log that contained the answer. None emits a red, a refusal,
> or an artifact. So none is detectable except by the person it blocks, at the
> moment they are blocked.

That is the finding. The causes below stay distinct on purpose — they want
different fixes, and grouping them by cause would be wrong.

**Three shapes appear, in increasing cost:**

- **§1-§3 — a RULE OR REMEDY read wider than written.** The reader STOPS. The
  output is silence, indistinguishable from correctly declining.
- **§3b — a RECORD read wider than its scope.** The reader PROCEEDS on a false
  conclusion. The output is correct and complete about the wrong subject.
- **§3c — an ACCUSATION naming an innocent subject.** The reader is actively
  SENT SOMEWHERE WRONG. The output is specific, confident, and false.

That the three shapes share one detection condition while sharing no cause is
the evidence that the class is about detectability, not about rules.

trace: 1025-a896, methodology.runtime_language_policy.base64_script_injection_ban, 1211-34v6, 1213-ysme
host: yolanda-windows, with macuahuitl-fedora and yoga-silverblue

---

## 1. Cause A — compression in transit

Order 1025-a896's settled mechanism is GitHub's OAuth token pool: ten tokens per
(user, application, scope), oldest revoked beyond that. Its interim rule
(Option C) bans `gh auth login` / `gh auth refresh` in worker cycles. The
eviction is caused by **minting** a token through the device flow.

Relayed through the fleet it became **"nobody should run a login to test it"** —
accurate in substance, lossy in exactly the wrong place. `--with-token` mints
nothing, is outside the mechanism, and evicts nobody. The compressed form
forbids it anyway.

The rule is correctly scoped where it is written. A restatement dropped the
qualifier in transit.

Cost, measured:

- yoga-silverblue declined an end-to-end control run as too expensive for the
  fleet. It would have cost nothing.
- The broad form reached two hosts and the operator across three messages,
  originating with the coordinator.
- **Nobody obtained an end-to-end confirmation of the login lane all evening** —
  attributable to the dropped qualifier, not to the defect being investigated.
- Caught by the OPERATOR asking "wouldn't that only evict device logins?" — the
  one participant who had not been told the compressed version.

macuahuitl-fedora asked that their own instance be recorded as the primary
evidence of this cause, on the grounds that it shows the compression travelling
through the channel that is supposed to be authoritative. Recorded as asked.

## 2. Cause B — a text naming a mechanism the code does not read

The 759-vceg refusal advises setting `TILLANDSIAS_PROJECT_REMOTE_URL`. The
resolver that would have to read it — `read_host_project_origin_url`, falling
through to `parse_gitdir_origin_url` — contains no `env::var` on that path at
all. The variable is real elsewhere; this resolver never consults it.

**Nothing was compressed here.** The refusal named a mechanism that does not
exist on the path it gates. An operator following it gets the identical refusal
and learns nothing.

Filed and owned by yoga-silverblue as 1211-34v6, in their gate at time of
writing. Not to be picked up by anyone else.

## 3. Cause C — absolute wording outrunning its own scope

> "Embedding scripts of ANY language ... inside base64-encoded string literals —
> whether in Rust source, YAML, shell, or any other file — is unconditionally
> forbidden."

A host blocked by the Windows→WSL hop mangling `$` expansions reached for
base64, read "unconditionally" and "any other file", and stopped. A prior
base64 podman shim really had been removed under this rule, which made the
mapping look confirmed.

It does not cover an interactive command line: the corollary scopes the harm to
presence *in source code* as a runtime script-generation mechanism, and the
incident was smuggling Python past `tlatoani_hard_no_python`. Ruled outside
scope by macuahuitl-fedora after reading the text.

The rule is correctly scoped. Its wording generalises past its own corollary.

## 3b. A fourth instance, inverted: a truthful log that was not the right log

The three above share a shape — a reader meets a rule or remedy that overreaches
and STOPS. A fourth case from the same day inverts it and lands on the same
detection condition.

A row was filed here claiming the `--github-login` refusal renders only in an
ephemeral conhost window that nothing records. It is false: the Windows tray
tees the full output to `/root/.cache/tillandsias/github-login-last.log`
(injected shell in `wsl_lifecycle.rs`, not Rust) and names the path on exit.
That file held the
entire refusal the whole time.

The claim came from `tray.log`, which records the login being spawned and the
sign-in state flipping back to `signed-out`, and nothing about the outcome. That
observation was TRUE. The error was generalising an absence in the log that was
checked into an absence in every log — the sink is a different file, in the
guest, under a path `tray.log` never mentions.

**Nothing overreached here. A correct, complete, truthful log simply was not the
log with the answer in it, and its silence read as absence.** A session of guest
forensics went into reconstructing a message the tool names on its way out; it
was found only when the operator pasted that line.

Same condition as §1-§3: the output of the fault was well-formed. And the same
cost profile — the reader was mid-investigation, least able to afford doubting
the instrument, and the instrument was not lying, merely narrow.

Recorded here rather than left in the withdrawn row alone, because the inversion
is what shows the condition is about DETECTABILITY and not about rules at all.
See the withdrawal for the full account.

## 3c. A fifth instance: a failure naming the wrong subject with total confidence

Found by yoga-silverblue while fixing 1213-ysme — i.e. inside the act of
repairing an instance of this class.

The wrapper source-scan bounds its window on the raw-string terminator. The
literal opens `r#"#!/usr/bin/env bash`, so a search for `"#` starting at the
match hits the OPENING delimiter three bytes in and yields an EMPTY body. The
test then fails with:

```
the wrapper must launch tillandsias-headless --github-login
```

Which states that the launch line is missing. It is not missing. **The window
was empty.** The assertion is truthful about what it looked at and wrong about
what that implies, and its message names a subject — the wrapper's launch line —
that is entirely healthy.

A reader acting on that message would go and inspect the wrapper, find the
launch line present, and be left with a test that fails for no visible reason.

**This is the class's most expensive shape** because the output is not silence
and not a plausible value — it is an ACCUSATION, specific and confidently
worded, pointing at innocent code. §1-§3 stop a reader; §3b lets them proceed
on a false conclusion; this one actively sends them somewhere wrong.

Fixed in 1213-ysme by searching for `"#;` from after the opening delimiter. The
original's `&source[start..start + 900]` fixed-byte window has the same
character — it panics on a char boundary or past EOF once the script grows, and
would read as a defect in the wrapper rather than in the scan.

## 4. Why the shared detection condition is the finding

Compression, a dead remedy, and over-general wording are three different
defects with three different fixes. Grouping them by cause would be wrong.

They belong together because of what each one PRODUCES: a reader who stops, or
who follows advice that cannot work, and in both cases leaves no trace. A guard
that wrongly refuses at least emits a refusal. These emit nothing — the work
simply is not attempted, which is indistinguishable from the work correctly not
being attempted.

And the reader is **blocked at the moment of encounter**, which is the condition
that makes it expensive: least able to afford checking the source, most likely
to accept the broader reading and stop.

**This is the same family this fleet has been filing all day from other
directions** — an unexercised guard whose silence reads as a pass; a mutation
that never reaches the code; a control at zero reported as a verdict; a mangled
shell expansion printing `": "`, which reads exactly like a true absence. In
every one, the output of the fault is a well-formed answer. Framing by
yoga-silverblue, who corrected an earlier draft of this row that had named
compression as the class — which would have made §2 a false confirmation and
left the environment-versus-source defect unfiled.

## 5. What this row does NOT propose

**Not longer rules.** `base64_script_injection_ban`'s brevity is a feature, and
a rule nobody can restate is worse than one restated imperfectly. Expanding
every rule to pre-empt every misreading makes it unquotable, which is the
condition that produces compression in the first place.

The narrow claim that survives is about the MOMENT:

> **When a rule is quoted IN A REFUSAL, or relayed by a coordinator, the
> qualifier is the part that must survive — because that is exactly when the
> reader cannot check the source.**

A refusal and a coordinator relay are the two surfaces where a rule arrives
without its context, at someone who is stopped. That is a far smaller set than
"all rules", and each surface already has an instance above: §2 for refusal
text, §1 for the relay.

Caution in this section is macuahuitl-fedora's, who asked explicitly that the
row not conclude the remedy is more rule text.

## 6. Suggested disposition

Ratify or reject the §5 claim rather than implementing anything. The three
causes are separately owned already (§1 needs no fix beyond the correction
recorded here; §2 is 1211-34v6; §3 is a scope-note question on the ban's
wording), so this row's deliverable is the principle, not a patch.

related: [github-login push probe needs a checkout the guest lacks](github-login-push-probe-needs-a-checkout-the-guest-lacks-2026-09-15-yolanda-windows.md)
related: [the Windows->WSL hop mangles shell expansions](windows-wsl-hop-mangles-shell-expansions-2026-09-15-yolanda-windows.md)
related: [the withdrawn unlogged-terminal row](interactive-login-refusal-only-renders-in-an-unlogged-terminal-2026-09-15-yolanda-windows.md) — §3b's full account
related: [a host's test inventory differs silently from its siblings](test-inventory-differs-silently-across-hosts-2026-09-15-yolanda-windows.md) — the sharpest member: the fault's output is not merely well-formed but CORRECT
related: 1211-34v6 (yoga-silverblue, landed e15c81e6d), 1213-ysme, 1025-a896

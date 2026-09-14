# 1109-t8kw group C — the three empty-output reds, classified

Part 2 left three failures unclassified because each printed `output=` with
nothing after it, and an empty output cannot separate a real assertion
failure from a missing service from a swallowed error. The coordinator asked
for a re-run with each arm's output captured to a file, then a classification
or an honest second refusal to classify.

**Two of the three are group A — the packet's own shape, proven causally.
The third is not classifiable without a build, and I say why rather than
guessing.**

trace: plan/issues/litmus-1109-t8kw-part2-esmeraldinha-2026-09-14.md (group C)

Regime: Windows / Git Bash, `MINGW64_NT-10.0-26200`, the AT-RISK locus. Every
comparison below that names a second locus ran in the `tillandsias-build`
distro on the same host.

---

## Why all three printed nothing, which turned out to be the first finding

None of the three is silent by accident. Each has an exit path that produces
no diagnostic **by construction**:

- `plan-answer-envelope-citability` 6/21 ends its failing branch in a bare
  `exit 1` inside a `for` loop.
- `citation-frame-and-caller-relation` 8/8 has exactly one silent exit:
  `printf '%s' "$out" | grep -q 'FAILED' && exit 1`. Its other failure path
  echoes a count.
- `project-answer-synthesis-refusal-typed` 3/10 chains `grep -qE … && jq -e …
  && echo ok`, so any link breaking yields nothing.

So "empty output" was never evidence about the system under test. It was a
property of the fixtures, and it is the reason these three cost a second pass.

---

## 1. `plan-answer-envelope-citability` step 6 — GROUP A, jq emits CRLF on MSYS

The arm asserts every cited packet_id appears in the answer text:

```
for id in $(jq -r '.citations[].authority.packet_id' <envelope>); do
    printf '%s' "$ans" | grep -qF "$id" || exit 1
done
```

The envelope from the failing run survived at `/tmp/.litmus-394b-env.json`
(written 17:33Z, inside the 17:21–17:49Z window). Running the arm with the
diagnostic it lacks:

```
ABSENT  plan-methodology-experts-rung1/expert-launch-state-and-ephemerality
PRESENT plan-methodology-experts-rung1/expert-answer-envelope
```

The "absent" id is **visibly present** in the answer text. The bytes explain
it — `jq` writes **CRLF** on this platform:

```
raw jq output:  … r - e n v e l o p e \r \n
loop item 1:    len=68, tail = … i t y \r
loop item 2:    len=53, tail = … e l o p e      (clean)
same id assigned directly with $(...):  len=67, grep -> MATCH
```

`\r` is not in the default `IFS`, so word-splitting leaves it attached to the
end of every field except the last, where command substitution strips it. The
first citation is therefore compared as `…ephemerality\r` and cannot match;
the second, being last, is clean and matches. **Both the product and the
envelope are correct** — the answer does name every packet it cites. The
fixture inherited the platform's line endings and asserted against them.

Same root as the two CRLF arms already in group A, which makes three, and it
is worth naming as one mechanism rather than three coincidences: **on this
locus, text arriving through a pipe carries `\r`, and any fixture that
word-splits or string-compares it is asserting a property of the host.**

## 2. `project-answer-synthesis-refusal-typed` step 3 — GROUP A, a dead port times out before it refuses

The arm requires the refusal envelope's answer to begin with
`… inference_reason=endpoint-unreachable; `. The saved artifact
`/tmp/.litmus-669r/refusal.json` says:

```
unsupported: synthesis question — missing_capability=local-inference
inference_state=not-ready inference_reason=endpoint-timeout; …
```

Everything else the arm checks is correct: `confidence=unsupported`,
`citations` length 0, `freshness` carrying both `source_commit` and
`indexed_at`. The single discriminator is `endpoint-timeout` where the arm
pins `endpoint-unreachable`.

`images/default/lib-inference-state.sh` maps curl 6/7 to `endpoint-unreachable`
and curl 28 to `endpoint-timeout`, probing with `--max-time 1`. The probe's
exact call, same command, only the locus varying:

```
Windows / Git Bash :  curl -fsS --max-time 1 http://127.0.0.1:9/api/tags -> exit 28
tillandsias-build  :  same command                                       -> exit 7
```

A first hypothesis — "curl exits 7 on Linux and 28 on Windows for a dead
port" — was **wrong and is recorded as wrong**: a plain `curl` to that port
exits 7 on both. The variable is the deadline. A connect attempt to a dead
local port takes ~2s on the Windows stack and ~0s in the distro, so the
one-second probe deadline expires first and curl reports 28 instead of 7.

The product is right, the refusal is right, and its reason is *accurate* for
this host: the endpoint really did time out. The fixture pins the vocabulary
one locus produces.

## 3. `citation-frame-and-caller-relation` step 8 — NOT CLASSIFIED, and not for want of looking

This arm runs `cargo test -p tillandsias-plan` and greps its output. Reading
the control flow narrows it usefully without a re-run: the **only** silent
exit is `grep -q 'FAILED' && exit 1`. The other failure path echoes
`FAIL: only $n frame unit pins ran`, and a compile error would leave `n=0`
and take that echoing path. So the empty output establishes that the test run
contained the literal `FAILED` — real failing tests, not a missing fixture and
not a build break.

That is as far as reading goes. **Which** tests failed, and whether they fail
for a Windows reason or a genuine one, needs the `cargo test` run itself.
I did not take it: this host's standing selection rule excludes packets whose
closure needs a release build or a long gate, and the run is both. Routing it
to a capable host is the right move, not running it here badly.

Flagging one thing for whoever does: the arm reports `314.0s` in the timing
table, the slowest in the spec. On a floor-tier host that is close enough to
budget territory that a re-run here could produce a *timeout* rather than the
`FAILED` this arm actually hit — a different red with the same colour, which
is the group A/B confusion this packet exists to prevent.

---

## Summary

| arm | verdict | mechanism |
|---|---|---|
| plan-answer-envelope-citability 6/21 | **group A** | jq emits CRLF; `\r` attaches to word-split fields |
| project-answer-synthesis-refusal-typed 3/10 | **group A** | dead-port connect exceeds the probe's `--max-time 1`; curl 28 not 7 |
| citation-frame-and-caller-relation 8/8 | **unclassified** | silent path proves `cargo test` reported FAILED; needs the build to say why |

Group A therefore grows from 6 to 8, and the CRLF mechanism accounts for
three of them. Nothing was edited.

---
tags: [review, testing, methodology, multi-host, fail-loud, documentation]
languages: [bash, rust, yaml]
since: 2026-08-26
last_verified: 2026-08-26
sources:
  - plan/index.yaml order:803-49re
  - plan/archive/packets-2026-08.yaml order:804-ckst
  - plan/archive/packets-2026-08.yaml order:899-q9di
  - plan/index.yaml order:903-8wsa
  - plan/index.yaml order:904-dprq
authority: high
status: current
tier: bundled
summary_generated_by: hand-curated
bundled_into_image: true
---

# Authorship blindness: the knowledge that lets you build a thing is the knowledge that hides its blind spot

**Not carelessness. A structural property of being the author.**

Three distinct mechanisms, measured on this fleet on 2026-08-25/26, each found
by the person it happened to. They are not three instances of one mistake —
they are three faces of one property, and each needs a different mitigation.

## Why this file could not have been produced by auditing

**Every mechanism below was self-reported by the host it happened to**, and two
of them corrected a more flattering account the coordinator had offered.

That is not incidental and it is the first thing to know about the class: **the
only person positioned to see an authorship blind spot is the author, after the
fact, and only if they are willing to say so.** A reviewer sees the artifact,
not the knowledge that shaped it — so a fleet whose findings arrive only from
review would contain none of these.

The practical consequence: **you cannot go looking for this class in someone
else's work.** You can only notice it in your own and publish it. Which means
the supply depends entirely on whether saying so is cheap.

## The three faces

### 1. Criterion drift — you cannot see your own criterion go stale

**The author of a criterion is the person least likely to notice it has been
superseded, because the improved understanding feels like it was always there.**

MEASURED (803-49re, yolanda). They wrote a `verifiable_closure` reading
*"asserts the guest's share wins (or that the wipe cleared the host entries)"*.
The parenthetical was accurate at filing time. Later work split the packet, and
the clause now permitted closing on evidence that misrepresented *who was
fixed* — Part A helps only hosts that wipe after the fix lands; every existing
user upgrading without a wipe is untouched.

They caught it because closing *felt* wrong before they could say why, and they
made themselves write down why instead of discharging the feeling by acting.

**Why it is worse than a stale script:** a script can be re-run. A criterion
cannot. There is no execution that reveals the drift.

**Mitigation:** record the escape clause AND the refusal together, so someone
who is *not* the author can adjudicate. This is disclosure, not detection.

### 2. Author confound — you build the experiment that cannot detect your fix

**The author of a fix is uniquely positioned to construct the test that cannot
observe it.**

MEASURED (804-ckst, yolanda). They wrote a runbook step that clears two
credentials manually. Hours later, validating their *own* Part A fix — which
clears the same credentials automatically — the obvious procedure would have
run the runbook step first, producing identical end state and proving nothing.
They reordered the experiment to exercise the fix's own call site first, then
read the credential store before the runbook could touch anything.

**They authored the confound without noticing they were building the thing they
would later have to route around.**

**Mitigation:** ask what the *obvious* procedure would prove, not whether it
would pass. Then check whether the fix's own call site is the thing being
exercised, or a bystander with the same effect.

**Credit where it actually belongs, at the author's insistence:** this reads
like foresight and it was not. They went looking for an attribution problem
because they had spent the evening watching four hypotheses die on exactly that
shape — three of them their own — and because the coordinator had asked them to
name the hazard explicitly before the run. **The design followed from the
night, not from insight.** Worth stating, because "they reordered the
experiment" makes the mitigation sound available to a careful person working
alone, and the evidence is that it was available to a primed person working
under supervision.

### 3. Reader staleness — a remembered document is a cached read with no invalidation

**The reader of a document is uniquely positioned not to notice it has been
corrected, because their memory of it is what tells them re-reading is
unnecessary.**

MEASURED (yolanda, 2026-08-26, and the diagnosis is theirs). They cited a
compaction invariant — *"zero removed lines is the property to protect"* — that
had been corrected nine hours earlier:

```
865-ng6r correction landed   0f55e66b9   2026-08-25 13:11
their compaction             5be37c131   2026-08-25 22:24
grep "Do not read that zero" in THEIR tree at that commit  ->  1
```

The corrected text was in their working tree, and the correction is the **next
sentence, in bold**. They read the skill once at session start, formed a durable
belief, and acted on it nine hours later.

**The trap is self-sealing:** every reason to re-read is one you would only have
if you already suspected the memory was stale, and a confident memory generates
no such suspicion.

**A SECOND INSTANCE, ~40 MINUTES LATER, WHILE VERIFYING THIS VERY FILE.** Told
that a bundled cheatsheet must be staged into `images/default/cheatsheets/`,
the same host looked for `images/default/cheatsheets/authorship-blindness.md`,
did not find it, and briefly concluded it was mis-staged. **The mirror preserves
the subdirectory** — it is at `.../cheatsheets/architecture/authorship-blindness.md`.
They had checked a path *constructed from a sentence* rather than the path that
exists, and caught it only by listing the directory instead of trusting the
negative.

That is the same shape as their `cmdkey | grep` that could not match its own
target: **a remembered or reconstructed description standing in for the thing,
and an absence result read as a fact about the world rather than about the
query.**

**NO PROSE MITIGATION IS OFFERED HERE, deliberately.** "Re-read before citing"
is the same class of instruction that failed — the same class as the documented
`tee | head` trap a host read and walked into the same night. The mechanical
version (something that fires when a cited section changed since the citer last
read it) is a real tool and is not something a drain cycle can build. **Naming
the gap honestly beats filling it with advice that will not be followed, and the
empty slot IS the finding — do not let a later edit put the failed instruction
back next to the evidence that it failed.**

## The unifying property, and why it matters for review

**The blind spot is generated by the same knowledge that created the artifact.**
More care does not close it, because care operates on what you can see.

Corollaries the fleet has measured:

- **The union is a state no single branch's gate observes.** Every branch green
  alone, the merge broken — no branch's `--check` compiles the other's
  configuration (731-eupn: green on osx-next and linux-next, `E0063` in the
  union).
- **The author's host is a silent oracle that answers "fine" to every
  portability question it is not asked** (macbook). `ps -o ppid=` worked on two
  lanes of three; GNU-only `du -sb` and `\S` each worked where written.
- **A host fact you do not have is invisible by construction.** A Windows host
  with a 1.2 GiB `target/` cannot see a 40 GiB build-cache sweep threshold that
  a Linux host at 31 GiB is days from tripping.
- **The author of a guard is the last to test its primitive.** An overlap check
  written one cycle was placed before the branch merge and silently reported
  "no overlap" because it read a stale ledger (903-8wsa).

## The portable rule: a negative result is a fact about your query

**When a negative result would be surprising, enumerate rather than query — a
query can only fail the way you spelled it.**

It covers three instances across three subsystems, which none of the
face-specific framings did:

| the query | how it was spelled wrong |
| --- | --- |
| `cmdkey /list \| grep "tillandsias\|vault-shamir"` | pattern could not match `vault-root-token-v1`, its own target |
| `ls images/default/cheatsheets/<name>.md` | path constructed from a sentence, not from the tree (the mirror keeps the subdirectory) |
| `ps -o ppid= -p $$` | spelled in a dialect MSYS does not implement; `2>/dev/null` ate the error |

Each returned a clean, confident, wrong negative. **In all three the fix is the
same move: stop asking, and list.**

### The limit, and the half that applies when enumeration cannot

**Enumeration is only available when the space is small and local** (yolanda,
who supplied this limit against their own generalisation). You can `ls` a
directory and `cmdkey /list` a credential store. You cannot enumerate *"every
way this host reports a parent pid"* — that space has no listing.

So the rule has two halves, and the second is what you reach for when the first
is unavailable:

1. **When the space is enumerable, enumerate.** A negative from a query is a
   fact about the query, not about the world.
2. **When it is not, make the probe report "I CANNOT ANSWER" distinctly from
   "no".** This is what `cycle-checkout-lock.sh ppid-probe` and its `return 2`
   do (899-q9di): a host with no working ppid mechanism gets
   `fail:ppid-probe:no-mechanism`, never a confident "not your lock".

The second half is the more general fix and the harder one to remember, because
the first half is what a careful person reaches for and it silently does not
apply.

**Neither half helps face 3.** A reader who does not know the document changed
has no reason to enumerate anything. That slot stays empty on purpose.

## What to do with it

**Prefer disclosure to care. A heads-up is a falsifiable act; care is not.**
"I considered the siblings" cannot be checked by anyone, including its author an
hour later. "I sent a message naming the surface and they ACKed" exists in two
transcripts and a ledger (yoga).

Concretely:

1. **State the limit of your own result** even when nobody would check. Every
   e2e leg in the v0.4.260826.1 validation volunteered a gap in its own PASS.
2. **Report the COMMAND, not the conclusion**, for any absence claim — an
   absence claim is a claim about your search. A host reported an id "exists
   nowhere in the ledger" having searched two of its three surfaces; pasting the
   grep would have made the missing `plan/archive/` visible to any reader.
3. **Get a second lane to look** before landing a change to a shared surface —
   not because you were careless, but because the state you need to observe is
   one your lane does not have.
4. **When you find one of these in yourself, publish it.** All three faces above
   were found by the person they happened to, reported unprompted, and cost
   nothing to fix once named. None would have been found by review.
5. **Check where being wrong would be EXPENSIVE, not generally.** "Check more"
   is unfollowable advice of exactly the kind this file refuses elsewhere. The
   host who caught two of these described their own behaviour precisely: *"I do
   not check generally more than anyone; I checked where being wrong would have
   been expensive — a claim about my own work, and a claim someone else had
   made about theirs."* Both times the comfortable answer was load-bearing.
   That is a usable trigger; diligence is not.

## A candidate fourth face, NOT filed — one instance is not a mechanism

Two agents each read the other's move as settled and did the same work twice:
one asked *"shall I do it or will you?"* and acted without waiting; the other
read the question as offering them the choice and acted on it. **Neither was
careless, and no amount of care fixes it** — which is this file's property
applied to a two-agent exchange rather than one agent's artifact.

Recorded as a candidate and deliberately not promoted to a face. **One instance
is an anecdote.** The three above each have a distinct mechanism and at least
one independent reproduction; this has neither yet.

## Provenance and attribution

The three mechanisms are **yolanda's**, self-reported across 2026-08-25/26.

The **synthesis** — that they are one property with three faces rather than
three separate findings — is the **coordinator's** (macuahuitl). Recorded at
yolanda's insistence rather than the coordinator's: they produced the
observations and said explicitly that face 3 "had nowhere else to live yet",
and argued that filing the unifying claim under their name would over-credit
them in a file marked `authority: high`.

Both halves are load-bearing and neither produces the file alone. **Three
self-reports without the synthesis are three anecdotes; the synthesis without
the self-reports is unsupported** — and, per the opening section, unobtainable,
because no reviewer could have found any of the three.

Corollaries cited from macbook (the silent-oracle framing, the sibling-lane
rule) and yoga (falsifiable act vs. care, the four-change self-audit).

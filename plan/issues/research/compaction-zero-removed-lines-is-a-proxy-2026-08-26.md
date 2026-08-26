# RETRACTED as a defect report — the rule was already corrected. Kept for the failure mode that produced it.

- **Filed:** yolanda, 2026-08-26, after folding 79 fragments
- **Retracted:** same cycle, on checking the skill text instead of my memory of it
- **Status:** not a defect in the skill. **A defect in how I read it.**

## What I filed, and why it was wrong

I compacted 79 fragments, got `added=2851 removed=2`, and reported that the
skill's "zero removed lines" invariant was a proxy that fails on a correct fold —
proposing that the test move to comment count, packet count, and the four-space
item prefix.

**All of that was already in the skill, and had been for nine hours.**
`skills/meta-orchestration/SKILL.md`, immediately after the 2026-08-03 numbers:

> **Do not read that zero as the invariant** — it was a true measurement of a
> fold that could only APPEND, taken before `set-field` fragments existed…
>
> THE PROPERTY TO PROTECT, stated so a healthy compaction cannot fail it: no line
> is removed EXCEPT one whose field a fragment explicitly reassigned. Comment
> lines, packet count, and the four-space item prefix all survive unchanged.

That is 865-ng6r, landed `0f55e66b9` at 2026-08-25 13:11, after lenovinha and
yoga each stopped a cycle over the same thing. My compaction was `5be37c131` at
22:24 — **nine hours later, with the corrected text present in my working tree**
(verified: `git show 5be37c131:skills/…/SKILL.md | grep -c "Do not read that
zero"` → 1).

So the conclusion I reached was right, the reasoning was sound, and it was
**re-derivation of a fix already in front of me**. My analysis of *why* the zero
held in 2026-08-03 matches the skill's almost sentence for sentence.

## The failure mode, which is the part worth keeping

The correction is not buried. It is the **next sentence** after the number, in
bold. I did not skim past it in the moment — **I never re-read the section at
all.** I read the whole skill once at session start, formed a durable belief that
"zero removed lines is the property to protect", and hours later acted on that
belief without checking whether the document still said it.

**A remembered document is a cached read with no invalidation.** Every reason to
re-read is a reason I would only have if I already suspected the memory was
stale — and a confident memory generates no such suspicion. The document changed
underneath a belief that had no reason to notice.

This is the same shape as two findings already recorded this cycle, applied to
*reading* rather than *writing*:

- **Criterion drift** (on 803-49re): a criterion authored early encodes the
  author's early model, and the author is least likely to notice it was
  superseded, because the improved understanding feels like it was always there.
- **Author confound** (on 899-6pwv): the author of a fix is uniquely positioned
  to build the experiment that cannot detect it.

Here: **the reader of a document is uniquely positioned not to notice it has been
corrected**, because their memory of it is what tells them re-reading is
unnecessary. Three surfaces, one root — a belief formed at time T being applied
at time T+n with no mechanism that fires on the difference.

**I have no mitigation to propose that I trust.** "Re-read before citing" is the
same class of prose instruction that failed here and failed with the `tee | head`
warning earlier the same night. The mechanical version — something that notices a
cited section has changed since the citer last read it — is a real tool and not
one I can build from a drain cycle.

## What remains true and small

Nothing about the rule. One narrow observation for whoever owns the text: **three
hosts have now stopped a cycle on the 2026-08-03 numbers** — lenovinha, yoga, and
me. The first two hit it before the correction existed. I hit it after, from
memory. If a fourth host does this, the anecdote is costing more than it teaches
and could move below the rule or into a footnote — but that is a judgement about
diminishing returns, not a defect, and the current text is correct as written.

## Second finding — SUPERSEDED, and it was fixed the same cycle

This file originally recorded that `append-event` accepted a reference to an
**archived** packet (`582-4wdi`), producing an event attached to nothing that the
gate caught later.

**Already fixed on the trunk.** 896-f8ti was closed this cycle: `resolve()` ended
with `resolve_archived()` — right for reads, wrong for a write — and
`append-event` never asked `is_archived()`. It now refuses at write time, and the
refusal says, verbatim: *"Your reference is not a typo — the target is
finished."*

The one part that was mine and was kept: the packet's title framed this as a
typo case, but **the likely caller is an id that was valid when the author last
read the ledger and archived since** — and the archiver moved 801 packets in a
single cycle. That makes it a routine, expected refusal rather than a rare
mistake, which is why the message reads the way it does. macbook independently
retracted the same "invents packets" framing after finding their packet in
`plan/archive/`.

Two hosts, two days, same archived-ref path — **both while doing something
else, neither by reading the packet.**

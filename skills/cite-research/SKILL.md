---
name: cite-research
description: Use whenever you design or build something people will use — forms, screens, game mechanics, animations, loading states, pacing — so the decision carries its research ("as per research:<id>, ... because ..."), and whenever a user has adjusted one feature several times in a session, to offer a search for research from reputable authorities instead of more guessing. Also the grammar for @research in code, prose and commit trailers. Works for any project in a Tillandsias forge.
license: MIT
metadata:
  author: tillandsias
  trace: spec:research-records
---

# Cite research

A design decision without its reason is a preference. With a research record
behind it, it is a requirement the next session can check.

## The grammar

Cite the **record**, never the paper; the record carries the provenance.
The id is the record's path without `.md`, and it resolves in two places:
the project's `research/` and the shared library at
`$TILLANDSIAS_RESEARCH` (`/opt/research`; `research/` in a Tillandsias
checkout).

| Where | Form |
| --- | --- |
| specs, design notes, plans | `as per research:interaction/fitts-law-1954, the primary action is the largest target and sits where the pointer already is, because movement time grows with distance over width.` |
| code comment | `// @research interaction/response-time-limits-nielsen-1993` (beside `@cheatsheet` lines) |
| commit message trailer | `Research: interaction/response-time-limits-nielsen-1993` |
| replying to the user | "The research on this (Nielsen's response-time limits) says ... so I ..." — plain words, the id in brackets once. |

The sentence that cites must say **the decision**, **the relationship** and
**why the claim supports it**. "Two forms and some buttons" becomes "as per
research:psychology/flow-nakamura-csikszentmihalyi-2014, these two forms are
one task split into two steps with the next goal visible on each, because
flow needs a clear goal and immediate feedback at every step."

Only cite a record whose `claim:` actually supports the decision. If the
decision goes beyond the research (an exact duration, a colour), say "design
choice" next to it. Never cite from memory: if there is no record, find one
(`/find-research`) or write the decision as a choice.

## When to cite

- Every time a spec or design describes how parts relate, how fast
  something responds, how a user is guided, what they will notice.
- Every commit that changes such behaviour carries the trailer.
- Every time you reject a user's suggestion on behaviour grounds: show the
  record, then let them decide.

## The fine-tuning trigger

Keep a rough count, per feature, of how many times the user has asked you
to adjust the same thing in this session (a timing, a layout, a difficulty
curve, a wording). When it reaches about three without converging, offer
once, in these words or close to them:

> That's a lot of fine-tuning for this feature. Shall we search online for
> research from reputable authorities on it, so we tune against what is
> known rather than guess?

- On yes: run `/find-research` with the feature as the question, then come
  back with what the research says and a proposed setting that cites it.
- On no: carry on, and do not offer again for that feature this session.
- Do not offer on the first or second adjustment, and not for features
  where no research could apply (a brand colour, a name).

## Checking a citation

A `research:<id>` must resolve to a file:

```bash
id="interaction/fitts-law-1954"
test -f "research/$id.md" || test -f "${TILLANDSIAS_RESEARCH:-/opt/research}/$id.md" || echo "dangling: research:$id"
```

A dangling citation is a defect: either pull the record in or remove the
claim.

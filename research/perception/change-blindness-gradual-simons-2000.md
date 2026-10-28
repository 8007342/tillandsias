---
id: perception/change-blindness-gradual-simons-2000
claim: >
  Large changes to a scene go unnoticed when they happen gradually, even
  with no visual disruption and with the observer looking straight at them.
applies_to: [ambient-animation, slow-transitions, background-effects, state-change-visibility, atmosphere]
tags: [change-blindness, perception, gradual-change, attention, animation]
sources:
  - url: https://doi.org/10.1068/p3104
    doi: 10.1068/p3104
    kind: peer-reviewed
    title: "Change Blindness in the Absence of a Visual Disruption"
    authors: Simons, Daniel J.; Franconeri, Steven L.; Reimer, Rebecca L.
    year: 2000
    venue: Perception 29(10), 1143-1154
    archived: https://web.archive.org/web/20231029024226/https://journals.sagepub.com/doi/10.1068/p3104
    retrieved: 2026-10-26
authority: primary
strength: replicated
since: 2026-10-26
last_verified: 2026-10-26
status: current
origin: shared
---
# Change blindness for gradual change

@trace spec:research-records

## Claim

Observers fail to detect substantial changes that unfold slowly, without any
flicker, blink or saccade to mask them. Gradual change is itself a mask.

## Evidence

Laboratory experiments with photographs changing over several seconds;
detection rates were low and did not require a visual disruption. The
change-blindness literature as a whole is large and replicated; this paper
is the one that removes the disruption. First pulled in by the ranitas
project (`docs/quiet-awakening.md`) to justify a slow dawn transition that
players should feel rather than watch.

## How it applies

- Use slow, continuous change for atmosphere that should not demand
  attention (time of day, weather, ambient light).
- Do not use slow change for state the user must notice; add a cue.
- A still-image comparison test will not catch a temporal artifact that a
  user also would not consciously see; test time-adjacent frames.

## Provenance

- <https://doi.org/10.1068/p3104>
  archived: <https://web.archive.org/web/20231029024226/https://journals.sagepub.com/doi/10.1068/p3104>
  retrieved: 2026-10-26 (metadata confirmed through the Crossref record)

## See also

- `research:animation/animation-for-attention-harley-2014`

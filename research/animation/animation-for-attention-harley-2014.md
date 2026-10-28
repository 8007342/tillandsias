---
id: animation/animation-for-attention-harley-2014
claim: >
  Interface animation earns its place by directing attention or showing
  cause and effect; to read as caused by the user, the effect must begin
  within about 0.1 s of the action, and decorative motion competes with the
  content for attention.
applies_to: [ui-animation, transitions, micro-interactions, motion-design, onboarding-animations]
tags: [animation, motion, attention, cause-effect, nngroup, transitions]
sources:
  - url: https://www.nngroup.com/articles/animation-usability/
    kind: expert-secondary
    title: "Animation for Attention and Comprehension"
    authors: Harley, Aurora
    year: 2014
    venue: Nielsen Norman Group
    archived: https://web.archive.org/web/20261014014759/https://www.nngroup.com/articles/animation-usability/
    retrieved: 2026-10-26
authority: secondary
strength: expert-opinion
since: 2026-10-26
last_verified: 2026-10-26
status: current
origin: shared
---
# Animation for attention and comprehension

@trace spec:research-records

## Claim

Animation is justified when it directs attention to a change or explains a
relationship (where something came from, where it went). Its only hard
number is the 0.1 s cause-and-effect window, inherited from the
response-time literature.

## Evidence

Expert guidance from a usability consultancy, grounded in attention research
and the response-time thresholds. It gives no millisecond ranges for
transition durations beyond the 0.1 s onset; any specific duration an agent
chooses is a design decision, not a research finding, and must be labelled
as such. Guidance on moving, slow and gradual change is in
`perception/change-blindness-gradual-simons-2000`; on letting users switch
motion off, in `accessibility/wcag-2-3-3-animation-from-interactions`.

## How it applies

- Start a reaction animation within 0.1 s of the user's action.
- Animate to explain (origin, destination, state change), not to decorate.
- Keep recurring animations short; attention paid to motion is taken from
  the content.

## Provenance

- <https://www.nngroup.com/articles/animation-usability/>
  archived: <https://web.archive.org/web/20261014014759/https://www.nngroup.com/articles/animation-usability/>
  retrieved: 2026-10-26

## See also

- `research:interaction/response-time-limits-nielsen-1993`
- `research:perception/change-blindness-gradual-simons-2000`
- `research:accessibility/wcag-2-3-3-animation-from-interactions`

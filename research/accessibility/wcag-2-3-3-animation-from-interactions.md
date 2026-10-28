---
id: accessibility/wcag-2-3-3-animation-from-interactions
claim: >
  Motion animation triggered by a user's interaction must be disableable
  unless the animation is essential to the function or the information,
  because interaction-triggered motion causes distraction, dizziness or
  nausea for some people (WCAG 2.1 SC 2.3.3, Level AAA).
applies_to: [ui-animation, parallax, scroll-effects, reduced-motion, accessibility, transitions]
tags: [wcag, accessibility, reduced-motion, animation, vestibular, standard]
sources:
  - url: https://www.w3.org/WAI/WCAG21/Understanding/animation-from-interactions.html
    kind: standard
    title: "Understanding Success Criterion 2.3.3: Animation from Interactions"
    authors: W3C Web Accessibility Initiative
    year: 2018
    venue: W3C, Understanding WCAG 2.1
    archived: https://web.archive.org/web/20261004110512/https://www.w3.org/WAI/WCAG21/Understanding/animation-from-interactions.html
    retrieved: 2026-10-26
authority: primary
strength: established
since: 2026-10-26
last_verified: 2026-10-26
status: current
origin: shared
---
# WCAG 2.3.3: animation from interactions

@trace spec:research-records

## Claim

A standards-body requirement, not an experiment: give users a way to turn off
motion that their own interactions trigger, unless it is essential.

## Evidence

The W3C's Understanding document states the intent (distraction, dizziness,
nausea from motion such as parallax and scroll-triggered effects) and the
exception for essential animation. It is Level AAA in WCAG 2.1, so it is a
recommendation beyond the AA floor most products target; the underlying
harm is well documented in vestibular-disorder literature the document cites.

## How it applies

- Honour the platform's reduced-motion preference (`prefers-reduced-motion`,
  the OS accessibility switch) for every non-essential animation.
- Treat parallax and scroll-linked motion as the first candidates to gate.
- An animation that conveys state (a progress bar) is essential; a flourish
  is not.

## Provenance

- <https://www.w3.org/WAI/WCAG21/Understanding/animation-from-interactions.html>
  archived: <https://web.archive.org/web/20261004110512/https://www.w3.org/WAI/WCAG21/Understanding/animation-from-interactions.html>
  retrieved: 2026-10-26

## See also

- `research:animation/animation-for-attention-harley-2014`

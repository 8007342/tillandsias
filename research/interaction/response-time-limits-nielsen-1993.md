---
id: interaction/response-time-limits-nielsen-1993
claim: >
  Three response-time limits govern how an interface feels: about 0.1 s feels
  instantaneous, about 1 s keeps the user's flow of thought though the delay
  is noticed, and about 10 s is the limit for keeping attention on the task,
  beyond which progress feedback is needed.
applies_to: [loading-feedback, progress-indicators, latency-budgets, perceived-performance, spinners]
tags: [response-time, latency, feedback, nielsen, perceived-performance]
sources:
  - url: https://www.nngroup.com/articles/response-times-3-important-limits/
    kind: expert-secondary
    title: "Response Times: The 3 Important Limits"
    authors: Nielsen, Jakob
    year: 1993
    venue: Nielsen Norman Group (excerpt from Usability Engineering, 1993)
    archived: https://web.archive.org/web/20261017160720/https://www.nngroup.com/articles/response-times-3-important-limits/
    retrieved: 2026-10-26
authority: secondary
strength: established
since: 2026-10-26
last_verified: 2026-10-26
status: current
origin: shared
---
# Three response-time limits

@trace spec:research-records

## Claim

Nielsen's summary of the response-time literature (Miller 1968, Card et al.
1991) into three thresholds that have held since: 0.1 s, 1 s, 10 s.

## Evidence

A secondary synthesis by a recognised authority, resting on primary
experiments from the 1960s–1990s. The thresholds are order-of-magnitude
guides, not sharp edges. See `interaction/doherty-threshold-1982` for a
primary measurement of productivity against sub-second response.

## How it applies

- Under 0.1 s: show the result, no indicator.
- 0.1–1 s: no indicator needed, but the user notices; avoid stacking delays.
- Over 1 s: show that work is happening. Over 10 s: show how long remains and
  let the user do something else.

## Provenance

- <https://www.nngroup.com/articles/response-times-3-important-limits/>
  archived: <https://web.archive.org/web/20261017160720/https://www.nngroup.com/articles/response-times-3-important-limits/>
  retrieved: 2026-10-26

## See also

- `research:interaction/doherty-threshold-1982`
- `research:animation/animation-for-attention-harley-2014`

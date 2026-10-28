---
id: interaction/fitts-law-1954
claim: >
  The time to move to a target grows with the logarithm of the ratio of the
  distance to the target over its width, so bigger and closer targets are
  acquired faster.
applies_to: [button-sizing, touch-targets, menu-layout, toolbar-placement, hit-areas]
tags: [fitts, pointing, targets, motor-control, touch, layout]
sources:
  - url: https://doi.org/10.1037/h0055392
    doi: 10.1037/h0055392
    kind: peer-reviewed
    title: "The information capacity of the human motor system in controlling the amplitude of movement"
    authors: Fitts, Paul M.
    year: 1954
    venue: Journal of Experimental Psychology 47(6), 381-391
    archived: https://web.archive.org/web/20261004140812/https://psycnet.apa.org/doi/10.1037/h0055392
    retrieved: 2026-10-26
authority: primary
strength: established
since: 2026-10-26
last_verified: 2026-10-26
status: current
origin: shared
---
# Fitts's law

@trace spec:research-records

## Claim

Movement time to a target is a linear function of the index of difficulty,
log2(2A/W), where A is the amplitude (distance) and W the target width.

## Evidence

Fitts's original 1954 tapping, disc-transfer and pin-transfer experiments.
Replicated continuously for seven decades, including for mice, touch screens
and styluses (MacKenzie's variants). One of the most robust laws in HCI.

## How it applies

- Frequent targets should be large and near where the pointer already is.
- Screen edges and corners have effectively infinite width for a pointer.
- On touch, a target smaller than a fingertip costs time and errors; see the
  platform guideline for the minimum, and cite this record for why.

## Provenance

- <https://doi.org/10.1037/h0055392>
  archived: <https://web.archive.org/web/20261004140812/https://psycnet.apa.org/doi/10.1037/h0055392>
  retrieved: 2026-10-26 (metadata confirmed through the Crossref record)

## See also

- `research:interaction/response-time-limits-nielsen-1993`

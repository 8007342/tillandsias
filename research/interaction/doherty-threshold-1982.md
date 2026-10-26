---
id: interaction/doherty-threshold-1982
claim: >
  Productivity increases in more than direct proportion to a decrease in
  system response time, and rises dramatically once response time falls
  below one second.
applies_to: [latency-budgets, perceived-performance, developer-tools, editor-responsiveness, terminal-feedback]
tags: [doherty, response-time, productivity, latency, sub-second]
sources:
  - url: https://archive.computerhistory.org/resources/access/text/2024/03/102751398-05-01-acc.pdf
    kind: primary-report
    title: "The Economic Value of Rapid Response Time"
    authors: Doherty, Walter J.; Thadhani, Arvind J.
    year: 1982
    venue: IBM technical report GE20-0752, scanned by the Computer History Museum (catalog 102751398)
    archived: https://web.archive.org/web/20250720060413/https://archive.computerhistory.org/resources/access/text/2024/03/102751398-05-01-acc.pdf
    retrieved: 2026-10-26
authority: primary
strength: single-study
since: 2026-10-26
last_verified: 2026-10-26
status: current
origin: shared
---
# The Doherty threshold

@trace spec:research-records

## Claim

Doherty and Thadhani's IBM brief: the then-common belief that a two-second
response was acceptable "is not borne out by the facts: productivity
increases in more than direct proportion to a decrease in response time".

## Evidence

Read from the scanned primary. The brief reports Thadhani's measurement that
a programmer completed about 180 transactions per hour at a three-second
system response and 371 per hour at 0.3 seconds, and that the gain "rises
dramatically once system response time falls below one second". It is an
industry report on one population (IBM programmers on 1980s terminals), not a
peer-reviewed study. The popular "400 ms" figure attached to the Doherty
threshold is a later secondary summary; the sentence above is what the
primary says. Cite the primary's claim, not the round number.

## How it applies

- Treat sub-second response as a productivity feature in any tool people
  use repeatedly, not a polish item.
- Budget the whole transaction (user action to complete, displayed reply),
  not only the compute step.

## Provenance

- <https://archive.computerhistory.org/resources/access/text/2024/03/102751398-05-01-acc.pdf>
  archived: <https://web.archive.org/web/20250720060413/https://archive.computerhistory.org/resources/access/text/2024/03/102751398-05-01-acc.pdf>
  retrieved: 2026-10-26 (pages 1-4 read from the scan)

## See also

- `research:interaction/response-time-limits-nielsen-1993`

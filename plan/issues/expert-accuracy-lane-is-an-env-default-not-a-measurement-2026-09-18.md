# the expert-accuracy record writes the lane from an env default, so a cross-host comparison groups by an assertion

- filed: 2026-09-18
- host: lenovinha-silverblue
- trace: order:917-6iwv, order:917-n3n9, order:1254-47xd
- sibling: 1254-47xd is the same shape on the PROBE side (a container demonstrably
  placing a model on the GPU still recorded `container-lane-unverified`). This row is
  the RECORDER side.

## The line

`scripts/record-expert-accuracy.sh`, the `lane=` assignment — find it by the
literal string, not by a line number:

```sh
lane="${TILLANDSIAS_EXPERT_LANE:-cpu}"
```

Unconditional default. The recorder never asks what lane actually served the run,
although the endpoint it just graded against will answer that question in one call.

## Measured, and the pre-fix FAILS line

Two records written 32 seconds apart on lenovinha, same hardware, same resident
runner, nothing rebuilt or restarted between them:

```
2026-09-18T21:23:32Z lane=cpu       model=nomic-embed-text rate=100 graded=33 elapsed=24445
2026-09-18T21:24:04Z lane=gpu-cuda  model=nomic-embed-text rate=100 graded=33 elapsed=24453
```

Eight milliseconds apart. The only thing that changed was an environment variable.
Throughout both runs `/api/ps` reported:

```
nomic-embed-text:latest  size=323150151  size_vram=323150151
```

`size_vram == size` — the model was fully resident in VRAM for BOTH records,
including the one that says `cpu`.

## Why this is urgent rather than tidy

917-6iwv criterion 6 compares models ACROSS HOSTS, and the fleet reads those
records by lane. A comparison grouped by this field is **grouping by an
assertion**: any host can label any lane, and an accelerated host that simply
does not export the variable records `cpu` while serving from VRAM. The series
this packet exists to create cannot answer the question it was built for.

The default was CORRECT when written — 917-n3n9 tracks making the lane anything
but `cpu`, and at that time no accelerator was schedulable anywhere in the fleet.
It is now actively wrong on at least one host and will be wrong on more as lanes
come up.

## The shape this belongs to

Fourth instance in one night of one defect: the probe or recorder HOLDS, or could
hold, the evidence and writes an assertion instead.

- yoga's NPU verdict written as a literal
- pirria's iGPU read as discrete from a BAR size
- yoga's live container lane recorded `unverified` (1254-47xd)
- this: a lane recorded from an env default

## Exit criteria

- The lane is **MEASURED**, not defaulted. `/api/ps` is authoritative and is one
  call: `size_vram == size` proves full residency; `0 < size_vram < size` is a
  partial offload and must be recorded as such rather than rounded to either pole.
- `TILLANDSIAS_EXPERT_LANE`, if kept at all, becomes an OVERRIDE that must AGREE
  with the measurement — a disagreement REFUSES the record rather than preferring
  the variable. A silent override reintroduces exactly this defect for the next
  caller who exports it out of habit.
- NEGATIVE CONTROL, and it is the one that matters: a genuinely CPU-served run,
  with the variable UNSET, records `cpu` — reached by measurement rather than by
  the default happening to be right. A fix that cannot distinguish "measured cpu"
  from "defaulted cpu" has not fixed anything, because today's wrong records are
  indistinguishable from today's right ones.
- A record that cannot establish the lane writes `unknown`, never `cpu`. The
  recorder's own header already argues this for the other provenance fields: an
  absent field reads as "not applicable", a wrong field reads as fact.

## Not in scope

Re-labelling the records already written. They are append-only. The two from
2026-09-18T21:23:32Z and T21:24:04Z are both GPU-served and one says `cpu`; that
pair is the evidence for this row and should stay exactly as it is.

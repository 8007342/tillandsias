## Cycle 2026-08-17T23:37Z (cont.) — both expert-architecture forks integrated

**Result: the expert system can now answer CODE questions, and its index
survives the thing that used to destroy it. Verified on the merged tree, not
taken from the forks' reports.**

- 803-su4n COMPLETED (fork). Verified independently: 19,260 chunks,
  images/inference/entrypoint.sh present as 12 TITLED sections, and the real
  question "what does the inference container entrypoint do with the
  accelerator tuning line at boot?" now answers confidence=retrieved with top
  citation images/inference/entrypoint.sh:147-172 — the span containing line
  165. Before: six spec citations, zero mechanism. That is exactly the PARTIAL
  verdict from this morning's scorecard, closed.
- The fork found the packet HALF-DONE by yoga and found wave 1 had left the
  packet's own worked example unreachable — images/ was under no indexed root,
  so the line the packet cited measured 0 chunks. Verifying against the
  host-side Rust launcher and declaring victory is the measured-the-wrong-
  population pattern again.
- Cost, and it vindicates 408: full cold rebuild 122s on the GPU lane, ~11k
  chunks/min, GPU peak 74% with size_vram == size confirmed. Against ~12 min
  CPU spec-only and ~35 min on yoga. Corpus size has stopped being a cost
  question on this host, which is why 810-k8jy scopes out the remaining config
  languages for lacking a BOUNDARY RULE rather than for cost.
- 801-a2by at implemented (fork), correctly — no forge image baked, so the
  read-only mount into a forge is unexercised. Bare-metal half verified by me:
  warm hit 0.14s x3, and 0.14s again AFTER `rm -rf` of the old tmpfs path. That
  second measurement is the packet: deleting the old location used to mean a
  12-minute rebuild and now means nothing.
- 811-28eh FILED. Getting to that verification took four attempts because the
  dev inference container kept dying: Exited(2) mid-request while serving 200s
  at ~250ms, no OOM, no VRAM pressure, no panic, and podman labelling the
  corpse "(healthy)" for the fourth time (798-tk7b). NOT reproducible on demand
  — I ran the full build as sustained load to trigger it and it passed. Two of
  my hypotheses falsified in the process and both recorded.

WHAT I KEEP GETTING WRONG, sixth instance tonight: I called a 64x6000 batch
"reproduced" after one HTTP 400, then a sweep at every size returned 200. One
observation is not a reproduction. The honest verdict was "intermittent".

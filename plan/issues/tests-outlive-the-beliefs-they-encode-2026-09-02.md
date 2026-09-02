# A test outlives the belief it encodes, and then defends it

Filed 2026-09-02 by yoga, from three instances found by three different hosts in
one day. yolanda named the pattern; this packet records it because three
footnotes in three unrelated packets is how a pattern stays invisible.

## The shape

A test is written to encode what the fleet believes at the time. The belief is
later refuted by measurement. Nothing re-examines the test, because nothing links
a refuted claim to the assertions that were built on it — so the test keeps
passing, and a reader who consults it finds the dead claim pinned green in the
artifact that is supposed to be its authority.

The failure is not that the test is wrong. It is that the test is the LAST place
anyone looks for a belief, and the first place a new reader trusts.

## The three instances, all 2026-08-30 to 2026-09-02

1. **The twin pair, in the fingerprint's own test** (yolanda). The substrate arm
   of `hardware_fingerprint_ignores_substrate_and_separates_real_hardware` named
   its two documents `yolanda` and `yoga` and called them "the twin pair" in a
   comment. The twin claim had been refuted by measurement — different CPU SKUs,
   6c/12t vs 8c/16t — by the very order the test belongs to. A reader of the test
   would have found the refuted assertion green.

2. **The AMD disposition test** (lenovinha). `test_amd_gpu_disposition_fails_closed_without_rocm_runtime`
   asserted `lanes == ["container","host-native"]` for EXACTLY the configuration
   yoga had measured as broken (container lane advertised, `size_vram=0`). The
   assertion changing was the point of the fix, not collateral damage to it.

3. **The accel-probe state assertion** (yolanda). A test asserted
   `accel_gpu=none` unconditionally, on a platform where `enumerate_gpus` has no
   arm at all and returns empty-and-succeeded. The test was right about its real
   property — that no device is MANUFACTURED — and wrong to assume every platform
   can look.

Note the distribution: three different hosts, three different subsystems, no
common author. This is not one person's habit.

## Why the existing guards do not catch it

Everything the fleet built this week aims at the RUN: verify the treatment
reached the process, verify placement rather than a label, verify the gate
passed, verify the measurement happened. All of those check whether a test
EXECUTED honestly. None asks whether what it asserts is still true.

A test that encodes a dead belief passes every one of those checks. It is
green, it is fast, it is deterministic, and it is wrong.

## What would actually help, in rough order of cost

- **Cite the claim, not just the order.** An assertion resting on a measured
  premise should name that premise where the assertion lives, so refuting the
  premise gives a grep target. All three instances above were findable only by
  someone who already knew the belief had died.
- **When a measurement refutes a claim, grep the test corpus for it** as part of
  recording the refutation — a step in the same cycle, not a follow-up packet.
  Instance 1 was caught this way and only because its author happened to be
  editing that file.
- **Fixture names are claims.** Naming a document `yolanda` asserts it describes
  yolanda; naming it `same-gpu-different-cpu` asserts only what it demonstrates.
  Two of the three instances above were legible in the fixture NAME.
- Consider whether a test asserting a state (`accel_gpu=none`) rather than a
  property (`no device is manufactured`) is asserting the thing it means to.
  Instance 3 was one assertion doing both jobs, and only the state half was wrong.

## What is NOT claimed

That any of the three tests was badly written. Each was correct when written and
each was found by its own author or a sibling within days. The claim is only that
nothing in the process links a refuted belief to the tests that encode it, so the
interval between refutation and discovery is bounded by luck.

Related: 805-r98w (instances 1 and 3), 793-zumy (instance 2), 958-w4kq and
959-k3vb (yolanda's sibling packets on greens whose scope is narrower than every
reader takes them to be).

# On Windows the capability probe has no vantage point that sees the machine

Filed 2026-08-30 by yoga from measurements taken by yolanda (windows) during
937-68n4 / 805-r98w preflight. Not reproduced on Linux; the Linux document is
coherent.

## What was measured

The same physical Windows machine, probed two ways, produces two capability
documents and neither describes the machine:

    WINDOWS-NATIVE probe
      cpu_model     "Host CPU"              <- no CPU identity at all
      cpu_physical  16                      <- WRONG; the part is 8 physical / 16 logical
      cpu_logical   16
      gpu_model     "none"                  <- the machine has a Radeon 860M
      accel_ram_gb  "-"                     <- correctly says UNKNOWN, see below

    WSL2-GUEST probe
      cpu_model     "AMD Ryzen AI 7 350 w/ Radeon 860M"   <- correct
      cpu_physical  8   cpu_logical 16                     <- correct
      gpu_model     "WSL2 paravirtual GPU (/dev/dxg)"      <- the PATH, not the silicon
      accel_gpu     present-unusable
      accel_reason  engine-missing:no-vulkan-icd
      npu           none                                   <- the machine has an XDNA NPU
      RAM           the VM's ~7 GB slice, not the host's 15.2 GB

The two documents FAIL DIFFERENTLY, and the difference is the point: the native
probe says the GPU DOES NOT EXIST, the guest probe says it exists and cannot be
reached. Those are opposite claims about one piece of silicon, and a reader
holding either document alone has no way to know the other exists.

So: the CPU fields are right only inside the guest, and the GPU and RAM fields
are right in neither. There is no single vantage point on this platform from
which the machine can be described.

## Why it matters

1. `cpu_physical == cpu_logical == 16` is not a missing value, it is a WRONG
   one. A reader cannot tell it apart from a genuine 16-physical part, and any
   thread-count or per-core reasoning built on it is silently wrong. A probe
   that cannot see the CPU should report unknown, not a plausible number.
2. `gpu_model "none"` on a machine with a Radeon is the same failure with worse
   consequences: it is indistinguishable from a real absence.
3. The two documents cannot be merged. The guest knows the CPU; the host knows
   the RAM and that a GPU exists. Neither knows both, and nothing marks either
   document as partial.
4. Consequence for 805-r98w: this host currently HAS NO FINGERPRINT. Any
   hardware key derived from either document encodes the vantage point as much
   as the hardware, so it cannot be compared with a Linux document. The
   fingerprint tool is right to refuse; the gap is upstream in the probe.

## What is NOT claimed

This packet does not say which document should win, and does not propose that
the native probe read through the guest or vice versa. Both are design questions
for whoever owns the probe. It says only that the current state — two documents,
each confidently wrong about a different half, neither marked partial — cannot
support a hardware comparison and should not silently be used for one.

## Suggested direction

- A field the probe CANNOT observe from its vantage point must be recorded as
  unknown, never as a plausible default. `cpu_physical = cpu_logical` when the
  topology is unreadable, and `gpu_model = "none"` when the enumeration failed,
  are both fabrications a reader cannot detect.

  THE FIX IS SMALLER THAN IT LOOKS, and this is the actionable part: the native
  document ALREADY emits `accel_ram_gb = "-"`. The probe knows how to say
  unknown. It says unknown in one field and invents a plausible 16 in another,
  in the same document, in the same run. So this is not "teach the probe a new
  vocabulary" — it is an INCONSISTENCY between fields that already have both
  behaviours available. Whichever field convention is right, one of these two is
  wrong today.
- Record the VANTAGE POINT in the document (native | wsl2-guest), so two
  documents from one machine are recognisably two views rather than two
  machines.
- Only then can a fingerprint be defined on Windows at all.

Related: 805-r98w (the fingerprint, which refuses rather than guesses — this is
the upstream gap that forces the refusal), 793-zumy / 793-a8e7 (the Windows
GPU lane), and
`plan/issues/inference-container-is-cpu-only-despite-gpu-rocm-tier-2026-08-30.md`
(the Linux mirror: a host-lane verdict that does not survive into the workload's
lane).

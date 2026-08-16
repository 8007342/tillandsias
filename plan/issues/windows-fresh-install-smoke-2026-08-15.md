# Operator fresh-Windows curl-install smoke, 2026-08-15 — narrative + findings

- Date: 2026-08-15
- Source: operator (attended), fresh Windows host, no GH/git/dev tools installed
- Release under test: v0.4.260815.1 (curl installer)
- Packets filed from this session:
  756-dwkm (WSL2 detect-only remediation), 756-s8s8 (restart-claim accuracy),
  756-2jnj (upstream write-readiness guard, child of 424), and the recreated
  756-hn3a (canonical agent identity). Evidence event appended to order 424.

## What worked (a lot)

Curl install on a clean host → tray launch → token login → git attribution →
codex lane launch → device-flow auth → plan experts answered quickly with a
sensible work batch. That is the entire cold-start funnel working on an
untouched machine.

## Findings, in the operator's sequence

1. **WSL2 preflight is detect-only** (756-dwkm). An earlier portable-version
   attempt on the same host correctly detected WSL2 was needed, did not
   install it, and failed on launch until a manual install + restart.
2. **Restart-required claim did not match observed behavior** (756-s8s8).
   The curl installer added the account to the hypervisor admins group and
   demanded a restart; the operator skipped the restart and everything
   through codex-lane provisioning worked anyway. Message should be
   conditional on an actual effective-membership/needs probe, and name what
   breaks.
3. **Late-detected write failure lost work** (756-2jnj, evidence on 424).
   The codex forge drained work, then its first push 403'd at GitHub
   ("Permission to 8007342/tillandsias.git denied to 8007342") — the
   credential guard had said ok because it probes reachability, not
   authorization. The mirror's verified-ack correctly refused to fake
   durability, and the new check-forge-findings-persisted.sh guard
   (741-3y48 family) flagged unpersisted:unpushed, so the forge serialized a
   full recovery handoff instead of losing everything silently — the
   fail-loud investment paying for itself on its first real incident.
   Two commits were still lost locally (lease bc11044f, findings 358903fc);
   their content is recreated in this fragment set.

## Root-cause note for the 403 itself

The token identified AS the repo owner and was still denied push — consistent
with a token lacking the repo-write scope/permission (fine-grained PAT without
contents:write, or classic token without repo scope), not with a wrong
account. The operator logged in with a pasted token this session. 756-2jnj's
probe turns exactly this state into a loud pre-drain verdict; the WINDOWS
host should re-run its lane after the guard ships and re-seed the token with
push scope if the probe says unauthorized.

# Order 273 (agent attach runs login flow) is confounded by the guest-disk wall — re-test before fixing (2026-07-11)

- class: research (reframe / de-risk a linux packet)
- filed by: macOS operator session 2026-07-11
- affects: plan/index.yaml order 273 (guest-agent-attach-runs-login-flow, linux)

## Two different captures, two different failure modes

- **2026-07-10** (5GB substrate, guest headless v0.3.260710.2): agent attach
  PTY streamed the interactive github-login flow, then PtyClose code=**0**.
  This is what order 273 was filed on.
- **2026-07-11** (this session, fresh substrate BEFORE the disk fix): agent
  attach PTY streamed the forge-base image build (558 dnf packages) then died
  `needs NNN MB more space on the / filesystem` → `Error: building at STEP
  "RUN microdnf install …"` → PtyClose code=**1**. Root cause: the ~5GB
  Fedora default guest disk (fixed in order 294 → 250G, 249G free).

The 2026-07-10 substrate was 5GB (and at times order-281-corrupt). Both
captures are therefore contaminated by the disk wall: the launch may never
have reached `run_opencode_mode` because the forge image the agent needs
could not build. The "login flow, code=0" symptom cannot be trusted as proof
of a guest-dispatch bug.

## Action (before any dispatch fix)

Re-run an agent attach on the **250G** substrate (order 294) with
`TILLANDSIAS_PTY_DEBUG=1`, after the forge-base image has successfully built,
and read the tee:

- If the agent TUI now paints → **273 is MOOT** (it was the disk); close it.
- If the login flow STILL appears with a fully-built forge image → the
  dispatch bug is real; the original order-273 candidate paths
  (ensure_git_login / ensure_provider_auth interactive prompts;
  require_desktop_user_session lane classification) apply.

Needs the operator's PAT (agent leaves are auth-gated), so it is an
operator-attended re-test — flagged for the next macOS interactive session.

## Ledger hygiene note

Order 273's `events:` list has picked up a mis-placed DUPLICATE of order
264's forge-budget decision/progress/completed events (a merge artifact;
YAML-valid, so validate-yaml + plan-orders did not catch it). Linux, as the
ledger owner for these packets, should prune the duplicate block from 273.

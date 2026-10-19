# Tasks — observatorium-deploy-on-stable

Packet `1798-khw6`.

## 1. Deploy ref mechanics

- [x] 1.1 `scripts/advance-deploy-ref.sh`: fast-forward, restore commit, no-op on
      an identical tree, verify by tree on origin, `--dry-run`, refusal grammar.
- [x] 1.2 `scripts/lua/test-advance-deploy-ref.lua`: 10 arms against a bare
      remote that refuses rewinds (arm 0 proves the guard is live).

## 2. Promotion

- [x] 2.1 `scripts/promote-stable.sh` step 4 on promote and demote; dry-run names it.
- [x] 2.2 `scripts/test-promote-stable-evidence-gate.sh`: a promotion advances
      the ref; a refused advance is not a promotion (30/30).
- [x] 2.3 `litmus:stable-channel-shape`: promotion is the only writer of the ref.

## 3. Push gate

- [x] 3.1 `pre-push-local-gate.sh`: `refs/heads/deploy/*` joins the tag-on-main
      exemption, restore commits judged by tree.
- [x] 3.2 `scripts/test-gate-stamp-scope.sh` cases 14–16 (17/17). Case 14 is red
      on the pre-change hook.

## 4. Docs and seeding

- [x] 4.1 `deployment.md` Cloudflare settings; `methodology/versioning.yaml`
      `stable_channel.promotion`.
- [x] 4.2 Seed `deploy/observatorium` at the current `stable` commit.
- [ ] 4.3 Operator: create the Worker with the settings in `deployment.md`
      (the forge's Cloudflare access is read-only).
- [ ] 4.4 Follow-up packet: darwin/msys run of `test-advance-deploy-ref.lua`, then
      a `scripts/gate-steps.d` step.

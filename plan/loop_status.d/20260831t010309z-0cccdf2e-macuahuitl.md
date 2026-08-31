## Cycle — forge smoke test SUCCEEDS end to end (macuahuitl)

The operator's tray-launched claude forge completed a full directed cycle:
synced to linux-next, PROVED the mirror->GitHub write path (relay-verified
twice — contrary evidence recorded on p0 809-w2xy: the denial did not
reproduce at 01:00Z), obeyed the stop-rule on the embed fix (root cause is
an OPERATOR-OWNED tracked-settings env leak, not forge plumbing), and
filed three plan/issues packets (expert-surface calibration recon; the
dev-loopback env leak incl. inference+spec endpoint blast radius;
project-info descriptive defects). Nothing claimed, tray untouched, clean
exit directed. Daily release v0.4.260830.5 PUBLISHED (prerelease/unstable
channel) — fleet daily-channel smoke is now unblocked.

OPERATOR PLAIN ASKS (updated): 1) tray click acceptance continues (five
freeze fixes in; menu-mute-during-launch is the remaining known defect);
2) DECIDE the settings env leak: your dev loopback env block in TRACKED
.claude/settings.json leaks into every forge, poisoning embed/inference/
spec endpoints — move it to untracked settings.local.json, or forge-image
override? (full story: plan/issues/dev-loopback-inference-env-leaks-into-
forge-settings-2026-08-31.md); 3) Apple x3; 4) Partner Center; 5) release-
to-main call (daily channel now live as the staging you wanted).

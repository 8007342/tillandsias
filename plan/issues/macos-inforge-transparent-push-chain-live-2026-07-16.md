# E2E REPORT: macOS in-forge transparent-push chain LIVE — mirror rewrite + clean push dry-run; only the operator credential remains

- Date: 2026-07-16 (probe series 09:40→10:20Z)
- Class: e2e report (PASS on the credential-free chain) + goal burndown
- Filed by: macos-Tlatoanis-MacBook-Air-fable5-20260716T0924Z
- Stack: tray/guest 0.3.260716.5 (git 35253356) installed; guest images rebuilt on-demand from its embedded assets (git, forge-base, forge all at v0.3.260716.5)
- Related: order 349, plan/issues/inforge-meta-orchestration-transparent-push-2026-07-16.md (Windows sibling), plan/issues/macos-clone-lane-push-remote-misalignment-2026-07-16.md (RESOLVED below), windows-260716-2, order 227

## Probe series (all unattended, one-shot `--opencode … --prompt`)

1. **09:40Z — lane refused (GOOD fail-loud)**: fresh VM boot, the
   windows-260716-2 mint-fails-loud fix refused the lane with "Vault
   container is not running". Root cause: `run_opencode_mode`'s ad-hoc
   bring-up chain predates the order-227 dependency model and never
   ensured vault (and ForgeLaunch's graph node lacked a Vault edge even
   for the modeled lanes). FIXED this cycle (35253356): Vault edge added
   to ForgeLaunch's DEPS; opencode lane ensures vault via spawn_blocking
   before the mint. Next boot: lane bootstraps vault itself, launches.
2. **10:00Z — mirror rewrite LIVE (order-349 criterion 2 PASS)**:
   `/home/forge/.gitconfig` carries
   `url.git://tillandsias-git/tillandsias.insteadOf=https://github.com/8007342/tillandsias.git`
   — windows' `parse_gitdir_origin_url` git-less fallback works on the VZ
   guest. Remaining skew: `git remote -v` still showed the RO staged path
   because the version-tagged forge image predated the lib-common fix.
3. **10:15Z — full chain green after image refresh**: removed all guest
   forge/git images; the lane rebuilt them on-demand from the fresh
   embedded assets. In-forge evidence: `remote.origin.url` =
   `https://github.com/8007342/tillandsias.git` (clean), `git remote -v`
   resolves both fetch and push to `git://tillandsias-git/tillandsias`
   via the rewrite, and **`git push --dry-run origin HEAD` is clean**
   through the mirror. The lane tore down cleanly (exit 0) on every probe.

## Residual for the operator goal (full in-forge /meta-orchestration with real push)

- **ONLY the vault github token** (`secret/data/github/token` 404;
  rechecked 09:25Z). A real push now transits the mirror and fail-closes
  at the verified-ack relay without the token — by design
  (windows-260716-2 + order 318). Once the operator runs
  `--github-login`, the existing chain should carry a full cycle's push
  end-to-end. No code gaps remain on this host's lane as measured.

## Resolved / updated by this evidence

- plan/issues/macos-clone-lane-push-remote-misalignment-2026-07-16.md —
  RESOLVED live (both halves: `git -C` origin resolution in lib-common
  559190c3 + bare-gated insteadOf; verified in-lane post image refresh).
- Guest image tag drift datum for the FRESHNESS burndown (orders 370-372/
  334): before refresh the guest simultaneously held forge-base
  v0.3.260715.6, git v0.3.260715.2, and on-demand-built v0.3.260716.5
  copies — three generations of entrypoint behavior coexisting. The
  on-demand ensure rebuilds MISSING tags but never retires stale ones.

## Operator handoff (loop window closed 2026-07-16 ~05:30 PDT / 12:30Z)

Token was still 404 at every recheck through 12:27Z; the 5-hour macOS
loop window closed without the credential. Everything else is DONE and
SHIPPED (v0.3.260716.7 proved from a wiped substrate). To finish the
goal, in order:

1. Operator: `/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray --github-login`
   (interactive device-code; stores the token in the guest vault).
2. Any macOS cycle then runs the closing gate:
   `--opencode /home/forge/src/tillandsias --prompt "Use the /meta-orchestration skill"`
   — a FULL cycle: the in-forge agent's commit pushes through
   git://tillandsias-git (rewrite verified live), the mirror relays with
   the vault token (order 318 verified-ack), and order 349's last
   criterion (real mirror push) + the operator goal both close with that
   one run. Record the evidence on order 349 and this file.

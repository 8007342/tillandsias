# 349 closing run — macOS current-build forge live config, mirror, and TLS parity (2026-08-16)

- **Host:** Apple Silicon (M1), macOS 26 · **Agent:** macos-tlatoanis-macbook-air-fable5-20260816t0923z
  (operator-authorized hourly meta-orchestration loop; the packet's deliverable
  says *attended* — this run was unattended-but-operator-directed, stated
  plainly; operator countersign invited on the packet)
- **Full transcript:** `target/smoke-e2e/07-349-closing-run.log` (macOS host)

## Criterion 1 — identity before behavior (PASS)

- Local build from THIS checkout: `dist/Tillandsias.app`, tray
  `git 7bc647f6` (= osx-next HEAD at run time), ad-hoc signed with the VZ
  entitlement, `built 2026-08-16T09:28:44Z`.
- Guest binary: bundle sha `32b488cc…0063` ≠ previously staged release sha
  `701c2a01…706b` → launch **restaged the current guest binary** and the
  enclave **rebuilt every image on-demand keyed on the new digest**
  (proxy/router/git/vault/forge-base/forge at tag v0.4.260815.1,
  `digest_missing` → rebuild), so the release-download fallback could not
  mask skew. Post-run `--diagnose --json`: `guest_binary_staged_matches_bundle:
  true`, VM stopped clean.
- In-forge checkout identity recorded in-transcript (host `forge-tillandsias`,
  seed branch `main` @ 1496e89f — the known-stale seed, 763-munc; harmless to
  this packet's behavior evidence and stated for honesty).

## Criterion 2 — gitconfig + mirror rewrite (PASS, re-verified live)

```
file:/home/forge/.gitconfig  url.git://git-6no98mm4837ff0lpr5c0/tillandsias.insteadof https://github.com/8007342/tillandsias.git
origin  git://git-6no98mm4837ff0lpr5c0/tillandsias (fetch)
origin  git://git-6no98mm4837ff0lpr5c0/tillandsias (push)
```

`--show-origin` resolves `/home/forge/.gitconfig`; the GitHub URL rewrite
resolves to the per-project Tillandsias mirror (659-8faj form).

## Criterion 3 — REAL mirror push + TLS parity (PASS)

- `git fetch origin` → rc 0 (mirror serves current upstream refs).
- **`git push origin HEAD:refs/heads/probe/349-close-20260816` → rc 0**, and
  the ref **appeared on the real GitHub repo** (host-side
  `git ls-remote origin` showed `1496e89f… refs/heads/probe/349-close-20260816`)
  — the transparent chain in-forge → mirror → authenticated upstream relay is
  proven end-to-end with a real, verified, then removed ref (host-side
  `gh api DELETE …/git/refs/heads/probe/349-close-20260816`; re-check: gone).
- TLS parity, all through the enclave's interception CA, with the no-override
  proof `no-ca-override-env` printed first:
  `git ls-remote https://github.com/...` ✓ · `curl-tls-ok` ✓ ·
  `node-tls-ok 200` ✓ · `python-tls-ok` ✓.
- No host or repository config was edited; no per-client CA variables set.

## Findings recorded en route (not blockers)

1. **Mirror pre-receive denies ref deletion** (`ref deletion is disabled`) —
   deliberate hardening against destructive upstream relay. Consequence:
   probe/scratch refs pushed through the mirror must be cleaned host-side
   (as done here). Worth one line in the mirror family's docs (749/755).
2. The in-forge agent caught my prompt's `delete_rc` measuring `tail`'s exit
   rather than git's (the recurring pipe-exit trap) and corrected the
   evidence itself — the truthful rc was 1, by policy above.

## Verdict

All three exit criteria hold with live, current-build evidence. The oldest
unscored stable-milestone packet is closed pending operator countersign of
the attended clause.

# Release Runbook

The release rule is: spend GitHub-hosted minutes only for work that needs
GitHub-hosted platform runners, OIDC-backed Cosign signing, or publication to a
GitHub Release. Verification, litmus checks, dashboard generation, and merge
work happen locally first.

## Local release gate

1. Update the local release branch:

   ```bash
   git fetch --prune origin
   git switch linux-next
   git merge --ff-only origin/linux-next
   ```

2. Reconcile release branches locally if needed. Do not use GitHub Actions just
   to merge branches or refresh dashboards.

3. Run the local preflight:

   ```bash
   scripts/release-preflight-local.sh
   ```

   For a quick smoke before a full pass:

   ```bash
   scripts/release-preflight-local.sh --fast
   ```

   To probe the Linux Nix release targets locally before dispatching the hosted
   release:

   ```bash
   scripts/release-preflight-local.sh --nix-probe
   ```

4. Review and commit any generated local evidence, especially
   `docs/convergence/centicolon-dashboard.md` and
   `docs/convergence/centicolon-dashboard.json`.

5. Push the release ref only after the local gate passes:

   ```bash
   git status --short
   git push origin HEAD
   ```

## Hosted release

Dispatch `.github/workflows/release.yml` only after the local gate has passed:

```bash
gh workflow run release.yml --ref "$(git branch --show-current)" -f version="$(tr -d '[:space:]' < VERSION)"
```

The hosted workflow is intentionally limited to the remote-only release work:
Linux/macOS/Windows builds on the target runners, artifact sanity checks,
Cosign keyless signing through GitHub OIDC, release upload, and rolling tags.

Do not run hosted CI, litmus metadata, convergence dashboard, cache warm, or
integration jobs for normal releases. Those checks are local through
`scripts/release-preflight-local.sh` and `scripts/local-ci.sh`.

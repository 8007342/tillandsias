# GitHub E2E Lifecycle — Interactive Troubleshooting Packet — 2026-06-20

**Filed:** 2026-06-20T20:30Z
**Origin:** Operator request — enumerate UX glitches in the full GitHub flow
**Trace:** `spec:gh-auth-script`, `spec:remote-projects`, `spec:git-mirror-service`

## Goal

Run a full operator-attended GitHub lifecycle on a **mutable Linux host** and enumerate
every UX glitch encountered, so they can be reduced to discrete fix packets.

The lifecycle under test:

```
1. tillandsias --github-login       (login / token store)
2. tillandsias --list-cloud-projects  (list repos from Vault token)
3. tillandsias . --bash              (open forge shell for current project)
4. git clone <repo> / cd <project>  (clone a project inside forge)
5. git add / commit / push          (push a change from inside forge)
6. git log, git status              (verify state)
```

## Known Issues To Reproduce

### P1 — Push from forge blocked
Inside the forge, `git push origin` fails with "could not read Username" (no credential
channel — see order 66). This must be fixed before the rest of the push lifecycle works.

### P2 — UX glitches on login (known, not fully enumerated)
Operator note: "We can login and list projects, and checkout (with a few UX glitches
we need to enumerate through an interactive run)". Specific glitches TBD from the run.

### P3 — Push to remote not always reliable from host
The operator noted "we've not been always able to push to remote" from the host (outside
the forge). The Vault credential channel works for `--list-cloud-projects` but not for
raw `git push` from the working tree. Root cause: `gh auth login` token (OAuth `gho_`)
vs the stored PAT (`github_pat_`) are different tokens with different scopes/permissions
stored in different locations; the git credential helper only activates for one of them.

## Interactive Run Protocol

Run on mutable Linux host (big-pickle), operator-attended:

```bash
# 1. Verify login state
tillandsias --list-cloud-projects

# 2. Launch forge shell for tillandsias repo
tillandsias . --bash

# Inside forge:
# 3. Verify git remote
git remote -v
git fetch origin

# 4. Make a trivial change and commit
echo "# test" >> /tmp/probe.md
git add /tmp/probe.md  # (adapt to a real in-repo file)
git commit -m "chore(e2e): interactive lifecycle probe"

# 5. Attempt push — observe UX
git push origin <branch>

# 6. Verify from host
git ls-remote origin | grep <branch>
```

Capture: exact error messages, timing, any credential prompts, any missing binaries.

## Action Items

- `github-e2e/interactive-run`: operator-attended run on big-pickle; file observed
  glitches as sub-packets below
- `github-e2e/login-ux-glitch-list`: enumerate `--github-login` UX issues
  (device-flow prompts, error messages, retry behaviour)
- `github-e2e/list-projects-ux`: enumerate `--list-cloud-projects` latency / error UX
- `github-e2e/clone-ux`: enumerate forge-side clone UX (missing tools, slow pull, auth)
- `github-e2e/push-from-forge`: fix push inside forge (depends on order 66)
- `github-e2e/push-from-host`: fix `git push origin` from the working tree using the
  `gh`-managed credential (ensure `gh auth setup-git` is called at init or on login)

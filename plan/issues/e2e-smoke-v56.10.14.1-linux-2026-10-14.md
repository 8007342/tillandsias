# v56.10.14.1 e2e smoke — linux PASS (2026-10-14)

Release: https://github.com/8007342/tillandsias/releases/tag/v56.10.14.1. Smoke requested by the coordinator (macuahuitl-fedora) after the release published and its ledger row landed (5442f5375, land 429).

| Platform | Host | Result | Evidence |
|---|---|---|---|
| linux | lenovinha-silverblue (Fedora Silverblue) | PASS v56.10.14.1 | cold-start acceptance run v56.10.14.1-20261014200323 on a sealed, no-D-Bus nested substrate. Verdict: `ok:cold-start-acceptance:v56.10.14.1:served:https://www.macron.dev.localhost:18443:http=200:lakanoa-shape=built-nested-served:router-failure=step-qualified:recovered:project=03a46e1f3041028e4953002246a7846f3c65b5b6` |

## Sections

| Section | Result | What was observed |
|---|---|---|
| Fresh install | PASS | Installer sha256 `0b58390f…2273` matches SHA256SUMS. install rc=0; proxy, git, vault, inference and router all SUCCESS. |
| Forge on macron.dev latest | PASS | The forge was up on attempt 1 after 50 s and holds `03a46e1f3` (latest; the notebook-convention merge). The source was hydrated 5 s after forge-up. |
| publish_local auto | PASS | Runtime wrangler; https://www.macron.dev.localhost:18443 returned HTTP 200 with title "Mācron — learning by building", fetched over verified TLS. |
| Lakanoa-shaped project (step 7b) | PASS | Before its build it was refused, naming the build command (`npm ci && npm run build`). After the in-forge build it was served: HTTP 200, LAKANOA-SHAPE-BUILT. |
| Forced router failure and recovery | PASS | The failure was qualified to its step: `runtime_unavailable: podman failed at step router (exit)`, remedy=operator. After recovery: HTTP 200, last_failure=false. |
| Host credentials untouched | PASS | Keychain item metadata for service=tillandsias was identical before and after. The operator's containers and the netavark network dir were unchanged. Host repo-local `user.*` is empty. |
| 1668-8jmq: no git identity prompt | PASS | install.txt and launch.txt contain no identity prompt and no mention of an identity. The run had no operator step. |
| 1668-8jmq: a forge commit has an identity without manual config | PASS (unsigned path) | With no GitHub App sign-in in the substrate, the forge seeded a project-derived identity: `Tillandsias forge (macron.dev) (c487a9826bb0 · tillandsia-juncea) <forge+macron.dev@users.noreply.tillandsias.invalid>`. It is in git's XDG global file (`/home/forge/.config/git/config`); there are no `GIT_AUTHOR_*`/`GIT_COMMITTER_*` env vars. A scratch commit in the forge succeeded with that author. It is not the operator's identity. Forge log: `git-identity | configured from project as tillandsia-juncea on c487a9826bb0`. |
| 1668-8jmq: forge commits authored from the GitHub App identity | NOT RUN | It needs a GitHub App sign-in inside the substrate, which is a device login on the operator's account. That is an operator step this host may not take on its own. |
| macron.dev note (public push) | NOT RUN | The operator has not said yes to public pushes in this host's session. |

## Provenance

- Run and recorded by lenovinha-silverblue on 2026-10-14, at the coordinator's GO.
- The driver is scripts/lua/cold-start-acceptance.lua at origin/linux-next f5a5e4248, run with `--keep` so the forge's git identity could be inspected after the verdict.
- The substrate was then removed. The evidence directory stays at target/work/cold-start-acceptance/v56.10.14.1-20261014200323/evidence on lenovinha.

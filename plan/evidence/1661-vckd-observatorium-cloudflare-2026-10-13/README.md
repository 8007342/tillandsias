# 1661-vckd — observatorium Cloudflare Workers Builds proof (2026-10-13)

The same build Workers Builds runs (root directory `observatorium`, Build
command `npm run build`, deploy `npx wrangler deploy`), executed by
`harness.sh.txt` in a FRESH container on a private podman store, limited to
the free plan's 2 vCPU / 8 GB, from a `--depth 1` clone of the branch.

| image | npm ci | npm run build | timed total | node tests | flutter analyze | flutter test | wrangler --dry-run |
|---|---|---|---|---|---|---|---|
| ubuntu:24.04 (Workers Builds' image) | 3 s | 292 s | 295 s | 10 pass / 0 fail | No issues found | 7 passed | 47 files read from build/web |
| fedora:44 | 3 s | 274 s | 277 s | 10 pass / 0 fail | No issues found | 7 passed | 47 files read from build/web |

Build phases (ubuntu / fedora): tillandsias-plan 160.4 / 158.1 s (pinned
rustup + repo toolchain, release build), git-history 20.2 / 16.8 s
(unshallowed), collect 1.7 / 1.6 s, precompute 0.2 / 0.2 s, flutter pub get
12.1 / 13.2 s, flutter build web 35.1 / 35.8 s. Well inside the 20 min
Workers Builds limit and the coordinator's 12 min bar (option a).

The ubuntu run predates the req-id stamp on the observatorium spec, so its
CentiColon residual is null (the grader refused the unstamped spec); the
fedora run is at c19f883b9, after the stamp. The operator's containers,
networks and images were recorded before and after each run: unchanged.
Base tools (curl, git, compilers, Node 22.23.3 pinned by SHA-256) are set up
first and excluded from the timed budget, as Workers Builds preinstalls them.

# 1663-6mns — v56.10.13.1 Linux cold-start acceptance (2026-10-13)

**PASS**, run `v56.10.13.1-20261013235228`, on lenovinha with privileged podman-in-podman:

    ok:cold-start-acceptance:v56.10.13.1:served:https://www.macron.dev.localhost:18443:http=200:lakanoa-shape=built-nested-served:router-failure=step-qualified:recovered:project=03a46e1f3041028e4953002246a7846f3c65b5b6

The run covered:
- the installer's sha256 matched SHA256SUMS;
- macron.dev at `03a46e1f3` (the notebook merge) served by Wrangler over verified TLS;
- step 7b, the lakanoa-shaped project: refused before its build, naming the build command, and served with the built marker afterwards;
- a forced router failure (step-qualified) and its recovery;
- host keychain metadata identical before and after.

The first run (`failed-run-transcript.txt`, run `v56.10.13.1-20261013224041`, macron.dev `e04a3293`) FAILED. `publish_local` said `source_not_found` because the driver published while the forge was still cloning the project. `forge-source.txt` from the passing run shows it:
- at forge-up: no HEAD, 0 tracked files, 53 MB copied, log `cloning from git://…`;
- 5 s later: `clone successful`, 55 files, 176 MB of a 348 MB tmpfs.

The HOT-storage budget did not refuse it. The driver now waits for the checkout, and 1676-4j53 makes `publish_local` name that state instead of answering `source_not_found`.

Side observation: the forge log shows `hot-paths | FAILED: cp /opt/cheatsheets-image/. -> /opt/cheatsheets/ … preserving times … Operation not permitted` inside the nested substrate.

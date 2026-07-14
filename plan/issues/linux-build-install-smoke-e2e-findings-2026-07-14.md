# Linux local-build e2e findings - 2026-07-14

- host: Linux mutable (`macuahuitl.ayahuitlcalpan.com`), branch `linux-next`
- commit tested: `d8af7540`
- discovered_by: `/build-install-and-smoke-test-e2e`
- evidence: `target/build-install-smoke-e2e/20260714T194724Z/`
- agent: `linux-tlatoani-codex-20260714T1938Z`

## Gate results

| Gate | Result |
|---|---|
| 1 build + install | **FAIL** - pre-build policy/litmus suite |
| 2 destroy Podman substrate | NOT RUN - build did not pass |
| 3 cold `tillandsias --debug --init` | NOT RUN |
| 4 forge `/meta-orchestration` | NOT RUN |

No Podman reset or other destructive substrate action occurred. The failed
build's generated version and trace artifacts were discarded after evidence
capture.

## Finding 1: pre-receive YAML fixture violates no-Python policy

- packet: `pre-receive-yaml-fixture-no-python-policy`
- owner: Linux
- status: ready
- evidence:
  - `01-build-install.log:1716` identifies
    `scripts/test-pre-receive-yaml-gate.sh:22`.
  - `01-build-install.log:1718` reports `Python scripts detected`.
  - `01-build-install.log:2767` records the aggregate `no-python-scripts`
    failure.
- reproduction: `scripts/check-no-python-scripts.sh`
- root cause: the order-316 fixture invokes `python3 -c` with PyYAML to parse
  its generated YAML, although the repository policy rejects Python scripts.
- next action: replace the fixture parser with the repository's sanctioned
  YAML validation path, then pin the fixture and no-Python checks together.

## Finding 2: git-mirror audit documents absent from image mirror

- packet: `git-mirror-audit-cheatsheet-image-sync`
- owner: Linux
- status: ready
- evidence:
  - `01-build-install.log:1810-1815` records
    `litmus:cheatsheet-host-image-sync` failure.
  - The host-only files are
    `cheatsheets/concurrent-git/git-mirror-architecture-audit.md` and
    `cheatsheets/concurrent-git/git-mirror-enterprise-practices.md`.
- reproduction:
  `scripts/run-litmus-test.sh cheatsheet-tooling --phase pre-build --compact`
- root cause: the two order-315 host documents were merged without their
  corresponding `images/default/cheatsheets/concurrent-git/` copies on
  `linux-next`.
- next action: synchronize both documents into the image mirror, update any
  generated index required by the cheatsheet tooling, and rerun the pre-build
  litmus.

## Release disposition

The local-build e2e gate is red, so this cycle does not qualify for release or
published-release smoke testing. Resume the destructive smoke sequence only
after both pre-build failures close and gate 1 passes.

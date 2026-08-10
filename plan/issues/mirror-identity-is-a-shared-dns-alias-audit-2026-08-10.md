# Mirror service identity — shared-alias audit (2026-08-10)

Classification: `research/`
Packet: 659-8faj, a slice of 606-bvnp
(`git-mirror-cross-project-service-identity`, p0), which is one of the four
remaining dependencies of 451 (`release-blocker-v0.5`).

606-bvnp is a 6-hour security-design packet. This audit closes the cheapest and
most load-bearing part of it: establishing **what the identity model actually is
today**, by measurement, so the design work is decidable rather than speculative.

## Exit criterion 3 is violated today, and it is measurable in one command

The criterion: *"two simultaneous projects resolve only their opaque unique
mirror hostnames and fixed repository paths."*

What the implementation does — `build_git_run_args`, `main.rs:2974-2977`:

```
--network-alias git-service
--network-alias tillandsias-git
```

Both aliases are **constants**. The container NAME is per-project
(`tillandsias-git-{project}`) and the volume is per-project
(`tillandsias-mirror-{project}`), but the DNS identity is shared by every
project's mirror.

Clients address projects as a **path on that shared name**
(`images/default/lib-common.sh:503, :752, :764, :794, :806`):

```
git://tillandsias-git/${TILLANDSIAS_PROJECT}
```

So project separation rests on a path component, not on identity.

### Measured

Two containers were started on `tillandsias-enclave`, each carrying the exact
aliases the product assigns (`tillandsias-git`, `git-service`) — simulating two
projects' mirrors running at once. From a third container on the same network:

```
$ getent ahostsv4 tillandsias-git
10.0.42.17      STREAM tillandsias-git.dns.podman
10.0.42.18      STREAM tillandsias-git.dns.podman
```

**Two A records for one name.** Podman's DNS returns both and the client picks;
`git://tillandsias-git/projectA` is therefore free to connect to project B's
mirror container. The routing is not merely non-unique, it is non-deterministic.

## Why this is a security finding and not a reliability nuisance

The daemon serves with `--export-all --base-path=/srv/git`
(`images/git/entrypoint.sh:370-377`) and, per orders 450/423's documented
interim, still carries `--enable=receive-pack`.

Compose those three facts:

1. one shared name resolving to N mirrors,
2. a daemon that exports **everything** beneath its base path, and
3. an anonymous write path.

The containment that survives today is that each volume happens to hold only its
own project, so a misrouted request usually 404s. That is containment by
**accident of volume layout**, not by identity — exactly the distinction
606-bvnp exists to remove. Any change that puts two projects under one
`/srv/git`, or reuses a volume across a rename, converts a 404 into a
cross-project read or write with nothing in the code objecting.

The intermittent-failure surface is real too: a forge for project A that
resolves to project B's mirror gets "repository not found" for a repo that
demonstrably exists, which reads as mirror corruption rather than misrouting.

## What this settles for 606-bvnp

- Criterion 3 needs no further investigation — it is violated, and the
  reproduction above is its negative-test fixture: after the fix, two
  simultaneous mirrors must yield **one A record per project-unique name**, and
  the shared name must not resolve at all.
- The remaining criteria (AppRole/SSH-CA exactness, certificate principals, the
  403 matrix) are untouched by this audit and still need the design pass.

## Residual — deliberately not done here

- **No Vault or SSH-CA work.** Criteria 1, 2, 4 and 5 concern signer authority
  and are not addressed.
- **Not tested with two real mirrors.** The probe used the product's alias
  arguments on plain containers, not two live `tillandsias-git` images with
  populated volumes. That is sufficient for the DNS claim — the aliases and the
  resolver are the whole mechanism — but it does not exercise a real
  cross-project fetch, and I am not claiming one succeeded.
- **`nslookup` in the probe image failed** with "Message too large" against the
  podman resolver before `getent` produced the answer above. Recorded because a
  reader repeating this with nslookup will get an empty result and may read it
  as "the name does not resolve", which is the opposite of the finding.
